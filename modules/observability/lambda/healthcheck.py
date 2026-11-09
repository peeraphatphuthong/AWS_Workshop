"""Synthetic health check: GET <URL> from outside the VPC, publish the result as CloudWatch metrics.

Runs every few minutes (EventBridge Scheduler). Publishes:
  HealthCheckOk         1 = HTTP 200 within the timeout, 0 = anything else
  HealthCheckLatencyMs  response time of successful checks

When the web tier is intentionally scaled to zero (office-hours schedule) nothing is published, so
the alarm sees "missing data" (treated as not breaching) instead of a false outage.
"""
import json
import os
import time
import urllib.error
import urllib.request

import boto3

URL = os.environ["URL"]
ASG_NAME = os.environ["ASG_NAME"]
NAMESPACE = os.environ["NAMESPACE"]
TIMEOUT = float(os.environ.get("TIMEOUT_SECONDS", "5"))

autoscaling = boto3.client("autoscaling")
cloudwatch = boto3.client("cloudwatch")


def in_service_instances() -> int:
    """Instances the ASG considers InService (0 at night, or while the first one is booting)."""
    groups = autoscaling.describe_auto_scaling_groups(AutoScalingGroupNames=[ASG_NAME])["AutoScalingGroups"]
    if not groups:
        return 0
    return sum(1 for i in groups[0]["Instances"] if i["LifecycleState"] == "InService")


def check() -> tuple[bool, float, str]:
    started = time.monotonic()
    try:
        with urllib.request.urlopen(URL, timeout=TIMEOUT) as resp:  # noqa: S310 (fixed http URL)
            body = resp.read(2048).decode("utf-8", "replace")
            ok = resp.status == 200
            detail = f"HTTP {resp.status} {body[:200]}"
    except urllib.error.HTTPError as err:
        ok, detail = False, f"HTTP {err.code}"
    except Exception as err:  # timeout, connection refused, DNS ...
        ok, detail = False, f"{type(err).__name__}: {err}"
    return ok, (time.monotonic() - started) * 1000, detail


def handler(event, context):
    in_service = in_service_instances()
    if in_service == 0:
        print(json.dumps({"skipped": True, "in_service": 0}))
        return {"skipped": True, "in_service": 0}

    ok, latency_ms, detail = check()
    metrics = [{"MetricName": "HealthCheckOk", "Value": 1 if ok else 0, "Unit": "Count"}]
    if ok:
        metrics.append({"MetricName": "HealthCheckLatencyMs", "Value": latency_ms, "Unit": "Milliseconds"})
    cloudwatch.put_metric_data(Namespace=NAMESPACE, MetricData=metrics)

    result = {"ok": ok, "latency_ms": round(latency_ms, 1), "detail": detail, "url": URL, "in_service": in_service}
    print(json.dumps(result))  # structured log line -> easy to query in Logs Insights
    return result
