# `aws-eks-adot` — Implementation Plan

OTEL collector hosted on EKS via AWS Distro for OpenTelemetry (ADOT). Implements the
`datastore/aws/otel:eks` contract and mirrors the logical architecture of
`gcp/gcp-gke-otel-collector/` (`datastore/gcp/otel:gke`), including the optional **extender**
mechanism for forwarding telemetry to another provider (e.g. Langfuse).

> Status: planning. Tracked in Linear **NUL-88**. No module code has been written yet.

---

## 1. Goals & non-goals

**Goals**

- Deploy an OTEL collector into an existing EKS cluster-namespace.
- Expose the same outputs as the GCP module so consumers are provider-agnostic:
  - `kubernetes_namespace`
  - `grpc_endpoint` (OTLP gRPC, `:4317`)
  - `http_endpoint` (OTLP HTTP, `:4318`)
- Support the optional **extender** connection (`datastore/aws/otel-extender`, provider-wildcarded
  in practice) to emit telemetry to another provider without forking the module.
- Route telemetry to AWS-native backends: CloudWatch (logs/metrics), X-Ray (traces), and
  optionally Amazon Managed Prometheus (AMP).

**Non-goals**

- Installing the ADOT operator or cert-manager (treated as a cluster prerequisite — see Open Q1).
- Replacing the GKE module's mount-based extender consumption (that contract is unchanged).

---

## 2. Architectural differences from the GKE module

| Concern | GKE module | EKS / ADOT module |
| --- | --- | --- |
| Collector definition | Hand-built `Deployment` + `ConfigMap` | `OpenTelemetryCollector` CRD (`opentelemetry.io/v1beta1`) |
| Multi-config merge | Multiple `--config` files mounted as volumes; collector merges at runtime | `spec.config` is a single structured object; **fragments deep-merged in Terraform** |
| Services | Created by the module | Auto-created by the operator: `<name>-collector`, `<name>-collector-headless`, `<name>-collector-monitoring` |
| Identity | GCP Workload Identity | EKS Pod Identity (default) / IRSA (Fargate) |
| Config delivery | `spec.args` `--config` per fragment | **Not possible** — `spec.args` is `map[string]string`, can't repeat `--config` |

**Key constraint:** because `spec.args` cannot carry multiple `--config` flags, the ADOT module
deep-merges extender fragments into the structured `spec.config` *in Terraform* before rendering
the CR. This is the central design pivot of the module.

---

## 3. Collector deployment (the CRD)

Create exactly **one** `OpenTelemetryCollector` CR via `gavinbunney/kubectl`'s `kubectl_manifest`
(see Open Q3). The CRD *definition* is installed by the ADOT operator (prerequisite).

```yaml
apiVersion: opentelemetry.io/v1beta1
kind: OpenTelemetryCollector
metadata:
  name: <resource_name>
  namespace: <kubernetes_namespace>
spec:
  mode: deployment          # Deployment, autoscaled via spec.autoscaler
  serviceAccount: <sa_name> # bound to the IAM role (Pod Identity / IRSA)
  replicas: var.min_replicas
  autoscaler:
    minReplicas: var.min_replicas
    maxReplicas: var.max_replicas
  resources:
    requests: { cpu: var.cpu, memory: var.memory }
    limits:   { memory: var.memory_limit }
  config:                   # <-- structured object, NOT a string (v1beta1)
    receivers: { ... }
    processors: { ... }
    exporters: { ... }
    extensions: { ... }
    service:
      extensions: [ ... ]
      pipelines: { ... }
```

Notes:
- v1beta1 `spec.config` is a **structured** object (v1alpha1 was a string). Empty components must be
  rendered as `{}` / `[]`, not omitted.
- The operator owns the Services; OTLP is reachable at
  `<name>-collector.<namespace>:4317` (gRPC) and `:4318` (HTTP). Outputs derive from this.

---

## 4. Base collector config

Receivers / processors mirror the GKE base so pipelines are portable:

- **receivers:** `otlp` (grpc `:4317`, http `:4318`)
- **processors:** `memory_limiter`, `batch`, `k8sattributes` (enriches spans with pod/namespace
  metadata — requires ClusterRole RBAC, see §6)
- **exporters (AWS-native):**
  - `awsxray` — traces → X-Ray
  - `awsemf` — metrics → CloudWatch (EMF)
  - `awscloudwatchlogs` — logs → CloudWatch Logs
  - *(optional)* `prometheusremotewrite` + `sigv4auth` extension (`service: aps`) — metrics → AMP
- **service.pipelines:** `traces`, `metrics`, `logs` wired to the above.

CloudWatch EMF is the default metrics path; AMP is opt-in (see Open Q2).

---

## 5. The extender mechanism (Terraform-side merge)

The shared extender module (`k8s-otel-langfuse-extender`) is updated to export **two** outputs from
one source-of-truth fragment local:

```hcl
# UNCHANGED — GKE mount-based consumers
output "collector-config-maps" {
  value = [{ filename = string, configMapName = string }]
}

# NEW — EKS/ADOT merge-based consumers; structured, no yamldecode needed
output "collector-config-fragments" {
  value = list(any)
}

output "kubernetes_namespace" { value = string }
```

The ADOT collector consumes `collector-config-fragments` via its `extender` `ns_connection` and
**deep-merges** each fragment onto the base `spec.config`:

- **maps merge recursively** (so `exporters`, `processors`, `extensions`, `service.pipelines` keys
  from the fragment are added);
- **`service.extensions` is concatenated** (not list-replaced) so an extender can activate its own
  extensions (e.g. `sigv4auth`);
- the merge happens in TF, so there is **no plan/apply ordering fragility** (no reading ConfigMaps
  back via a data source).

Backward compatibility: the GKE module needs **zero changes** — it keeps consuming
`collector-config-maps`. Minor accepted wart: the extender still creates an (unused) ConfigMap when
targeting AWS.

Namespace guard: like the GKE module, the collector validates at plan time that its namespace
matches the extender's `kubernetes_namespace` output.

---

## 6. Identity & IAM

Follow the `eks-appscaffold` pattern:

- Create an `aws_iam_role` for the collector's KSA.
- **Pod Identity (default):** trust `pods.eks.amazonaws.com`; create
  `aws_eks_pod_identity_association` (count on `!use_irsa`).
- **IRSA (`use_irsa`, Fargate):** OIDC federated trust with `sts:AssumeRoleWithWebIdentity`,
  KSA pinned in the `sub` claim.
- `use_irsa` is read from the cluster connection.

Attach managed policies for the enabled exporters:
- `AWSXrayWriteOnlyAccess` (X-Ray)
- `CloudWatchAgentServerPolicy` (EMF metrics + CW logs)
- `AmazonPrometheusRemoteWriteAccess` (only when AMP enabled)

The collector's `serviceAccount` in the CR is the KSA bound to this role.

---

## 7. RBAC for `k8sattributes`

The `k8sattributes` processor needs a `ClusterRole` + `ClusterRoleBinding` granting
`get/list/watch` on `pods`, `namespaces`, `nodes`, `replicasets` — same as the GKE module's
`service-account.tf`.

---

## 8. Providers & cluster auth

- `kubernetes` provider authenticated via `ephemeral "aws_eks_cluster_auth"` (host / CA from the
  cluster-namespace connection), as in `aws-eks-app/cluster-namespace.tf`.
- `gavinbunney/kubectl` provider for `kubectl_manifest` (the CR) — same auth inputs.
  - Rationale: `hashicorp/kubernetes`'s `kubernetes_manifest` performs a plan-time CRD-schema
    lookup that fails when the CRD isn't yet present in the cluster.

---

## 9. Proposed file layout

```
aws/aws-eks-adot/
├── .nullstone/
│   └── module.yml          # category: datastore, provider_types: [aws],
│                           # platform: otel, subplatform: eks, tool_name: opentofu,
│                           # include: [collector.yml.tftpl or inline]
├── cluster-namespace.tf    # ns_connection + kubernetes/kubectl provider auth
├── collector.tf            # OpenTelemetryCollector CR (kubectl_manifest), config assembly + merge
├── config.tf               # base spec.config locals (receivers/processors/exporters/service)
├── extender.tf             # ns_connection extender (optional), namespace-match precondition
├── iam.tf                  # aws_iam_role, assume policies, pod-identity assoc, policy attachments
├── service-account.tf      # KSA + ClusterRole/Binding for k8sattributes
├── outputs.tf              # kubernetes_namespace, grpc_endpoint, http_endpoint
├── variables.tf            # collector_version, cpu, memory, memory_limit,
│                           # min_replicas, max_replicas, enable_amp, amp_workspace_*, etc.
└── providers.tf            # required_providers: kubernetes, kubectl, aws
```

---

## 10. Variables (initial)

| Variable | Default | Purpose |
| --- | --- | --- |
| `collector_version` | (pinned) | ADOT collector image tag |
| `cpu` / `memory` / `memory_limit` | mirror GKE | resource requests/limits |
| `min_replicas` / `max_replicas` | mirror GKE | autoscaler bounds |
| `enable_amp` | `false` | turn on `prometheusremotewrite` + `sigv4auth` |
| `amp_workspace_endpoint` / `amp_region` | `""` | AMP remote-write target (when enabled) |
| `aws_region` | from connection | exporter region config |

---

## 11. Outputs (parity with GKE)

```hcl
output "kubernetes_namespace" { value = local.kubernetes_namespace }
output "grpc_endpoint"        { value = "${local.collector_service}.${local.kubernetes_namespace}:4317" }
output "http_endpoint"        { value = "${local.collector_service}.${local.kubernetes_namespace}:4318" }
```

where `local.collector_service = "${resource_name}-collector"` (operator naming).

---

## 12. Open questions (must resolve before coding)

1. **Operator ownership** — install ADOT operator + cert-manager via the EKS cluster module as a
   prerequisite (recommended), or assume pre-installed? Confirm whether `aws-eks-standard` /
   `aws-eks-auto` guarantee the `adot` add-on + cert-manager.
2. **AMP default** — confirm CloudWatch EMF default with AMP opt-in (vs. AMP primary).
3. **`kubectl` provider** — accept `gavinbunney/kubectl` as a new dependency (recommended) vs.
   `hashicorp/kubernetes` `kubernetes_manifest`.

---

## 13. Implementation sequence

1. Resolve Open Questions 1–3.
2. Add `collector-config-fragments` output to `k8s-otel-langfuse-extender` (no behavior change for
   GKE).
3. Scaffold `aws/aws-eks-adot/` with `.nullstone/module.yml` + providers + cluster auth.
4. Build base `spec.config` locals (§4) and the deep-merge of extender fragments (§5).
5. Render the `OpenTelemetryCollector` CR via `kubectl_manifest` (§3).
6. Add IAM (§6), RBAC (§7), outputs (§11).
7. Validate against a cluster with the ADOT operator present; confirm OTLP endpoints and that an
   extender (Langfuse) pipeline activates.
