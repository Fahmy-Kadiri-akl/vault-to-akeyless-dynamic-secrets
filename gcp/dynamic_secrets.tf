# One akeyless_dynamic_secret_gcp per discovered Vault entity.
#
# Docs: https://registry.terraform.io/providers/akeyless-community/akeyless/latest/docs/resources/dynamic_secret_gcp
#
# Field choices:
#   - access_type           = "sa"      (we're producing SA-bound credentials, not external/federation tokens)
#   - service_account_type  = "fixed"   (we always reference an existing SA email; this is a true 1:1 with Vault
#                                        static and impersonated entries. Rolesets need an operator-supplied
#                                        durable SA, see locals.tf.)
#   - gcp_cred_type         = "token" or "key", from local.migration_map[*].cred_type
#   - gcp_sa_email          = local.migration_map[*].sa_email
#   - gcp_token_scopes      = comma-separated string per provider docs
#                             (provider takes a String, "scope1,scope2", not a list)
#   - target_name           = the akeyless_target_gcp we created
resource "akeyless_dynamic_secret_gcp" "migrated" {
  for_each = local.migration_map

  name                 = "${var.akeyless_path_prefix}/${each.key}"
  target_name          = akeyless_target_gcp.migrated_from_vault.name
  access_type          = "sa"
  service_account_type = "fixed"
  gcp_cred_type        = each.value.cred_type
  gcp_sa_email         = each.value.sa_email
  gcp_token_scopes     = join(",", each.value.token_scopes)

  # Refuse to apply if any roleset lacks an override, OR if the discovered
  # data is missing a service-account email for some other reason. Names the
  # offenders in the error message so the operator can fix and retry.
  lifecycle {
    precondition {
      condition = length(local.rolesets_missing_override) == 0
      error_message = format(
        "The following Vault rolesets have no entry in var.roleset_sa_overrides: %s. See gcp/README.md \"Rolesets\" for how to mint a durable service account per roleset and supply its email.",
        join(", ", local.rolesets_missing_override),
      )
    }
    precondition {
      condition     = each.value.sa_email != null && each.value.sa_email != ""
      error_message = "Vault entity ${each.key} has no service_account_email available. For static-account / impersonated-account this means Vault returned no email field; for roleset, fill in var.roleset_sa_overrides[\"${each.value.vault_name}\"]."
    }
  }
}
