// An optional "extender" connection contributes additional OTEL config (e.g. an exporter plus a
// traces/<sink> pipeline forwarding to Langfuse) without forking this module. Unlike the GKE module
// (which mounts each fragment as a ConfigMap and lets the collector merge --config files at runtime),
// the ADOT collector's CRD takes a single structured spec.config. So we consume the extender's
// STRUCTURED fragments (collector-config-fragments) and deep-merge them in Terraform (config.tf).
data "ns_connection" "extender" {
  name     = "extender"
  contract = "datastore/aws/otel-extender"
  optional = true
}

locals {
  // Presence flag: wired iff the structured-fragments output resolves (even to []).
  extender_connected = try(data.ns_connection.extender.outputs["collector-config-fragments"], null) != null

  // list(any) of OTEL config fragments; [] when not connected.
  extender_fragments = try(data.ns_connection.extender.outputs["collector-config-fragments"], [])

  // The namespace the extender created its resources in; used to validate it matches this collector.
  extender_namespace = try(data.ns_connection.extender.outputs["kubernetes_namespace"], null)
}
