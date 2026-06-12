locals {
  collector_sa_name = local.resource_name
}

resource "kubernetes_service_account_v1" "collector" {
  metadata {
    namespace = local.kubernetes_namespace
    name      = local.collector_sa_name

    // IRSA: annotate the KSA with the role it can impersonate. Pod Identity uses an association
    // (iam.tf) instead, so no annotation is needed there.
    annotations = (var.enable_aws_sinks && local.use_irsa) ? {
      "eks.amazonaws.com/role-arn" = local.collector_role_arn
    } : {}
  }

  automount_service_account_token = true
}

// The k8sattributes processor (present in the base config regardless of sinks) needs to read pod /
// namespace / node / replicaset metadata cluster-wide.
resource "kubernetes_cluster_role_v1" "collector" {
  metadata {
    name = local.resource_name
  }

  rule {
    api_groups = [""]
    resources  = ["pods", "namespaces", "nodes"]
    verbs      = ["get", "watch", "list"]
  }

  rule {
    api_groups = ["apps"]
    resources  = ["replicasets"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["extensions"]
    resources  = ["replicasets"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "collector" {
  metadata {
    name = local.resource_name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.collector.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.collector.metadata[0].name
    namespace = kubernetes_service_account_v1.collector.metadata[0].namespace
  }
}
