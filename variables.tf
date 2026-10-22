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
  default     = "0.118.0"
  description = "The version of the opentelemetry-operator Helm chart (https://open-telemetry.github.io/opentelemetry-helm-charts) to install."
}

variable "collector_image" {
  type        = string
  default     = "ghcr.io/open-telemetry/opentelemetry-collector-releases/opentelemetry-collector-contrib:0.163.1"
  description = <<EOF
The container image for both collectors: the OTLP gateway and, when enable_infra_metrics is true, the
kubelet-scraping agent. It must include the AWS exporters (awsxray, awsemf, awscloudwatchlogs),
prometheusremotewrite + sigv4auth, the kubeletstats receiver, and (when enable_cluster_metrics is true) the
k8s_cluster receiver with the k8s_leader_elector extension. The contrib distribution has all of
them; the ADOT image lacks kubeletstats and the core image lacks the AWS exporters.
EOF
}

variable "enable_aws_sinks" {
  type        = bool
  default     = true
  description = <<EOF
When true (default), the collector exports to AWS-native backends: traces to X-Ray, metrics to
Amazon Managed Prometheus (an AMP workspace is created by this module), and logs to CloudWatch Logs.

When false, the collector sends telemetry ONLY to the connected `extender` (e.g. external vendor): the AWS
exporters, the AMP workspace, and the AWS IAM role/policies are all omitted. An `extender` connection is required in this mode.
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
  default     = "256Mi"
  description = "The amount of memory to request for each collector."
}

variable "memory_limit" {
  type        = string
  default     = "512Mi"
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

variable "batch_size" {
  type        = number
  default     = 1000
  description = "Items (spans, metric points, log records) the batch processor accumulates before exporting (send_batch_size)."
}

variable "batch_max_size" {
  type        = number
  default     = 2000
  description = "Upper bound on items per exported batch (send_batch_max_size). Must be >= batch_size."

  validation {
    condition     = var.batch_max_size >= var.batch_size
    error_message = "batch_max_size must be >= batch_size."
  }
}

variable "enable_infra_metrics" {
  type        = bool
  default     = false
  description = <<EOF
When true, runs an agent on every node (DaemonSet) that scrapes the kubelet for node, pod, and
container CPU/memory and exports it ONLY to the connected `extender`, never to the AWS sinks.
Requires an `extender` connection. Not available on Fargate.
EOF
}

variable "infra_namespaces" {
  type        = list(string)
  default     = []
  description = <<EOF
Namespaces whose pod and container infra metrics are kept; all others are dropped. Node metrics are
always kept. Empty (default) means only the connected cluster-namespace.
EOF
}

variable "agent_collection_interval" {
  type        = string
  default     = "60s"
  description = "How often each infra metrics agent scrapes its kubelet."
}

variable "agent_cpu" {
  type        = string
  default     = "100m"
  description = "The amount of CPU to request for each infra metrics agent."
}

variable "agent_memory" {
  type        = string
  default     = "128Mi"
  description = "The amount of memory to request for each infra metrics agent."
}

variable "agent_memory_limit" {
  type        = string
  default     = "256Mi"
  description = "The maximum amount of memory each infra metrics agent can use."
}

variable "enable_cluster_metrics" {
  type        = bool
  default     = false
  description = <<EOF
When true, the OTLP gateway also runs the k8s_cluster receiver, which watches the Kubernetes API for
cluster-level state (container restarts and readiness, pod phase, deployment available/desired,
container CPU/memory limits, node conditions) and exports it ONLY to the connected `extender`, never
to the AWS sinks. Runs on one gateway replica at a time via leader election. Requires an `extender`
connection.
EOF
}

variable "cluster_collection_interval" {
  type        = string
  default     = "60s"
  description = "How often the k8s_cluster receiver emits cluster metrics."
}
