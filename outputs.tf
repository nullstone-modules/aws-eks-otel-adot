locals {
  // The operator names the OTLP Service "<cr-name>-collector".
  collector_service = "${local.resource_name}-collector"
  service_endpoint  = "http://${local.collector_service}.${local.kubernetes_namespace}"
}

output "kubernetes_namespace" {
  value       = local.kubernetes_namespace
  description = "string ||| The name of the namespace (from the connected cluster-namespace) where this OpenTelemetry collector runs"
}

output "grpc_endpoint" {
  value       = "${local.service_endpoint}:4317"
  description = "string ||| The endpoint URL to receive OpenTelemetry over gRPC"
}

output "http_endpoint" {
  value       = "${local.service_endpoint}:4318"
  description = "string ||| The endpoint URL to receive OpenTelemetry over HTTP"
}

output "amp_workspace_id" {
  value       = one(aws_prometheus_workspace.this[*].id)
  description = "string ||| The ID of the Amazon Managed Prometheus workspace receiving metrics (null when enable_aws_sinks is false)"
}
