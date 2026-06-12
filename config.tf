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

  // ---- processors (always present) ----
  base_processors = {
    memory_limiter = {
      check_interval         = "1s"
      limit_percentage       = 65
      spike_limit_percentage = 20
    }
    batch = {
      send_batch_size     = 200
      send_batch_max_size = 200
      timeout             = "5s"
    }
    k8sattributes = {
      passthrough = false
      extract = {
        metadata = [
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
      }
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
  aws_exporters = var.enable_aws_sinks ? merge(
    {
      awsxray = { region = local.aws_region }
      awscloudwatchlogs = {
        region          = local.aws_region
        log_group_name  = "/aws/eks/otel/${local.resource_name}"
        log_stream_name = "otel-collector"
      }
      prometheusremotewrite = {
        endpoint = local.amp_remote_write_endpoint
        auth     = { authenticator = "sigv4auth" }
      }
    },
    var.enable_cloudwatch_metrics ? { awsemf = { region = local.aws_region, namespace = local.block_name } } : {},
  ) : {}

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

  // ---- deep-merge extender fragments onto the base config ----
  // Maps merge recursively at the component level (each fragment adds its own keys). service.extensions
  // is concatenated (not replaced). When no extender is connected, frag is [] and merged_config == base.
  frag = local.extender_fragments

  merged_config = {
    receivers  = merge(local.base_config.receivers, [for f in local.frag : try(f.receivers, {})]...)
    processors = merge(local.base_config.processors, [for f in local.frag : try(f.processors, {})]...)
    exporters  = merge(local.base_config.exporters, [for f in local.frag : try(f.exporters, {})]...)
    extensions = merge(local.base_config.extensions, [for f in local.frag : try(f.extensions, {})]...)
    service = {
      extensions = distinct(concat(local.base_config.service.extensions, flatten([for f in local.frag : try(f.service.extensions, [])])))
      pipelines  = merge(local.base_config.service.pipelines, [for f in local.frag : try(f.service.pipelines, {})]...)
    }
  }
}
