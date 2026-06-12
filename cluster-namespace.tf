// Connect to the shared cluster-namespace (where the collector runs) and, through it, the cluster
// (for use_irsa / OIDC details). Mirrors aws-eks-app/cluster-namespace.tf.
data "ns_connection" "cluster_namespace" {
  name     = "cluster-namespace"
  contract = "cluster-namespace/aws/k8s:eks"
}

data "ns_connection" "cluster" {
  name     = "cluster"
  contract = "cluster/aws/k8s:eks"
  via      = data.ns_connection.cluster_namespace.name
}

locals {
  cluster_arn                 = data.ns_connection.cluster_namespace.outputs.cluster_arn
  cluster_name                = data.ns_connection.cluster_namespace.outputs.cluster_name
  kubernetes_namespace        = data.ns_connection.cluster_namespace.outputs.kubernetes_namespace
  cluster_endpoint            = data.ns_connection.cluster_namespace.outputs.cluster_endpoint
  cluster_ca_certificate      = data.ns_connection.cluster_namespace.outputs.cluster_ca_certificate
  cluster_oidc_issuer         = try(data.ns_connection.cluster_namespace.outputs.cluster_oidc_issuer, "")
  cluster_openid_provider_arn = try(data.ns_connection.cluster_namespace.outputs.cluster_openid_provider_arn, "")

  // Fargate clusters cannot use Pod Identity; fall back to IRSA when the cluster reports it.
  use_irsa = try(data.ns_connection.cluster.outputs.use_irsa, false)
}

ephemeral "aws_eks_cluster_auth" "cluster" {
  name = local.cluster_name
}

provider "kubernetes" {
  host                   = local.cluster_endpoint
  token                  = ephemeral.aws_eks_cluster_auth.cluster.token
  cluster_ca_certificate = base64decode(local.cluster_ca_certificate)
}

provider "helm" {
  kubernetes = {
    host                   = local.cluster_endpoint
    cluster_ca_certificate = base64decode(local.cluster_ca_certificate)
    token                  = ephemeral.aws_eks_cluster_auth.cluster.token
  }
}

// gavinbunney/kubectl applies the OpenTelemetryCollector CR. Unlike hashicorp/kubernetes's
// kubernetes_manifest, it does NOT perform a plan-time CRD-schema lookup, so it tolerates the CRD
// being installed by the operator (helm_release.operator) within this same apply.
provider "kubectl" {
  host                   = local.cluster_endpoint
  token                  = ephemeral.aws_eks_cluster_auth.cluster.token
  cluster_ca_certificate = base64decode(local.cluster_ca_certificate)
  load_config_file       = false
}
