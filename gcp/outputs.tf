output "migration_summary" {
  description = "Per-entity record of what was migrated. One element per Akeyless dynamic secret created."
  # vault_generic_secret.data is sensitive, so derived fields (sa_email,
  # token_scopes) inherit that. Mark this whole output sensitive so plan/apply
  # can render it without forcing operators to wrap individual fields in
  # nonsensitive(). Use `terraform output -json migration_summary` to inspect.
  sensitive = true
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
  description = "Vault roleset names discovered in the mount but missing an entry in var.roleset_sa_overrides. Empty after a successful apply."
  value       = local.rolesets_missing_override
}

output "akeyless_target_name" {
  description = "Name of the Akeyless GCP target this module created."
  value       = akeyless_target_gcp.migrated_from_vault.name
}
