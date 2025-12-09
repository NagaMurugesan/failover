How it works — walkthrough

Metrics publishing (your responsibility):

Your app or a synthetic monitor in each region must publish a CloudWatch metric:

Namespace: MyApp/Failover

MetricName: RegionHealth

Dimension: Region = east-01 (primary) or west-01 (secondary)

Value: 1 for healthy, 0 for unhealthy

You can publish from app code or a small cron Lambda (in each region) that does a health probe and calls PutMetricData.

CloudWatch Alarm (primary):

When RegionHealth for primary <= 0.5 (i.e., trending to 0) for one period, the alarm goes to ALARM.

The alarm sends an SNS notification. SNS invokes the control Lambda.

Lambda failover:

Control Lambda (running in control_region, default us-east-2) receives the SNS message.

If the event says PRIMARY alarm is ALARM → Lambda verifies secondary is healthy (by checking the metric). If healthy → Lambda swaps failover by UPSERTing the two Route53 record sets so the secondary becomes the PRIMARY.

When primary alarm returns to OK, Lambda verifies primary healthy and swaps back.

Route53 behavior:

Because the Lambda changes which alias is labeled PRIMARY vs SECONDARY, Route53 will start returning the now-PARENT record (PRIMARY). TTL is low (60s), so resolvers will pick up the change relatively quickly.

Important caveats & suggestions

Publishing metrics: The solution depends on accurate, timely custom metrics for both regions. If there are gaps, the Lambda will be conservative and may avoid switching.

Lambda location: Put the Lambda in a region that will stay up even if east-01 is down (e.g., us-east-2 or us-west-2). The Terraform default is us-east-2.

Permissions: The Lambda requires route53:ChangeResourceRecordSets — our policy uses Resource="*" to simplify (Route53 APIs often require zone-level strings; you can lock it down further).

Testing: Test thoroughly:

Publish RegionHealth=0 to primary and confirm the alarm triggers and the Lambda swaps records.

Test the revert path by publishing RegionHealth=1.

Edge cases: If both regions go unhealthy, Lambda will not switch traffic (it checks secondary health first).

DNS caching: Clients / resolvers may cache the old record beyond TTL; keep TTL low but be aware of resolver caching behavior.

Logging & alerting: CloudWatch logs for Lambda should be monitored. You can add an SNS notification for swap events.