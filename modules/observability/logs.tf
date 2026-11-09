# Turn nginx JSON access logs into a metric: number of 5xx responses.
# Metric filters are free; the metric is a custom metric ($0.30/month).
resource "aws_cloudwatch_log_metric_filter" "nginx_5xx" {
  name           = "nginx-5xx"
  log_group_name = var.container_log_group_name
  pattern        = "{ $.status >= 500 }"

  metric_transformation {
    name          = "Nginx5xx"
    namespace     = local.metric_namespace
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }
}
