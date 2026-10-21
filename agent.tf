// The infra metrics agent: a second OpenTelemetryCollector CR run as a DaemonSet so every node is
// scraped by its local agent (agent-config.tf). Shares the gateway's image, service account, and
// ClusterRole. It needs no AWS IAM because extender exporters authenticate on their own.

locals {
  agent_spec = merge(
    {
      mode           = "daemonset"
      image          = var.collector_image
      serviceAccount = local.collector_sa_name
      env = [
        { name = "K8S_NODE_NAME", valueFrom = { fieldRef = { fieldPath = "spec.nodeName" } } },
        // The kubelet is reached by node IP: node names are not DNS-resolvable on EKS Auto Mode.
        { name = "K8S_NODE_IP", valueFrom = { fieldRef = { fieldPath = "status.hostIP" } } },
      ]
      // Every node, including tainted ones.
      tolerations = [{ operator = "Exists" }]
      resources = {
        requests = { cpu = var.agent_cpu, memory = var.agent_memory }
        limits   = { memory = var.agent_memory_limit }
      }
      config = local.agent_config
    },
    // Extender credentials, exactly as the gateway loads them (collector.tf); the annotation rolls
    // the pods when they rotate.
    length(local.extender_env_from) > 0 ? { envFrom = local.extender_env_from } : {},
    local.extender_env_version != null ? {
      podAnnotations = { "nullstone.io/extender-env-version" = local.extender_env_version }
    } : {},
  )
}

resource "kubectl_manifest" "agent" {
  count = var.enable_infra_metrics ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "opentelemetry.io/v1beta1"
    kind       = "OpenTelemetryCollector"
    metadata = {
      name      = "${local.resource_name}-agent"
      namespace = local.kubernetes_namespace
      labels = {
        "app.kubernetes.io/name"       = local.block_name
        "app.kubernetes.io/component"  = "agent"
        "app.kubernetes.io/managed-by" = "nullstone"
      }
    }
    spec = local.agent_spec
  })

  depends_on = [
    helm_release.operator,
    kubernetes_service_account_v1.collector,
    kubernetes_cluster_role_binding_v1.collector,
  ]

  lifecycle {
    precondition {
      condition     = local.extender_connected
      error_message = "enable_infra_metrics exports infra metrics only to the connected `extender`; wire an extender connection."
    }

    precondition {
      condition     = !local.use_irsa
      error_message = "enable_infra_metrics runs a DaemonSet that scrapes the kubelet; this is not available on Fargate (use_irsa) clusters."
    }
  }
}
