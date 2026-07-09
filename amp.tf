// Amazon Managed Prometheus workspace — the default metrics sink. Not created in extender-only mode
// (enable_aws_sinks = false), where metrics flow only to the extender's exporters.
resource "aws_prometheus_workspace" "this" {
  count = var.enable_aws_sinks ? 1 : 0

  alias = local.resource_name
  tags  = local.tags
}
