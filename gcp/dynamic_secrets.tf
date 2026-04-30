# One akeyless_dynamic_secret_gcp per discovered Vault entity, across every
# discovered <env>/<app>/gcp mount. All three Vault types (static-account,
# impersonated-account, roleset) collapse into the same Akeyless folder:
#   <env>/<app>/gcp/rolesets/<entity_name>
#
# Docs: https://registry.terraform.io/providers/akeyless-community/akeyless/latest/docs/resources/dynamic_secret_gcp
#
# Field choices:
#   - access_type           = "sa"      (SA-bound credentials, not federation tokens)
#   - service_account_type  = "fixed"   (always reference an existing SA email)
#   - gcp_cred_type         = "token" or "key", from local.migration_map[*].cred_type
#   - gcp_sa_email          = local.migration_map[*].sa_email
#   - gcp_token_scopes      = comma-separated string per provider docs
#   - target_name           = the akeyless_target_gcp we created
resource "akeyless_dynamic_secret_gcp" "migrated" {
  for_each = local.migration_map

  name                 = each.value.akeyless_name
  target_name          = akeyless_target_gcp.migrated_from_vault.name
  access_type          = "sa"
  service_account_type = "fixed"
  gcp_cred_type        = each.value.cred_type
  gcp_sa_email         = each.value.sa_email
  gcp_token_scopes     = join(",", each.value.token_scopes)

  # Refuse to apply if any Vault mount path is malformed, if any roleset
  # lacks an override, or if a discovered entity has no service-account
  # email. Names the offenders so the operator can fix and retry.
  lifecycle {
    precondition {
      condition = length(local.invalid_mount_paths) == 0
      error_message = format(
        "The following Vault GCP mounts do not match the required <env>/<app>/gcp layout: %s. Re-mount with `vault secrets move` so each path has exactly three non-empty segments and the third is `gcp`. See gcp/runbooks/03-vault-structure.md.",
        join(", ", local.invalid_mount_paths),
      )
    }
    precondition {
      condition = length(local.rolesets_missing_override) == 0
      error_message = format(
        "The following Vault rolesets have no entry in var.roleset_sa_overrides: %s. Each entry must be keyed by `<env>/<app>/<roleset_name>` because roleset names can collide across apps. See gcp/runbooks/05-roleset-durable-sa.md.",
        join(", ", local.rolesets_missing_override),
      )
    }
    precondition {
      condition     = each.value.sa_email != null && each.value.sa_email != ""
      error_message = "Vault entity ${each.key} has no service_account_email available. For static-account / impersonated-account this means Vault returned no email field; for roleset, fill in var.roleset_sa_overrides[\"${each.value.env}/${each.value.app}/${each.value.vault_name}\"]."
    }
  }
}
