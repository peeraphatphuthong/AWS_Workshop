"""Synthetic health check: GET <URL> from outside the VPC, publish the result as CloudWatch metrics.

Runs every few minutes (EventBridge Scheduler). Publishes:
  HealthCheckOk         1 = HTTP 200 within the timeout, 0 = anything else
  HealthCheckLatencyMs  response time of successful checks

When the web host is intentionally stopped (office-hours schedule) nothing is published, so the
alarm sees "missing data" (treated as not breaching) instead of a false outage.
"""
import json
import os
import time
import urllib.error
import urllib.request

import boto3

URL = os.environ["URL"]
INSTANCE_ID = os.environ["INSTANCE_ID"]
NAMESPACE = os.environ["NAMESPACE"]
TIMEOUT = float(os.environ.get("TIMEOUT_SECONDS", "5"))

ec2 = boto3.client("ec2")
cloudwatch = boto3.client("cloudwatch")


def instance_state() -> str:
    resp = ec2.describe_instance_status(InstanceIds=[INSTANCE_ID], IncludeAllInstances=True)
    statuses = resp.get("InstanceStatuses", [])
    return statuses[0]["InstanceState"]["Name"] if statuses else "unknown"


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
    state = instance_state()
    if state != "running":
        print(json.dumps({"skipped": True, "instance_state": state}))
        return {"skipped": True, "instance_state": state}

    ok, latency_ms, detail = check()
    metrics = [{"MetricName": "HealthCheckOk", "Value": 1 if ok else 0, "Unit": "Count"}]
    if ok:
        metrics.append({"MetricName": "HealthCheckLatencyMs", "Value": latency_ms, "Unit": "Milliseconds"})
    cloudwatch.put_metric_data(Namespace=NAMESPACE, MetricData=metrics)

    result = {"ok": ok, "latency_ms": round(latency_ms, 1), "detail": detail, "url": URL}
    print(json.dumps(result))  # structured log line -> easy to query in Logs Insights
    return result
