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
into the collector's `spec.config` in Terraform.

Set `enable_aws_sinks = false` to send telemetry **only** to the extender — the AWS exporters, the
AMP workspace, and the AWS IAM are all omitted. An `extender` connection is required in that mode.

## Notes

- The operator is cluster-scoped (one per cluster). When multiple otel collector datastores target
  the same cluster, set `install_operator = false` on the additional instances.
- `collector_image` must be a distribution that includes the AWS exporters (the ADOT collector or
  `opentelemetry-collector-contrib`); the core upstream image does not.
