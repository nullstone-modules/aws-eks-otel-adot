# `aws-eks-otel-adot` — Design (as built)

OpenTelemetry collector on EKS via the AWS Distro for OpenTelemetry (ADOT) operator. Implements the
`datastore/aws/otel:eks` contract and mirrors the GKE module (`gcp/gcp-gke-otel-collector`,
`datastore/gcp/otel:gke`) so telemetry consumers stay provider-agnostic, including the optional
**extender** mechanism for forwarding telemetry to another provider (e.g. Langfuse).

> Tracked in Linear **NUL-88**.

---

## 1. Operator & cert-manager ownership

- The **ADOT/OpenTelemetry operator is self-managed by this module** via Helm
  (`operator.tf`, chart `opentelemetry-operator`). It registers the `OpenTelemetryCollector` CRD and
  reconciles the CR into a Deployment + Services.
- The operator's admission webhook requires **cert-manager**, which the cluster modules
  (`aws-eks-standard`, `aws-eks-auto`) install by default via Helm. The previously-available `adot`
  EKS managed add-on was removed from `aws-eks-standard`.
- The operator is **cluster-scoped** (one per cluster) while this module is per-cluster-namespace.
  `var.install_operator` (default `true`) is the escape hatch: additional collector datastores on the
  same cluster set it `false` to reuse the existing operator.

## 2. Collector CR (`gavinbunney/kubectl`)

`collector.tf` renders one `OpenTelemetryCollector` (`opentelemetry.io/v1beta1`) with
`kubectl_manifest`. The official `hashicorp/kubernetes` `kubernetes_manifest` is **not** used because
it performs a plan-time CRD-schema lookup that fails when the CRD is installed (by the operator) in
the same apply; `kubectl_manifest` does no such lookup. v1beta1 `spec.config` is a structured object.
The autoscaler block is only emitted when `max_replicas > min_replicas` (it needs metrics-server).

## 3. Base config & sinks (`config.tf`)

- receivers: `otlp` (grpc `:4317`, http `:4318`); processors: `memory_limiter`, `batch`,
  `k8sattributes`; extension `health_check`.
- When `enable_aws_sinks = true` (default): exporters `awsxray` (traces), `prometheusremotewrite` →
  AMP (`amp.tf` creates the `aws_prometheus_workspace`) with the `sigv4auth` extension,
  `awscloudwatchlogs` (logs), and optionally `awsemf` (`enable_cloudwatch_metrics`); pipelines
  `traces`/`metrics`/`logs` wired accordingly.
- When `enable_aws_sinks = false`: the base contributes only the OTLP receiver + shared processors;
  **all sinks come from the extender**. A precondition requires an extender in that mode (no empty
  pipelines), and the AMP workspace + AWS IAM are omitted.

## 4. Extender (Terraform-side deep-merge) — `extender.tf`

Consumes the extender's structured `collector-config-fragments` output (added to
`k8s-otel-langfuse-extender`) via an optional `extender` connection and deep-merges each fragment onto
the base `spec.config`: component maps merge recursively; `service.extensions` is concatenated. A
precondition enforces the extender targets the same `kubernetes_namespace`. The GKE module's
mount-based `collector-config-maps` output is unchanged.

## 5. Identity, IAM & RBAC — `iam.tf`, `service-account.tf`

KSA bound to an `aws_iam_role` via EKS Pod Identity (default) or IRSA (`use_irsa`, Fargate). Managed
policies (`AmazonPrometheusRemoteWriteAccess`, `AWSXrayWriteOnlyAccess`, `CloudWatchAgentServerPolicy`)
attach only when AWS sinks are enabled. A `ClusterRole`/`ClusterRoleBinding` grants the
`k8sattributes` processor `get/list/watch` on pods/namespaces/nodes/replicasets.

## 6. Providers & outputs

`providers.tf`: `ns`, `aws`, `kubernetes`, `helm`, `kubectl`, `random`; cluster auth via
`ephemeral aws_eks_cluster_auth` (`cluster-namespace.tf`). Outputs (`outputs.tf`, GKE parity):
`kubernetes_namespace`, `grpc_endpoint`, `http_endpoint`, plus `amp_workspace_id`.

## 7. Verification

- `tofu init -backend=false && tofu validate` here, in `k8s-otel-langfuse-extender`, and the cluster
  modules.
- On a cluster with cert-manager present: apply → operator + CRD ready, CR reconciles, operator
  creates `<name>-collector` Services; OTLP reachable at `grpc_endpoint`/`http_endpoint`; traces in
  X-Ray, metrics in AMP, logs in CloudWatch.
- Extender connected → its pipeline appears in the merged `spec.config`; wrong namespace → precondition
  fails. `install_operator = false` second instance applies without conflict. `enable_aws_sinks = false`
  + extender → no AMP/AWS exporters, telemetry only to the extender.
