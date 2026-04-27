# Single Akeyless GCP target. Akeyless will use the parent SA to mint
# per-lease credentials for the child SAs the dynamic secrets reference.
#
# akeyless_target_gcp.gcp_key is documented as "Base64-encoded service
# account private key text", so we base64-encode the raw JSON the customer
# hands us via var.parent_sa_credentials.
#
# Docs: https://registry.terraform.io/providers/akeyless-community/akeyless/latest/docs/resources/target_gcp
resource "akeyless_target_gcp" "migrated_from_vault" {
  name        = var.akeyless_target_name
  description = "Created by vault-to-akeyless-dynamic-secrets migration TF. Wraps the parent SA used to mint child credentials for the migrated dynamic secrets."
  gcp_key     = base64encode(var.parent_sa_credentials)
}
