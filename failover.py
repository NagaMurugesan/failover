"""
Lambda to swap Route53 failover PRIMARY/SECONDARY based on CloudWatch Alarm SNS events.

Behavior:
- Receives CloudWatch Alarm notifications delivered via SNS.
- If the alarm is the primary-region alarm and is in state 'ALARM', attempts to make the secondary record PRIMARY.
- If the alarm is the primary-region alarm and is in state 'OK', attempts to revert the primary back to PRIMARY.
- Before switching to secondary, checks the secondary RegionHealth metric to ensure it's healthy.

Environment variables expected:
- HOSTED_ZONE_ID
- RECORD_NAME (FQDN e.g. www.example.com)
- PRIMARY_SET_ID
- SECONDARY_SET_ID
- PRIMARY_ALB_DNS
- PRIMARY_ALB_ZONE_ID
- SECONDARY_ALB_DNS
- SECONDARY_ALB_ZONE_ID
- PRIMARY_REGION_LABEL
- SECONDARY_REGION_LABEL
"""

import os
import json
import boto3
import logging
from datetime import datetime, timedelta

logger = logging.getLogger()
logger.setLevel(logging.INFO)

route53 = boto3.client('route53')
cloudwatch = boto3.client('cloudwatch')

HOSTED_ZONE_ID = os.environ['HOSTED_ZONE_ID']
RECORD_NAME = os.environ['RECORD_NAME']
PRIMARY_SET_ID = os.environ['PRIMARY_SET_ID']
SECONDARY_SET_ID = os.environ['SECONDARY_SET_ID']
PRIMARY_ALB_DNS = os.environ['PRIMARY_ALB_DNS']
PRIMARY_ALB_ZONE_ID = os.environ['PRIMARY_ALB_ZONE_ID']
SECONDARY_ALB_DNS = os.environ['SECONDARY_ALB_DNS']
SECONDARY_ALB_ZONE_ID = os.environ['SECONDARY_ALB_ZONE_ID']
PRIMARY_REGION_LABEL = os.environ['PRIMARY_REGION_LABEL']
SECONDARY_REGION_LABEL = os.environ['SECONDARY_REGION_LABEL']

# Get recent metric datapoint for a region; return None if no data
def get_latest_region_health(region_label):
    try:
        end = datetime.utcnow()
        start = end - timedelta(minutes=5)
        resp = cloudwatch.get_metric_statistics(
            Namespace='MyApp/Failover',
            MetricName='RegionHealth',
            Dimensions=[{'Name': 'Region', 'Value': region_label}],
            StartTime=start,
            EndTime=end,
            Period=60,
            Statistics=['Average']
        )
        datapoints = resp.get('Datapoints', [])
        if not datapoints:
            return None
        # return latest by Timestamp
        latest = sorted(datapoints, key=lambda d: d['Timestamp'])[-1]
        return latest.get('Average')
    except Exception as e:
        logger.exception("Failed to get metric for %s: %s", region_label, e)
        return None

def upsert_failover_records(primary_is_east: bool):
    """
    primary_is_east == True -> set the east/alb as PRIMARY, west as SECONDARY
    primary_is_east == False -> set the west/alb as PRIMARY, east as SECONDARY
    """
    if primary_is_east:
        primary_alias = {
            'HostedZoneId': PRIMARY_ALB_ZONE_ID,
            'DNSName': PRIMARY_ALB_DNS,
            'EvaluateTargetHealth': False
        }
        secondary_alias = {
            'HostedZoneId': SECONDARY_ALB_ZONE_ID,
            'DNSName': SECONDARY_ALB_DNS,
            'EvaluateTargetHealth': False
        }
        primary_set_id = PRIMARY_SET_ID
        secondary_set_id = SECONDARY_SET_ID
        primary_fail = 'PRIMARY'
        secondary_fail = 'SECONDARY'
    else:
        primary_alias = {
            'HostedZoneId': SECONDARY_ALB_ZONE_ID,
            'DNSName': SECONDARY_ALB_DNS,
            'EvaluateTargetHealth': False
        }
        secondary_alias = {
            'HostedZoneId': PRIMARY_ALB_ZONE_ID,
            'DNSName': PRIMARY_ALB_DNS,
            'EvaluateTargetHealth': False
        }
        primary_set_id = SECONDARY_SET_ID
        secondary_set_id = PRIMARY_SET_ID
        primary_fail = 'PRIMARY'
        secondary_fail = 'SECONDARY'

    changes = [
        {
            'Action': 'UPSERT',
            'ResourceRecordSet': {
                'Name': RECORD_NAME,
                'Type': 'A',
                'SetIdentifier': primary_set_id,
                'Failover': primary_fail,
                'TTL': 60,
                'AliasTarget': {
                    'HostedZoneId': primary_alias['HostedZoneId'],
                    'DNSName': primary_alias['DNSName'],
                    'EvaluateTargetHealth': primary_alias['EvaluateTargetHealth']
                }
            }
        },
        {
            'Action': 'UPSERT',
            'ResourceRecordSet': {
                'Name': RECORD_NAME,
                'Type': 'A',
                'SetIdentifier': secondary_set_id,
                'Failover': secondary_fail,
                'TTL': 60,
                'AliasTarget': {
                    'HostedZoneId': secondary_alias['HostedZoneId'],
                    'DNSName': secondary_alias['DNSName'],
                    'EvaluateTargetHealth': secondary_alias['EvaluateTargetHealth']
                }
            }
        }
    ]

    logger.info("Applying Route53 ChangeResourceRecordSets with %s", json.dumps(changes, default=str))
    resp = route53.change_resource_record_sets(
        HostedZoneId=HOSTED_ZONE_ID,
        ChangeBatch={
            'Comment': 'Failover swap by Lambda',
            'Changes': changes
        }
    )
    logger.info("Route53 response: %s", resp)
    return resp

def parse_sns_event(event):
    """
    Received SNS wrapper-> record -> SNS -> Message (CloudWatch alarm JSON).
    """
    try:
        # CloudWatch sends raw JSON in SNS Message
        sns_record = event['Records'][0]['Sns']
        message = sns_record['Message']
        msg = json.loads(message)
        return msg
    except Exception as e:
        logger.exception("Failed to parse SNS event: %s", e)
        return None

def lambda_handler(event, context):
    logger.info("Event: %s", json.dumps(event))
    msg = parse_sns_event(event)
    if not msg:
        logger.error("No parsed message, aborting")
        return

    alarm_name = msg.get('AlarmName')
    new_state = msg.get('NewStateValue')  # OK or ALARM or INSUFFICIENT_DATA
    logger.info("Alarm %s changed to %s", alarm_name, new_state)

    # Determine if it's primary alarm
    if var_is_primary_alarm(alarm_name):
        logger.info("Event for primary alarm")
        if new_state == 'ALARM':
            # Primary reported down -> before switching, ensure secondary is healthy
            sec_health = get_latest_region_health(SECONDARY_REGION_LABEL)
            logger.info("Secondary region latest health datapoint: %s", sec_health)
            if sec_health is None:
                # conservatively avoid switching if no metric datapoint
                logger.warning("No datapoint for secondary; aborting switch")
                return
            if sec_health <= 0.5:
                logger.error("Secondary appears unhealthy (%s); aborting failover", sec_health)
                return
            # safe to switch: make secondary primary
            upsert_failover_records(primary_is_east=False)
            logger.info("Switched to secondary as PRIMARY")
            return
        elif new_state == 'OK':
            # Primary recovered -> switch back (make east primary)
            # But verify primary health before switching
            pri_health = get_latest_region_health(PRIMARY_REGION_LABEL)
            logger.info("Primary latest health datapoint: %s", pri_health)
            if pri_health is None or pri_health <= 0.5:
                logger.warning("Primary not healthy enough to revert. Skipping revert.")
                return
            upsert_failover_records(primary_is_east=True)
            logger.info("Reverted to primary as PRIMARY")
            return
        else:
            logger.info("Unhandled new state: %s", new_state)
            return
    else:
        logger.info("Alarm is not primary alarm; ignoring in this version")
        return

def var_is_primary_alarm(alarm_name):
    # matches the CloudWatch alarm name as created by Terraform
    expected = f"RegionDown-{PRIMARY_REGION_LABEL}-{os.environ.get('RECORD_NAME').split('.',1)[1]}"
    # But to be robust, check prefix
    if alarm_name and PRIMARY_REGION_LABEL in alarm_name:
        return True
    return False
