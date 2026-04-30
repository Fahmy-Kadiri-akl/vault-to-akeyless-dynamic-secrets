# ----------------------------------------------------------------------------
# Discovery (live LIST against the Vault HTTP API)
#
# The hashicorp/vault provider has no generic LIST data source for arbitrary
# mounts. We use the hashicorp/http provider to call Vault's LIST verb via
# the `?list=true` GET form.
#
# Step 1: GET sys/mounts to enumerate every mount of type "gcp". Each mount
# path must be exactly three non-empty segments: <env>/<app>/gcp.
#
# Step 2: per discovered mount, LIST static-account / impersonated-account /
# roleset. Vault returns 200 on a non-empty path and 404 on an empty one;
# anything else is a real error and fails the plan via postcondition.
#
# Step 3: per discovered entity, READ the entity's data via the vault
# provider's vault_generic_secret data source.
# ----------------------------------------------------------------------------

locals {
  vault_base_url = "${trimsuffix(var.vault_address, "/")}/v1"
}

data "http" "list_mounts" {
  url = "${local.vault_base_url}/sys/mounts"
  request_headers = {
    "X-Vault-Token" = var.vault_token
    "Accept"        = "application/json"
  }

  lifecycle {
    postcondition {
      condition     = self.status_code == 200
      error_message = "Vault GET sys/mounts returned HTTP ${self.status_code}. The token must have `read` on `sys/mounts`. Body: ${self.response_body}"
    }
  }
}

data "http" "list_static_accounts" {
  for_each = local.gcp_mounts

  url = "${local.vault_base_url}/${each.key}/static-account?list=true"
  request_headers = {
    "X-Vault-Token" = var.vault_token
    "Accept"        = "application/json"
  }

  lifecycle {
    postcondition {
      condition     = contains([200, 404], self.status_code)
      error_message = "Vault LIST ${each.key}/static-account returned HTTP ${self.status_code}. Body: ${self.response_body}"
    }
  }
}

data "http" "list_impersonated_accounts" {
  for_each = local.gcp_mounts

  url = "${local.vault_base_url}/${each.key}/impersonated-account?list=true"
  request_headers = {
    "X-Vault-Token" = var.vault_token
    "Accept"        = "application/json"
  }

  lifecycle {
    postcondition {
      condition     = contains([200, 404], self.status_code)
      error_message = "Vault LIST ${each.key}/impersonated-account returned HTTP ${self.status_code}. Body: ${self.response_body}"
    }
  }
}

data "http" "list_rolesets" {
  for_each = local.gcp_mounts

  url = "${local.vault_base_url}/${each.key}/roleset?list=true"
  request_headers = {
    "X-Vault-Token" = var.vault_token
    "Accept"        = "application/json"
  }

  lifecycle {
    postcondition {
      condition     = contains([200, 404], self.status_code)
      error_message = "Vault LIST ${each.key}/roleset returned HTTP ${self.status_code}. Body: ${self.response_body}"
    }
  }
}

# Per-entity reads, keyed by "<mount_path>/<kind>/<name>" so each Vault path
# is uniquely addressable across mounts.

data "vault_generic_secret" "static_account" {
  for_each = local.static_account_paths
  path     = "${each.value.mount}/static-account/${each.value.name}"
}

data "vault_generic_secret" "impersonated_account" {
  for_each = local.impersonated_account_paths
  path     = "${each.value.mount}/impersonated-account/${each.value.name}"
}

data "vault_generic_secret" "roleset" {
  for_each = local.roleset_paths
  path     = "${each.value.mount}/roleset/${each.value.name}"
}
