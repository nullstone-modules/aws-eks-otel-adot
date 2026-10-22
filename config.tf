// Assembles the collector's spec.config (OTEL v1beta1 structured object). The base config wires OTLP
// receivers + shared processors and, when enable_aws_sinks is true, the AWS exporters/pipelines.
// Extender fragments (structured) are deep-merged on top: maps merge recursively; service.extensions
// is concatenated so an extender can activate its own extensions.

locals {
  // ---- AMP remote-write target (only when AWS sinks are enabled) ----
  amp_remote_write_endpoint = var.enable_aws_sinks ? "${aws_prometheus_workspace.this[0].prometheus_endpoint}api/v1/remote_write" : ""

  // ---- receivers (always present) ----
  base_receivers = {
    otlp = {
      protocols = {
        grpc = { endpoint = "0.0.0.0:4317" }
        http = { endpoint = "0.0.0.0:4318" }
      }
    }
  }

  // Pod metadata attached by k8sattributes in both collectors.
  k8sattributes_metadata = [
    "k8s.namespace.name",
    "k8s.deployment.name",
    "k8s.statefulset.name",
    "k8s.daemonset.name",
    "k8s.cronjob.name",
    "k8s.job.name",
    "k8s.replicaset.name",
    "k8s.node.name",
    "k8s.pod.name",
    "k8s.pod.uid",
    "k8s.pod.start_time",
  ]
  // ---- processors (always present) ----
  base_processors = {
    memory_limiter = {
      check_interval         = "1s"
      limit_percentage       = 80
      spike_limit_percentage = 25
    }
    batch = {
      send_batch_size     = var.batch_size
      send_batch_max_size = var.batch_max_size
      timeout             = "5s"
    }
    k8sattributes = {
      passthrough = false
      extract     = { metadata = local.k8sattributes_metadata }
      pod_association = [
        { sources = [{ from = "resource_attribute", name = "k8s.pod.ip" }] },
        { sources = [{ from = "resource_attribute", name = "k8s.pod.uid" }] },
        { sources = [{ from = "connection" }] },
      ]
    }
  }

  // Shared processor chain referenced by every base pipeline (order matters: limit, enrich, batch).
  base_pipeline_processors = ["memory_limiter", "k8sattributes", "batch"]

  // ---- extensions ----
  base_extensions = merge(
    { health_check = { endpoint = "0.0.0.0:13133" } },
    var.enable_aws_sinks ? { sigv4auth = { region = local.aws_region, service = "aps" } } : {},
  )

  // ---- exporters (only when AWS sinks are enabled) ----
  // Each exporter is gated as its own single-key conditional so the true/false branches share a
  // consistent type (map of one object). A single ternary over the whole heterogeneous object fails
  // because the populated object can't unify with the empty `{}` false branch.
  aws_exporters = merge(
    var.enable_aws_sinks ? { awsxray = { region = local.aws_region } } : {},
    var.enable_aws_sinks ? {
      awscloudwatchlogs = {
        region          = local.aws_region
        log_group_name  = "/aws/eks/otel/${local.resource_name}"
        log_stream_name = "otel-collector"
      }
    } : {},
    var.enable_aws_sinks ? {
      prometheusremotewrite = {
        endpoint = local.amp_remote_write_endpoint
        auth     = { authenticator = "sigv4auth" }
      }
    } : {},
    var.enable_aws_sinks && var.enable_cloudwatch_metrics ? { awsemf = { region = local.aws_region, namespace = local.block_name } } : {},
  )

  // ---- pipelines (only when AWS sinks are enabled) ----
  metrics_exporters = concat(["prometheusremotewrite"], var.enable_cloudwatch_metrics ? ["awsemf"] : [])

  aws_pipelines = var.enable_aws_sinks ? {
    traces  = { receivers = ["otlp"], processors = local.base_pipeline_processors, exporters = ["awsxray"] }
    metrics = { receivers = ["otlp"], processors = local.base_pipeline_processors, exporters = local.metrics_exporters }
    logs    = { receivers = ["otlp"], processors = local.base_pipeline_processors, exporters = ["awscloudwatchlogs"] }
  } : {}

  base_service_extensions = concat(["health_check"], var.enable_aws_sinks ? ["sigv4auth"] : [])

  base_config = {
    receivers  = local.base_receivers
    processors = local.base_processors
    exporters  = local.aws_exporters
    extensions = local.base_extensions
    service = {
      extensions = local.base_service_extensions
      pipelines  = local.aws_pipelines
    }
  }

  // ---- cluster metrics (only when enable_cluster_metrics is true) ----
  // k8s_cluster watches the Kubernetes API for cluster-level state (restarts, pod phase, deployment
  // available/desired, container limits, node conditions). It runs on one replica at a time via the
  // k8s_leader_elector extension so a scaled-out gateway never double-counts. Its output goes through
  // its own metrics/k8s_cluster pipeline (namespace filter + cluster/env stamp, shared with the agent)
  // and then, via a forward connector, into every extender `metrics*` pipeline. Keeping the filter in
  // a dedicated pipeline means it never touches app metrics arriving over OTLP. The AWS metrics
  // pipeline stays otlp-only.
  cluster_receivers = var.enable_cluster_metrics ? {
    k8s_cluster = {
      auth_type                   = "serviceAccount"
      collection_interval         = var.cluster_collection_interval
      node_conditions_to_report   = ["Ready", "MemoryPressure", "DiskPressure"]
      allocatable_types_to_report = ["cpu", "memory"]
      k8s_leader_elector          = "k8s_leader_elector"
    }
  } : {}

  cluster_extensions = var.enable_cluster_metrics ? {
    k8s_leader_elector = {
      auth_type       = "serviceAccount"
      lease_name      = "${local.resource_name}-k8s-cluster"
      lease_namespace = local.kubernetes_namespace
    }
  } : {}

  cluster_connector  = "forward/k8s_cluster"
  cluster_connectors = var.enable_cluster_metrics ? { (local.cluster_connector) = {} } : {}
  cluster_processors = { for k, v in local.infra_processors : k => v if var.enable_cluster_metrics }

  cluster_pipelines = var.enable_cluster_metrics ? {
    "metrics/k8s_cluster" = {
      receivers  = ["k8s_cluster"]
      processors = ["memory_limiter", "filter/namespaces", "resource/infra"]
      exporters  = [local.cluster_connector]
    }
  } : {}

  cluster_service_extensions = var.enable_cluster_metrics ? ["k8s_leader_elector"] : []

  // ---- deep-merge extender fragments onto the base config ----
  // Maps merge recursively at the component level (each fragment adds its own keys). service.extensions
  // is concatenated (not replaced). When no extender is connected, frag is [] and merged_config == base.
  frag = local.extender_fragments

  extender_pipelines = merge({}, [for f in local.frag : try(f.service.pipelines, {})]...)

  // With cluster metrics on, every extender `metrics*` pipeline also receives the forwarded k8s_cluster output.
  extender_pipelines_with_cluster = merge(local.extender_pipelines, {
    for k, p in local.extender_pipelines : k => merge(p, {
      receivers = concat(try(p.receivers, []), [local.cluster_connector])
    }) if var.enable_cluster_metrics && startswith(k, "metrics")
  })

  merged_config = merge(
    {
      receivers  = merge(local.base_config.receivers, concat([for f in local.frag : try(f.receivers, {})], [local.cluster_receivers])...)
      processors = merge(local.base_config.processors, concat([for f in local.frag : try(f.processors, {})], [local.cluster_processors])...)
      exporters  = merge(local.base_config.exporters, [for f in local.frag : try(f.exporters, {})]...)
      extensions = merge(local.base_config.extensions, concat([for f in local.frag : try(f.extensions, {})], [local.cluster_extensions])...)
      service = {
        extensions = distinct(concat(local.base_config.service.extensions, flatten([for f in local.frag : try(f.service.extensions, [])]), local.cluster_service_extensions))
        pipelines  = merge(local.base_config.service.pipelines, local.extender_pipelines_with_cluster, local.cluster_pipelines)
      }
    },
    // The connectors key is only present when cluster metrics are on, so the disabled config is unchanged.
    var.enable_cluster_metrics ? { connectors = local.cluster_connectors } : {},
  )
}
