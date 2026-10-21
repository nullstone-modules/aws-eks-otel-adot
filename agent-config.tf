// Assembles spec.config for the infra metrics agent (agent.tf). The agent scrapes its node's kubelet
// with kubeletstats and exports ONLY to the connected extender: its pipelines are the extender
// fragments' `metrics*` pipelines with the receiver swapped to kubeletstats. The AWS sinks are never
// referenced here.

locals {
  // Namespaces whose pod/container metrics are kept. Default: the connected cluster-namespace.
  infra_namespaces = coalescelist(var.infra_namespaces, [local.kubernetes_namespace])

  agent_own_processors = {
    memory_limiter = {
      check_interval         = "1s"
      limit_percentage       = 65
      spike_limit_percentage = 20
    }
    // Node-scoped (watches only this node's pods). Associates by pod UID, which kubeletstats sets on
    // every pod/container resource; node resources have none and are left untouched.
    k8sattributes = {
      passthrough = false
      filter      = { node_from_env_var = "K8S_NODE_NAME" }
      extract     = { metadata = local.k8sattributes_metadata }
      pod_association = [
        { sources = [{ from = "resource_attribute", name = "k8s.pod.uid" }] },
      ]
    }
    // Drops pod/container metrics outside infra_namespaces. Node metrics carry no namespace and pass.
    "filter/namespaces" = {
      error_mode = "ignore"
      metrics = {
        metric = [
          "resource.attributes[\"k8s.namespace.name\"] != nil and not IsMatch(resource.attributes[\"k8s.namespace.name\"], \"^(${join("|", local.infra_namespaces)})$\")",
        ]
      }
    }
    "resource/infra" = {
      attributes = [
        { key = "k8s.cluster.name", value = local.cluster_name, action = "upsert" },
        { key = "deployment.environment", value = local.env_name, action = "upsert" },
      ]
    }
    batch = {
      send_batch_size     = 2000
      send_batch_max_size = 2000
      timeout             = "10s"
    }
  }

  agent_pipeline_processors = ["memory_limiter", "k8sattributes", "filter/namespaces", "resource/infra", "batch"]

  // Processors an extender pipeline names that the agent defines itself. Any other processor it names
  // is appended; the extender ships its definition in the fragment's processors map.
  agent_shared_processors = ["memory_limiter", "k8sattributes", "batch"]

  // One pipeline per extender `metrics*` pipeline, fed by kubeletstats instead of otlp.
  agent_pipelines = merge({}, [
    for f in local.extender_fragments : {
      for k, p in try(f.service.pipelines, {}) : k => {
        receivers  = ["kubeletstats"]
        processors = concat(local.agent_pipeline_processors, [for n in try(p.processors, []) : n if !contains(local.agent_shared_processors, n)])
        exporters  = try(p.exporters, [])
      } if startswith(k, "metrics")
    }
  ]...)

  agent_config = {
    receivers = {
      kubeletstats = {
        collection_interval  = var.agent_collection_interval
        auth_type            = "serviceAccount"
        endpoint             = "https://$${env:K8S_NODE_IP}:10250"
        insecure_skip_verify = true
        metric_groups        = ["node", "pod", "container"]
      }
    }
    // Extender components first, the agent's own last so its processor definitions win on collision.
    processors = merge(merge({}, [for f in local.extender_fragments : try(f.processors, {})]...), local.agent_own_processors)
    exporters  = merge({}, [for f in local.extender_fragments : try(f.exporters, {})]...)
    extensions = merge({ health_check = { endpoint = "0.0.0.0:13133" } }, [for f in local.extender_fragments : try(f.extensions, {})]...)
    service = {
      extensions = distinct(concat(["health_check"], flatten([for f in local.extender_fragments : try(f.service.extensions, [])])))
      pipelines  = local.agent_pipelines
    }
  }
}
