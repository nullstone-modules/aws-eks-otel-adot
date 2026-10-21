# aws-eks-otel-adot

Deploys an OpenTelemetry collector onto an existing EKS cluster-namespace via the AWS Distro for
OpenTelemetry (ADOT) operator. Implements the `datastore/aws/otel:eks` contract and exposes the same
outputs as the GCP/GKE collector (`grpc_endpoint`, `http_endpoint`, `kubernetes_namespace`) so
telemetry consumers stay provider-agnostic.

## What it does

- Installs the OpenTelemetry/ADOT operator via Helm (`install_operator`, default `true`). The
  operator's admission webhook requires **cert-manager**, which the cluster modules
  (`aws-eks-standard` / `aws-eks-auto`) install by default.
- Renders one `OpenTelemetryCollector` custom resource (applied with `gavinbunney/kubectl`).
- Routes telemetry to AWS-native sinks (when `enable_aws_sinks = true`, the default):
  - traces → AWS X-Ray
  - metrics → Amazon Managed Prometheus (an AMP workspace is created by this module)
  - logs → CloudWatch Logs
  - optionally metrics → CloudWatch EMF (`enable_cloudwatch_metrics`)
- Grants the collector's service account the matching IAM via EKS Pod Identity (default) or IRSA
  (Fargate), and the cluster RBAC the `k8sattributes` processor needs.

## Extender (optional)

Connect an `extender` (e.g. `k8s-otel-langfuse-extender`) to forward telemetry to another provider
without forking this module. The extender's structured `collector-config-fragments` are deep-merged
into the collector's `spec.config` in Terraform. If the extender reports `collector-env-from` (a
Secret holding exporter credentials referenced as `${env:...}`), it is loaded into the pod env and
`collector-env-version` is stamped on the pod so a credential rotation restarts the collector.

Set `enable_aws_sinks = false` to send telemetry **only** to the extender — the AWS exporters, the
AMP workspace, and the AWS IAM are all omitted. An `extender` connection is required in that mode.

## Tuning

- `memory` / `memory_limit` (defaults 256Mi / 512Mi): the memory_limiter refuses intake above 55% of
  the limit. Raise these when `otelcol_receiver_refused_*` grows.
- `batch_size` / `batch_max_size` (defaults 1000 / 2000): items per export batch.
- `min_replicas` / `max_replicas`: the OTLP receiver is stateless, so replicas scale horizontally.

## Notes

- The operator is cluster-scoped (one per cluster). When multiple otel collector datastores target
  the same cluster, set `install_operator = false` on the additional instances.
- `collector_image` is shared by the gateway and the infra metrics agent. It must include the AWS
  exporters and the `kubeletstats` receiver; the contrib distribution (default) does, the ADOT image
  lacks `kubeletstats`, and the core image lacks the AWS exporters.

## Infra metrics (optional)

Set `enable_infra_metrics = true` to run an agent on every node (a second `OpenTelemetryCollector`,
`mode: daemonset`) that scrapes the kubelet with `kubeletstats` for node, pod, and container CPU/memory.

- Exported **only to the connected `extender`** (its `metrics*` pipelines, fed by `kubeletstats`
  instead of `otlp`). Never to AMP or CloudWatch. An extender connection is required.
- Pod/container metrics are kept for `infra_namespaces` only (default: the connected
  cluster-namespace). Node metrics are always kept.
- Metrics carry `k8s.deployment.name` etc. via a node-scoped `k8sattributes`, plus
  `k8s.cluster.name` and `deployment.environment`.
- Sizing: `agent_cpu`, `agent_memory`, `agent_memory_limit`, `agent_collection_interval`.
- Not available on Fargate (no DaemonSets, no kubelet).
