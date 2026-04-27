# ----------------------------------------------------------------------------
# Discovery (live LIST against the Vault HTTP API)
#
# The hashicorp/vault provider has no generic LIST data source for arbitrary
# mounts. We use the hashicorp/http provider to call Vault's LIST verb via
# the `?list=true` GET form against:
#   <vault_address>/v1/<mount>/static-account
#   <vault_address>/v1/<mount>/impersonated-account
#   <vault_address>/v1/<mount>/roleset
#
# Vault returns 200 with `{"data":{"keys":[...]}}` when entries exist, and
# 404 with `{"errors":[]}` when the path has no entries. Anything else
# (401/403/5xx) is a real error and we fail the plan via postcondition.
#
# After LIST, per-entity reads use the vault provider's vault_generic_secret
# data source. So enumeration is via http; field extraction is via vault.
# ----------------------------------------------------------------------------

locals {
  vault_base_url = "${trimsuffix(var.vault_address, "/")}/v1/${var.vault_gcp_mount}"
}

data "http" "list_static_accounts" {
  url = "${local.vault_base_url}/static-account?list=true"
  request_headers = {
    "X-Vault-Token" = var.vault_token
    "Accept"        = "application/json"
  }

  lifecycle {
    postcondition {
      condition     = contains([200, 404], self.status_code)
      error_message = "Vault LIST ${var.vault_gcp_mount}/static-account returned HTTP ${self.status_code}. Body: ${self.response_body}"
    }
  }
}

data "http" "list_impersonated_accounts" {
  url = "${local.vault_base_url}/impersonated-account?list=true"
  request_headers = {
    "X-Vault-Token" = var.vault_token
    "Accept"        = "application/json"
  }

  lifecycle {
    postcondition {
      condition     = contains([200, 404], self.status_code)
      error_message = "Vault LIST ${var.vault_gcp_mount}/impersonated-account returned HTTP ${self.status_code}. Body: ${self.response_body}"
    }
  }
}

data "http" "list_rolesets" {
  url = "${local.vault_base_url}/roleset?list=true"
  request_headers = {
    "X-Vault-Token" = var.vault_token
    "Accept"        = "application/json"
  }

  lifecycle {
    postcondition {
      condition     = contains([200, 404], self.status_code)
      error_message = "Vault LIST ${var.vault_gcp_mount}/roleset returned HTTP ${self.status_code}. Body: ${self.response_body}"
    }
  }
}

# Per-entity reads. Each map is keyed by the Vault entity name; the value is
# the data source itself, so locals.tf can pull .data["service_account_email"]
# etc. The for_each set is computed in locals.tf from the http responses.

data "vault_generic_secret" "static_account" {
  for_each = toset(local.static_account_names)
  path     = "${var.vault_gcp_mount}/static-account/${each.value}"
}

data "vault_generic_secret" "impersonated_account" {
  for_each = toset(local.impersonated_account_names)
  path     = "${var.vault_gcp_mount}/impersonated-account/${each.value}"
}

data "vault_generic_secret" "roleset" {
  for_each = toset(local.roleset_names)
  path     = "${var.vault_gcp_mount}/roleset/${each.value}"
}
