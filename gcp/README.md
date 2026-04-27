# GCP module

Migrates a Vault `gcp/` mount into matching Akeyless dynamic secrets. Handles `static-account`, `impersonated-account`, and (with an operator-supplied override map) `roleset`.

## What this module reads from Vault

For the configured mount (default `gcp/`):

- `LIST <mount>/static-account` for the names of static accounts.
- `LIST <mount>/impersonated-account` for the names of impersonated accounts.
- `LIST <mount>/roleset` for the names of rolesets.
- `READ <mount>/<kind>/<name>` for each name, to pull `service_account_email`, `secret_type` (`access_token` or `service_account_key`), and `token_scopes`.

Discovery is fully live. Listing happens via `data "http"` against `<vault_address>/v1/<mount>/<kind>?list=true` (Vault's LIST verb in GET form). Per-entity reads happen via the `vault` provider. Vault returns 404 with `{"errors":[]}` on an empty path; the module treats that as "no entries of that kind" and continues. Anything else (401, 403, 5xx, ...) fails the plan with a postcondition error that names the offending path and HTTP status code.

## What this module writes to Akeyless

- One `akeyless_target_gcp` resource (default name `migrated-from-vault-gcp`), fed the parent SA JSON via `var.parent_sa_credentials`. The provider expects a base64-encoded string in `gcp_key`, so the module passes `base64encode(...)` for you.
- One `akeyless_dynamic_secret_gcp` per discovered Vault entity, keyed by `"<vault-type>/<name>"` and named `"${var.akeyless_path_prefix}/<vault-type>/<name>"`. `access_type` is `sa` and `service_account_type` is `fixed`. `gcp_cred_type` is `token` for impersonated accounts and rolesets, and is derived from `secret_type` for static accounts.

## Prereqs

- Terraform 1.5 or newer.
- Vault: address plus a token with `read` and `list` capability on the GCP mount. The simplest workflow is to alias your existing `VAULT_ADDR` and `VAULT_TOKEN` into the matching Terraform variables:

  ```bash
  export TF_VAR_vault_address="$VAULT_ADDR"
  export TF_VAR_vault_token="$VAULT_TOKEN"
  ```

- Akeyless: an access ID and your gateway's V2 SDK URL. The provider's `api_gateway_address` must point at *your* gateway, not `https://api.akeyless.io`; the public API does not expose `dynamic-secret-create-gcp`. Set `var.akeyless_gateway_url` to something like `https://gateway.example.com:8081/v2` (whatever your gateway is reachable on, with `/v2` appended). The default login is the GCP-SA auth method (`gcp_login`); if you are not running on a GCE host bound to that gateway's access ID, swap the login block in `main.tf`.
- A *parent* Google service account whose JSON key gets stored in the Akeyless target. Akeyless will use this parent SA to mint per-lease credentials for the child SAs your dynamic secrets reference.

### IAM roles required on the parent SA

Akeyless needs at minimum:

- `roles/iam.serviceAccountTokenCreator` on each child SA, for ACCESS_TOKEN-mode dynamic secrets (impersonated accounts, token-mode static accounts, and the SAs you map rolesets to).
- `roles/iam.serviceAccountKeyAdmin` on each child SA, for KEY-mode dynamic secrets (any static account whose Vault `secret_type` is `service_account_key`).

You can grant these at the project level if you prefer; per-SA bindings are the least-privilege option.

### Creating and exporting the parent SA JSON

Replace `<your-project>` and `<sa-id>` with your values:

```bash
PROJECT=<your-project>
SA_ID=<sa-id>                     # e.g. akeyless-migration-parent
SA_EMAIL="${SA_ID}@${PROJECT}.iam.gserviceaccount.com"

gcloud iam service-accounts create "$SA_ID" \
  --project "$PROJECT" \
  --display-name "Akeyless migration parent SA"

# Bind the required roles project-wide (least-privilege: bind per child SA instead).
gcloud projects add-iam-policy-binding "$PROJECT" \
  --member "serviceAccount:${SA_EMAIL}" \
  --role   "roles/iam.serviceAccountTokenCreator"

gcloud projects add-iam-policy-binding "$PROJECT" \
  --member "serviceAccount:${SA_EMAIL}" \
  --role   "roles/iam.serviceAccountKeyAdmin"

# Mint and download the JSON key. Keep this file out of git.
gcloud iam service-accounts keys create ./parent-sa.json \
  --iam-account "$SA_EMAIL" \
  --project     "$PROJECT"
```

Pass it to Terraform as an env var (cleanest, since `terraform.tfvars` does not accept the `file()` function):

```bash
export TF_VAR_parent_sa_credentials="$(cat ./parent-sa.json)"
```

Or via `-var` on the command line:

```bash
terraform plan -var "parent_sa_credentials=$(cat ./parent-sa.json)"
```

The Terraform variable is typed `string` and marked `sensitive`. The module base64-encodes it before storing it on the Akeyless target.

## Rolesets

Vault rolesets work differently from the rest of the GCP secrets engine. Each lease creates a fresh Google service account, applies the configured IAM bindings to it, and tears the SA down on revoke. There is no long-lived `service_account_email` on a roleset; the SA is per-lease and ephemeral.

Akeyless `dynamic_secret_gcp` in fixed-SA mode (which is what this module provisions) needs an existing email. To migrate a roleset cleanly you have to *pre-create* one durable Google service account per roleset, grant it the same set of bindings the roleset would have applied to its ephemeral SAs, then hand its email to this module via `var.roleset_sa_overrides`:

```hcl
roleset_sa_overrides = {
  "my-app-roleset"    = "my-app-roleset@<project>.iam.gserviceaccount.com"
  "ci-deploy-roleset" = "ci-deploy-roleset@<project>.iam.gserviceaccount.com"
}
```

The keys are the Vault roleset names that came back from `LIST gcp/roleset`. The values are the durable SA emails you created.

If a roleset is found in Vault and has no entry in the override map, the plan fails at precondition time with an error that names the missing rolesets. This is intentional: silently skipping rolesets would leave you believing the migration was complete when it was not.

If you do not want to migrate a particular roleset, remove it from Vault before running, or set its override to a sentinel SA that you have designated for "intentionally skipped" entries.

## Variables

| Name                       | Type                 | Default                      | Description                                                                                                                                            |
|----------------------------|----------------------|------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------|
| `vault_address`            | `string`             | required                     | Vault server URL. Easiest: `export TF_VAR_vault_address="$VAULT_ADDR"`.                                                                                |
| `vault_token`              | `string` (sensitive) | required                     | Vault token with `read` plus `list` on the GCP mount. Easiest: `export TF_VAR_vault_token="$VAULT_TOKEN"`.                                             |
| `vault_gcp_mount`          | `string`             | `"gcp"`                      | Path of the Vault GCP secrets engine mount.                                                                                                            |
| `akeyless_access_id`       | `string`             | required                     | Akeyless access ID used by the provider login block.                                                                                                   |
| `akeyless_gcp_audience`    | `string`             | `"akeyless.io"`              | Audience used by the GCP-SA auth method.                                                                                                               |
| `akeyless_gateway_url`     | `string`             | required                     | Your gateway's V2 SDK URL with `/v2` appended (e.g. `https://gateway.example.com:8081/v2`). Not the public `api.akeyless.io`.                          |
| `akeyless_path_prefix`     | `string`             | `"/migrated-from-vault/gcp"` | Path prefix under which migrated dynamic secrets are created.                                                                                          |
| `akeyless_target_name`     | `string`             | `"migrated-from-vault-gcp"`  | Name of the Akeyless GCP target this module creates.                                                                                                   |
| `parent_sa_credentials`    | `string` (sensitive) | required                     | Raw JSON content of the parent SA key. The module base64-encodes it before sending.                                                                    |
| `roleset_sa_overrides`     | `map(string)`        | `{}`                         | `{ "<vault-roleset-name>" = "<durable-sa-email>" }` mapping. See "Rolesets" above.                                                                     |

## Run

```bash
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars: set akeyless_access_id, akeyless_gateway_url, paths
export TF_VAR_vault_address="$VAULT_ADDR"
export TF_VAR_vault_token="$VAULT_TOKEN"
export TF_VAR_parent_sa_credentials="$(cat ./parent-sa.json)"
terraform init
terraform plan
terraform apply
```

`terraform output migration_summary` shows what was migrated and under which Akeyless paths. `terraform output rolesets_missing_override` should be `[]` after a successful apply.
