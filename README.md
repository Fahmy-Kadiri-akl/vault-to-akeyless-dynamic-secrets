# vault-to-akeyless-dynamic-secrets

Terraform-based migration tool that **discovers** dynamic-secret configuration in
HashiCorp Vault, **extracts** the relevant identity data, and **creates** equivalent
Akeyless dynamic secrets. Driven entirely by the `hashicorp/vault` and
`akeyless-community/akeyless` Terraform providers — Terraform never speaks to a
cloud provider API directly. The customer only needs Vault access and Akeyless
access; cloud-side credentials live inside the Akeyless target.

## Architecture

```
+---------------------+         +-------------------------+         +------------------------+
|                     |  read   |                         |  write  |                        |
|  HashiCorp Vault    | <-----  |       Terraform         | ----->  |       Akeyless         |
|  (gcp/, aws/, ...)  |  list/  |  vault provider (read)  |  apply  |  akeyless provider     |
|                     |  get    |  akeyless provider      |         |  (target + dyn secret) |
+---------------------+         +-------------------------+         +------------------------+
        ^                                   |                                   |
        |                                   |  no google / aws / azurerm        |
        |                                   |  providers — TF never touches     |
        |                                   |  cloud-control-plane APIs.        |
        |                                   v                                   |
        |                          +------------------+                         |
        +--------------------------|  Operator-run    |-------------------------+
                                   |  terraform plan  |
                                   |  + apply         |
                                   +------------------+
```

The TF run authenticates to Vault (address + token, supplied via TF
variables — easiest is `export TF_VAR_vault_address="$VAULT_ADDR"` and
`export TF_VAR_vault_token="$VAULT_TOKEN"`) and to Akeyless (your chosen
auth method). It does not need GCP, AWS, or Azure credentials. The cloud-side
identity (e.g. parent service-account JSON) is passed as a sensitive
Terraform variable and forwarded straight into the Akeyless target.

Discovery is fully live: the module enumerates Vault entities at plan time
via the Vault HTTP API (`?list=true`), with no operator-supplied name lists.
A 404 from Vault is treated as "no entries of that kind" and is not an error.

## Mapping

| Vault entity (`<mount>/<kind>/<name>`)    | Akeyless object                                              | Notes                                                                                                |
|-------------------------------------------|--------------------------------------------------------------|------------------------------------------------------------------------------------------------------|
| `gcp/static-account/<name>`               | `akeyless_dynamic_secret_gcp` (fixed SA, token or key)       | `gcp_sa_email` copied from Vault. `gcp_cred_type` derived from Vault `secret_type`.                  |
| `gcp/impersonated-account/<name>`         | `akeyless_dynamic_secret_gcp` (fixed SA, access token)       | `gcp_sa_email` copied from Vault. Always `gcp_cred_type = "token"`.                                  |
| `gcp/roleset/<name>`                      | `akeyless_dynamic_secret_gcp` — **needs override**           | Vault rolesets create a fresh SA per lease (no static email). Operator must supply a per-roleset SA. |
| (parent SA JSON for the Akeyless target)  | `akeyless_target_gcp.gcp_key` (base64-encoded)               | Provided as a sensitive tfvar; TF base64-encodes it before sending.                                  |

### Roleset caveat

Vault rolesets do **not** map cleanly to Akeyless. A Vault roleset materializes
a brand-new Google service account (and bindings) for each lease. Akeyless
fixed-SA dynamic secrets need a long-lived service-account email up front. To
migrate a roleset you must pre-create one Google service account per roleset
with bindings equivalent to what the roleset granted, and pass its email via
`var.roleset_sa_overrides`. The TF will fail closed if any roleset has no
override entry. See `gcp/README.md` for the full procedure.

## Repo layout

```
vault-to-akeyless-dynamic-secrets/
  README.md                        <- you are here
  .gitignore
  gcp/                             <- ready
    README.md
    main.tf  variables.tf  data.tf  locals.tf  target.tf  dynamic_secrets.tf  outputs.tf
    terraform.tfvars.example
  aws/                             <- coming soon
    README.md
  azure/                           <- coming soon
    README.md
```

## Prereqs

- Terraform >= 1.5
- Vault access:
  - Address via `var.vault_address` (or `export TF_VAR_vault_address="$VAULT_ADDR"`)
  - Token via `var.vault_token` (or `export TF_VAR_vault_token="$VAULT_TOKEN"`)
    with `read` + `list` capability on `<mount>/static-account`,
    `<mount>/impersonated-account`, `<mount>/roleset` and the per-entity paths.
- Akeyless access:
  - An access ID with permission to create targets and dynamic secrets under your chosen path prefix.
  - For the GCP-SA auth method (lab default), the runner must execute on a GCE
    instance whose service account is bound in Akeyless; otherwise switch
    `var.akeyless_auth_method` to a different login block in `main.tf`.
- Parent service-account JSON for the Akeyless GCP target — see `gcp/README.md`
  for the IAM roles required and the `gcloud` command to mint it.

## Quickstart (GCP module)

```bash
cd gcp/
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars: set akeyless_access_id, paths, parent_sa_credentials
export TF_VAR_vault_address="$VAULT_ADDR"
export TF_VAR_vault_token="$VAULT_TOKEN"
terraform init
terraform plan
# review the planned akeyless_target_gcp + akeyless_dynamic_secret_gcp resources
terraform apply
```

`terraform plan` will fail with a precondition error if any Vault roleset
lacks an entry in `var.roleset_sa_overrides`. The error message names the
missing rolesets so you can fill them in and retry.

## Status

| Module | Vault mount | Status   | Notes                                                                                |
|--------|-------------|----------|--------------------------------------------------------------------------------------|
| `gcp/` | `gcp/`      | Ready    | static-account, impersonated-account, roleset (with operator-supplied SA overrides). |
| `aws/` | `aws/`      | Planned  | Will mirror the GCP pattern: IAM users, assumed-roles, federation tokens.            |
| `azure`| `azure/`    | Planned  | Will mirror the GCP pattern for Azure SP / managed-identity rolesets.                |
