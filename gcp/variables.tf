variable "vault_address" {
  description = "Vault server URL (e.g. https://vault.example.com). Required: the http-based discovery needs an explicit URL. Easiest is `export TF_VAR_vault_address=\"$VAULT_ADDR\"` before plan/apply."
  type        = string
}

variable "vault_token" {
  description = "Vault token with `read` on `sys/mounts` plus `read` and `list` on every `<env>/<app>/gcp/{static-account,impersonated-account,roleset}` path. Easiest is `export TF_VAR_vault_token=\"$VAULT_TOKEN\"` before plan/apply. Sensitive."
  type        = string
  sensitive   = true
}

variable "akeyless_access_id" {
  description = "Akeyless access ID used to log in. Must have permission to create targets and dynamic secrets under any discovered `<env>/<app>/gcp/rolesets/` path."
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
    the public API. Two valid path suffixes depending on exposure:
      - Direct SDK port (e.g. :8081 or port-forward) uses "/v2", e.g.
          "https://gateway.example.com:8081/v2"
          "http://127.0.0.1:8081/v2"
      - Ingress-fronted (nginx, Istio) gateways on a path-based route use
        "/api/v2", e.g.
          "https://gateway.example.com/api/v2"
    Verify with `curl -sS -o /dev/null -w '%%{http_code}\n' -X POST "$${URL}/static-creds-auth"`
    and expect HTTP 400 (missing request body). A text/plain `404 page not
    found` means the suffix is wrong (flip between `/v2` and `/api/v2`); a
    JSON `{"error":"unknown command ..."}` 404 means the suffix is right
    but the test endpoint name is unknown to your gateway version.
  EOT
  type        = string
}

variable "akeyless_target_name" {
  description = "Name of the Akeyless GCP target this module creates. One target is shared by every migrated dynamic secret across all apps."
  type        = string
  default     = "migrated-from-vault-gcp"
}

variable "parent_sa_credentials" {
  description = "Raw JSON content of the parent service account key. Forwarded into akeyless_target_gcp.gcp_key after base64 encoding. Marked sensitive."
  type        = string
  sensitive   = true
}

variable "vault_mount_paths" {
  description = <<-EOT
    Optional allowlist of Vault GCP mount paths to migrate, e.g.
    ["prod/app-1234-saas/gcp/", "stage/app-1234-saas/gcp/"]. Trailing
    slash is optional. When empty (default), every type=="gcp" mount
    from sys/mounts is in scope. Use this on shared Vault servers
    where some mounts belong to other teams.
  EOT
  type        = list(string)
  default     = []
}

variable "roleset_sa_overrides" {
  description = <<-EOT
    Mapping from `<env>/<app>/<roleset_name>` to a durable Google service account email.
    Required for every roleset returned by any Vault GCP mount, since rolesets have no
    static service_account_email of their own. Keys must include the env and app prefix
    because roleset names can collide across apps. The plan fails with a precondition
    error at plan time if any discovered roleset lacks an entry here.

    Example:
      {
        "prod/app-1234-saas/my-roleset"     = "my-roleset@<project>.iam.gserviceaccount.com"
        "prod/app-1234-saas/my-roleset-app" = "my-roleset@<project>.iam.gserviceaccount.com"
      }

    See gcp/runbooks/05-roleset-durable-sa.md for how to mint these durable SAs.
  EOT
  type        = map(string)
  default     = {}
}
