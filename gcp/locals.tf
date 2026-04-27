# ----------------------------------------------------------------------------
# Names extracted from the Vault LIST responses.
# 200 => parse {data.keys}; 404 => empty list (no entries of that kind).
# ----------------------------------------------------------------------------

locals {
  static_account_names = (
    data.http.list_static_accounts.status_code == 200
    ? jsondecode(data.http.list_static_accounts.response_body).data.keys
    : []
  )

  impersonated_account_names = (
    data.http.list_impersonated_accounts.status_code == 200
    ? jsondecode(data.http.list_impersonated_accounts.response_body).data.keys
    : []
  )

  roleset_names = (
    data.http.list_rolesets.status_code == 200
    ? jsondecode(data.http.list_rolesets.response_body).data.keys
    : []
  )
}

# ----------------------------------------------------------------------------
# Build the unified migration map.
# Key:   "<vault-type>/<name>"           e.g. "static-account/my-app"
# Value: an object with the bits we need to drive the akeyless dynamic secret.
# ----------------------------------------------------------------------------

locals {
  # static-account: Vault stores service_account_email,
  # secret_type ("access_token" | "service_account_key"),
  # token_scopes (JSON-encoded list when present in the response data map).
  static_account_entries = {
    for name, ds in data.vault_generic_secret.static_account :
    "static-account/${name}" => {
      vault_type   = "static-account"
      vault_name   = name
      sa_email     = try(ds.data["service_account_email"], null)
      cred_type    = try(ds.data["secret_type"], null) == "service_account_key" ? "key" : "token"
      token_scopes = try(jsondecode(ds.data["token_scopes"]), [])
      mode         = "static-account"
    }
  }

  # impersonated-account: always token-type.
  impersonated_account_entries = {
    for name, ds in data.vault_generic_secret.impersonated_account :
    "impersonated-account/${name}" => {
      vault_type   = "impersonated-account"
      vault_name   = name
      sa_email     = try(ds.data["service_account_email"], null)
      cred_type    = "token"
      token_scopes = try(jsondecode(ds.data["token_scopes"]), [])
      mode         = "impersonated-account"
    }
  }

  # roleset: no static SA email; operator supplies one via roleset_sa_overrides.
  roleset_entries = {
    for name, ds in data.vault_generic_secret.roleset :
    "roleset/${name}" => {
      vault_type   = "roleset"
      vault_name   = name
      sa_email     = try(var.roleset_sa_overrides[name], null)
      cred_type    = "token"
      token_scopes = try(jsondecode(ds.data["token_scopes"]), [])
      mode         = "roleset (override SA)"
    }
  }

  # Single map driving the akeyless_dynamic_secret_gcp for_each.
  migration_map = merge(
    local.static_account_entries,
    local.impersonated_account_entries,
    local.roleset_entries,
  )

  # Rolesets discovered in Vault but missing from the override map.
  # The hard-fail precondition lives on the akeyless_dynamic_secret_gcp
  # resource (dynamic_secrets.tf) so plan refuses, not just warns.
  rolesets_missing_override = [
    for name in local.roleset_names :
    name if !contains(keys(var.roleset_sa_overrides), name)
  ]
}
