variable "install_operator" {
  type        = bool
  default     = true
  description = <<EOF
Whether this module installs the OpenTelemetry/ADOT operator (Helm) into the cluster.

The operator is cluster-scoped (one per cluster). When more than one otel collector datastore
targets the same cluster, set this to false on the additional instances so they reuse the
already-installed operator instead of colliding on the Helm release.
EOF
}

variable "operator_chart_version" {
  type        = string
  default     = "0.90.4"
  description = "The version of the opentelemetry-operator Helm chart (https://open-telemetry.github.io/opentelemetry-helm-charts) to install."
}

variable "collector_image" {
  type        = string
  default     = "public.ecr.aws/aws-observability/aws-otel-collector:v0.43.3"
  description = <<EOF
The container image for the collector. It must be a distribution that includes the AWS exporters
(awsxray, awsemf, awscloudwatchlogs) and prometheusremotewrite + sigv4auth — e.g. the ADOT collector
(aws-otel-collector) or opentelemetry-collector-contrib. The core upstream collector image does NOT
include these and will fail to start with this config.
EOF
}

variable "enable_aws_sinks" {
  type        = bool
  default     = true
  description = <<EOF
When true (default), the collector exports to AWS-native backends: traces to X-Ray, metrics to
Amazon Managed Prometheus (an AMP workspace is created by this module), and logs to CloudWatch Logs.

When false, the collector sends telemetry ONLY to the connected `extender` (e.g. Langfuse): the AWS
exporters, the AMP workspace, and the AWS IAM role/policies are all omitted. An `extender` connection
is required in this mode.
EOF
}

variable "enable_cloudwatch_metrics" {
  type        = bool
  default     = false
  description = "When true (and enable_aws_sinks is true), additionally export metrics to CloudWatch via the awsemf exporter (in addition to Amazon Managed Prometheus)."
}

variable "cpu" {
  type        = string
  default     = "200m"
  description = "The amount of CPU to request for each collector."
}

variable "memory" {
  type        = string
  default     = "128Mi"
  description = "The amount of memory to request for each collector."
}

variable "memory_limit" {
  type        = string
  default     = "256Mi"
  description = "The maximum amount of memory each collector can use."
}

variable "min_replicas" {
  type        = number
  default     = 1
  description = "The minimum number of collector replicas to run. Autoscaling is disabled when this equals max_replicas."
}

variable "max_replicas" {
  type        = number
  default     = 1
  description = "The maximum number of collector replicas to run. Autoscaling is disabled when this equals min_replicas."
}
