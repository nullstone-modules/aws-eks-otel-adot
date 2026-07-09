// IAM for the collector's Kubernetes service account. Only provisioned when AWS sinks are enabled —
// in extender-only mode the collector needs no AWS permissions (extender exporters authenticate
// independently, e.g. via Authorization headers).

locals {
  oidc_issuer_noproto = replace(local.cluster_oidc_issuer, "https://", "")
  collector_role_arn  = var.enable_aws_sinks ? aws_iam_role.collector[0].arn : null

  collector_managed_policies = var.enable_aws_sinks ? [
    "arn:aws:iam::aws:policy/AmazonPrometheusRemoteWriteAccess", // metrics -> AMP
    "arn:aws:iam::aws:policy/AWSXrayWriteOnlyAccess",            // traces -> X-Ray
    "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy",       // logs -> CloudWatch Logs (+ EMF metrics)
  ] : []
}

// Pod Identity assume policy (managed node groups).
data "aws_iam_policy_document" "assume" {
  statement {
    sid     = "AllowEKSAuthToAssumeRoleForPodIdentity"
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

// IRSA assume policy (Fargate, where Pod Identity is unavailable).
data "aws_iam_policy_document" "irsa_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.cluster_openid_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_noproto}:sub"
      values   = ["system:serviceaccount:${local.kubernetes_namespace}:${local.collector_sa_name}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_noproto}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "collector" {
  count = var.enable_aws_sinks ? 1 : 0

  name               = local.resource_name
  tags               = local.tags
  assume_role_policy = local.use_irsa ? data.aws_iam_policy_document.irsa_assume.json : data.aws_iam_policy_document.assume.json
}

resource "aws_eks_pod_identity_association" "collector" {
  count = var.enable_aws_sinks && !local.use_irsa ? 1 : 0

  cluster_name    = local.cluster_name
  namespace       = local.kubernetes_namespace
  service_account = local.collector_sa_name
  role_arn        = aws_iam_role.collector[0].arn
}

resource "aws_iam_role_policy_attachment" "collector" {
  for_each = toset(local.collector_managed_policies)

  role       = aws_iam_role.collector[0].name
  policy_arn = each.value
}
