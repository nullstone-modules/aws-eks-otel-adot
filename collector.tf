// The OpenTelemetryCollector custom resource. The operator reconciles it into a Deployment and the
// Services (<name>-collector, -headless, -monitoring). Applied with gavinbunney/kubectl so the CRD
// (installed by helm_release.operator in this same apply) need not exist at plan time.

locals {
  collector_spec = merge(
    {
      mode           = "deployment"
      image          = var.collector_image
      serviceAccount = local.collector_sa_name
      replicas       = var.min_replicas
      resources = {
        requests = { cpu = var.cpu, memory = var.memory }
        limits   = { memory = var.memory_limit }
      }
      config = local.merged_config
    },
    // Only enable the autoscaler when there is a range to scale across (it requires metrics-server).
    var.max_replicas > var.min_replicas ? {
      autoscaler = { minReplicas = var.min_replicas, maxReplicas = var.max_replicas }
    } : {},
  )
}

resource "kubectl_manifest" "collector" {
  yaml_body = yamlencode({
    apiVersion = "opentelemetry.io/v1beta1"
    kind       = "OpenTelemetryCollector"
    metadata = {
      name      = local.resource_name
      namespace = local.kubernetes_namespace
      labels = {
        "app.kubernetes.io/name"       = local.block_name
        "app.kubernetes.io/managed-by" = "nullstone"
      }
    }
    spec = local.collector_spec
  })

  depends_on = [
    helm_release.operator,
    kubernetes_service_account_v1.collector,
    kubernetes_cluster_role_binding_v1.collector,
    aws_eks_pod_identity_association.collector,
    aws_iam_role_policy_attachment.collector,
  ]

  lifecycle {
    precondition {
      condition     = var.enable_aws_sinks || local.extender_connected
      error_message = "With enable_aws_sinks = false the collector has no sinks of its own; an `extender` connection must be wired so telemetry has somewhere to go."
    }

    precondition {
      condition     = !local.extender_connected || local.extender_namespace == local.kubernetes_namespace
      error_message = "The `extender` connection must target the same cluster-namespace as this collector (its kubernetes_namespace must match)."
    }
  }
}
