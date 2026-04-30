# ----------------------------------------------------------------------------
# Mount discovery.
#
# sys/mounts returns { "<mount-path>/": { type, accessor, ... }, ... }. We
# filter to type == "gcp", strip the trailing slash from each key, and split
# on "/". A valid migration mount path is exactly:
#   <env>/<app>/gcp
# Anything else (1, 2, or 4+ segments, or third segment != "gcp") fails the
# plan via the precondition on the dynamic_secret resource.
# ----------------------------------------------------------------------------

locals {
  sys_mounts_raw = jsondecode(data.http.list_mounts.response_body)

  # Vault returns mounts under either the top-level keys (KV-style listing)
  # or under .data depending on the API path. /v1/sys/mounts returns the
  # keys at the top level, plus a "data" mirror.
  sys_mounts_map = try(local.sys_mounts_raw.data, local.sys_mounts_raw)

  gcp_mounts_all = {
    for raw_path, info in local.sys_mounts_map :
    trimsuffix(raw_path, "/") => info
    if try(info.type, "") == "gcp"
  }

  # Validation. A valid mount path splits cleanly on "/" into exactly three
  # non-empty segments and the third is the literal "gcp".
  invalid_mount_paths = [
    for mp, _ in local.gcp_mounts_all :
    mp if(
      length(split("/", mp)) != 3
      || length([for s in split("/", mp) : s if s == ""]) > 0
      || split("/", mp)[2] != "gcp"
    )
  ]

  # Final usable map: { "<env>/<app>/gcp" = { env = ..., app = ... } }
  gcp_mounts = {
    for mp, _ in local.gcp_mounts_all :
    mp => {
      env = split("/", mp)[0]
      app = split("/", mp)[1]
    }
    if !contains(local.invalid_mount_paths, mp)
  }
}

# ----------------------------------------------------------------------------
# Per-mount LIST results, flattened into maps keyed by
# "<mount_path>/<kind>/<name>" so the per-entity reads can be driven by a
# single for_each.
# 200 => parse {data.keys}; 404 => empty list.
# ----------------------------------------------------------------------------

locals {
  static_account_paths = merge([
    for mp, _ in local.gcp_mounts : {
      for name in(
        data.http.list_static_accounts[mp].status_code == 200
        ? jsondecode(data.http.list_static_accounts[mp].response_body).data.keys
        : []
      ) :
      "${mp}/static-account/${name}" => {
        mount = mp
        name  = name
      }
    }
  ]...)

  impersonated_account_paths = merge([
    for mp, _ in local.gcp_mounts : {
      for name in(
        data.http.list_impersonated_accounts[mp].status_code == 200
        ? jsondecode(data.http.list_impersonated_accounts[mp].response_body).data.keys
        : []
      ) :
      "${mp}/impersonated-account/${name}" => {
        mount = mp
        name  = name
      }
    }
  ]...)

  roleset_paths = merge([
    for mp, _ in local.gcp_mounts : {
      for name in(
        data.http.list_rolesets[mp].status_code == 200
        ? jsondecode(data.http.list_rolesets[mp].response_body).data.keys
        : []
      ) :
      "${mp}/roleset/${name}" => {
        mount = mp
        name  = name
      }
    }
  ]...)
}

# ----------------------------------------------------------------------------
# Build the unified migration map.
#
# Key:   "<env>/<app>/<vault_type>/<entity_name>"
#        e.g. "prod/app-1234-saas/static-account/db-static"
# Value: an object with the bits we need to drive the akeyless dynamic secret
#        plus the computed Akeyless DS path:
#          <env>/<app>/gcp/rolesets/<entity_name>
#        All three Vault types collapse into the same gcp/rolesets/ folder.
# ----------------------------------------------------------------------------

locals {
  static_account_entries = {
    for path_key, ref in local.static_account_paths :
    "${local.gcp_mounts[ref.mount].env}/${local.gcp_mounts[ref.mount].app}/static-account/${ref.name}" => {
      env           = local.gcp_mounts[ref.mount].env
      app           = local.gcp_mounts[ref.mount].app
      vault_mount   = ref.mount
      vault_type    = "static-account"
      vault_name    = ref.name
      akeyless_name = "${local.gcp_mounts[ref.mount].env}/${local.gcp_mounts[ref.mount].app}/gcp/rolesets/${ref.name}"
      sa_email      = try(data.vault_generic_secret.static_account[path_key].data["service_account_email"], null)
      cred_type     = try(data.vault_generic_secret.static_account[path_key].data["secret_type"], null) == "service_account_key" ? "key" : "token"
      token_scopes  = try(jsondecode(data.vault_generic_secret.static_account[path_key].data["token_scopes"]), [])
      mode          = "static-account"
    }
  }

  impersonated_account_entries = {
    for path_key, ref in local.impersonated_account_paths :
    "${local.gcp_mounts[ref.mount].env}/${local.gcp_mounts[ref.mount].app}/impersonated-account/${ref.name}" => {
      env           = local.gcp_mounts[ref.mount].env
      app           = local.gcp_mounts[ref.mount].app
      vault_mount   = ref.mount
      vault_type    = "impersonated-account"
      vault_name    = ref.name
      akeyless_name = "${local.gcp_mounts[ref.mount].env}/${local.gcp_mounts[ref.mount].app}/gcp/rolesets/${ref.name}"
      sa_email      = try(data.vault_generic_secret.impersonated_account[path_key].data["service_account_email"], null)
      cred_type     = "token"
      token_scopes  = try(jsondecode(data.vault_generic_secret.impersonated_account[path_key].data["token_scopes"]), [])
      mode          = "impersonated-account"
    }
  }

  roleset_entries = {
    for path_key, ref in local.roleset_paths :
    "${local.gcp_mounts[ref.mount].env}/${local.gcp_mounts[ref.mount].app}/roleset/${ref.name}" => {
      env           = local.gcp_mounts[ref.mount].env
      app           = local.gcp_mounts[ref.mount].app
      vault_mount   = ref.mount
      vault_type    = "roleset"
      vault_name    = ref.name
      akeyless_name = "${local.gcp_mounts[ref.mount].env}/${local.gcp_mounts[ref.mount].app}/gcp/rolesets/${ref.name}"
      sa_email      = try(var.roleset_sa_overrides["${local.gcp_mounts[ref.mount].env}/${local.gcp_mounts[ref.mount].app}/${ref.name}"], null)
      cred_type     = "token"
      token_scopes  = try(jsondecode(data.vault_generic_secret.roleset[path_key].data["token_scopes"]), [])
      mode          = "roleset (override SA)"
    }
  }

  migration_map = merge(
    local.static_account_entries,
    local.impersonated_account_entries,
    local.roleset_entries,
  )

  # Rolesets discovered in Vault but missing from the override map. Keys are
  # "<env>/<app>/<roleset_name>" since roleset names can collide across apps.
  rolesets_missing_override = [
    for path_key, ref in local.roleset_paths :
    "${local.gcp_mounts[ref.mount].env}/${local.gcp_mounts[ref.mount].app}/${ref.name}"
    if !contains(
      keys(var.roleset_sa_overrides),
      "${local.gcp_mounts[ref.mount].env}/${local.gcp_mounts[ref.mount].app}/${ref.name}"
    )
  ]
}
