output "migration_summary" {
  description = "Per-entity record of what was migrated. One element per Akeyless dynamic secret created."
  value = [
    for k, v in local.migration_map : {
      vault_type    = v.vault_type
      vault_name    = v.vault_name
      akeyless_path = "${var.akeyless_path_prefix}/${k}"
      gcp_sa_email  = v.sa_email
      cred_type     = v.cred_type
      mode          = v.mode
    }
  ]
}

output "rolesets_missing_override" {
  description = "Vault roleset names that were listed in var.vault_rolesets but had no entry in var.roleset_sa_overrides. Empty after a successful apply."
  value       = local.rolesets_missing_override
}

output "akeyless_target_name" {
  description = "Name of the Akeyless GCP target this module created."
  value       = akeyless_target_gcp.migrated_from_vault.name
}
