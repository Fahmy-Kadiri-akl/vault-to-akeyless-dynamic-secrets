variable "vault_address" {
  description = "Vault server URL (e.g. https://vault.example.com). Required: the http-based discovery needs an explicit URL. Easiest is `export TF_VAR_vault_address=\"$VAULT_ADDR\"` before plan/apply."
  type        = string
}

variable "vault_token" {
  description = "Vault token with `read` + `list` capability on the GCP mount. Easiest is `export TF_VAR_vault_token=\"$VAULT_TOKEN\"` before plan/apply. Sensitive."
  type        = string
  sensitive   = true
}

variable "vault_gcp_mount" {
  description = "Path of the Vault GCP secrets engine mount, without leading or trailing slashes (e.g. \"gcp\" or \"prod-gcp\")."
  type        = string
  default     = "gcp"
}

variable "akeyless_access_id" {
  description = "Akeyless access ID used to log in. Must have permission to create targets and dynamic secrets under var.akeyless_path_prefix."
  type        = string
}

variable "akeyless_gcp_audience" {
  description = "Audience claim used by the Akeyless GCP-SA auth method (gcp_login)."
  type        = string
  default     = "akeyless.io"
}

variable "akeyless_gateway_url" {
  description = <<-EOT
    URL of *your* Akeyless gateway's V2 SDK endpoint, NOT the public api.akeyless.io.
    The dynamic-secret-create-gcp operation is gateway-side and is not exposed on
    the public API. Examples:
      "https://gateway.example.com:8081/v2"     # gateway exposed via ingress
      "http://127.0.0.1:8081/v2"                # via port-forward into the cluster
    Trailing /v2 is required for the akeyless-community/akeyless provider.
  EOT
  type        = string
}

variable "akeyless_path_prefix" {
  description = "Path prefix under which migrated dynamic secrets are created. Each entity is named <prefix>/<vault-type>/<name>."
  type        = string
  default     = "/migrated-from-vault/gcp"
}

variable "akeyless_target_name" {
  description = "Name of the Akeyless GCP target this module creates."
  type        = string
  default     = "migrated-from-vault-gcp"
}

variable "parent_sa_credentials" {
  description = "Raw JSON content of the parent service account key. Forwarded into akeyless_target_gcp.gcp_key after base64 encoding. Marked sensitive."
  type        = string
  sensitive   = true
}

variable "roleset_sa_overrides" {
  description = <<-EOT
    Mapping from Vault roleset name to a durable Google service account email.
    Required for every roleset returned by the Vault GCP mount, since rolesets
    have no static service_account_email of their own. The TF run fails with
    a precondition error at plan time if any discovered roleset lacks an entry
    here. See gcp/README.md "Rolesets" for how to mint these durable SAs.
  EOT
  type        = map(string)
  default     = {}
}
