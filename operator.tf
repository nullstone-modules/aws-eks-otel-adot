// The OpenTelemetry/ADOT operator registers the OpenTelemetryCollector CRD and reconciles the CR
// (collector.tf) into a Deployment + Services. Its admission webhook requires cert-manager, which
// the cluster module (aws-eks-standard / aws-eks-auto) installs.
//
// The operator is CLUSTER-SCOPED (one per cluster), but this module is per-cluster-namespace. When
// more than one otel collector datastore targets the same cluster, set install_operator = false on
// the additional instances so they reuse the already-installed operator instead of colliding.
resource "helm_release" "operator" {
  count = var.install_operator ? 1 : 0

  name             = "opentelemetry-operator"
  repository       = "https://open-telemetry.github.io/opentelemetry-helm-charts"
  chart            = "opentelemetry-operator"
  version          = var.operator_chart_version
  namespace        = "opentelemetry-operator-system"
  create_namespace = true
  atomic           = true
  wait             = true # operator Deployment + CRD must be ready before the CR is applied
}
