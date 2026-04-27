# GCP module

Migrates Vault `gcp/`-mount dynamic-secret config into equivalent Akeyless
dynamic secrets. Handles `static-account`, `impersonated-account`, and (with an
operator-supplied override map) `roleset`.

## What this module reads from Vault

For the configured mount (default `gcp/`):

- `LIST <mount>/static-account` — names of static accounts.
- `LIST <mount>/impersonated-account` — names of impersonated accounts.
- `LIST <mount>/roleset` — names of rolesets.
- `READ <mount>/<kind>/<name>` for each name — pulls `service_account_email`,
  `secret_type` (`access_token` or `service_account_key`), and `token_scopes`.

Discovery is fully live. Listing is performed by `data "http"` against
`<vault_address>/v1/<mount>/<kind>?list=true` (Vault's LIST verb in GET form);
per-entity reads are performed by the `vault` provider. Vault returns 404 with
`{"errors":[]}` for an empty path — the module treats 404 as "no entries of
that kind" and continues. Any other status code (401/403/5xx) fails the plan
with a postcondition error naming the offending path and HTTP code.

## What this module writes to Akeyless

- One `akeyless_target_gcp` resource (default name `migrated-from-vault-gcp`),
  fed the parent SA JSON via `var.parent_sa_credentials`. The provider expects a
  base64-encoded string in `gcp_key`, so the module passes `base64encode(...)`
  for you.
- One `akeyless_dynamic_secret_gcp` per discovered Vault entity, keyed by
  `"<vault-type>/<name>"` and named
  `"${var.akeyless_path_prefix}/<vault-type>/<name>"`. `access_type` is `sa`
  with `service_account_type = "fixed"`. `gcp_cred_type` is `token` for
  impersonated accounts and rolesets, and is derived from `secret_type` for
  static accounts.

## Prereqs

- Terraform >= 1.5
- Vault: address + a token with `read` + `list` capability on the GCP mount.
  The simplest workflow is to alias your existing `VAULT_ADDR`/`VAULT_TOKEN`
  into the TF variables of the same name:

  ```bash
  export TF_VAR_vault_address="$VAULT_ADDR"
  export TF_VAR_vault_token="$VAULT_TOKEN"
  ```

- Akeyless: an access ID. The default provider config in `main.tf` uses the
  GCP-SA auth method (`gcp_login`); swap to a different block if you're not
  running on a GCE host that's bound to your Akeyless gateway.
- A **parent** Google service account whose JSON key gets stored in the
  Akeyless target. Akeyless will use this parent SA to mint per-lease
  credentials for the child SAs your dynamic secrets reference.

### IAM roles required on the parent SA

Akeyless minimally needs:

- `roles/iam.serviceAccountTokenCreator` on each child SA — required for
  ACCESS_TOKEN-mode dynamic secrets (impersonated accounts, token-mode static
  accounts, and the SAs you map rolesets to).
- `roles/iam.serviceAccountKeyAdmin` on each child SA — required for
  KEY-mode dynamic secrets (any static account whose Vault `secret_type` is
  `service_account_key`).

You can grant these at the project level if you prefer; per-SA bindings are
the least-privilege option.

### Creating + exporting the parent SA JSON

Replace `<your-project>` and `<sa-id>` with your values:

```bash
PROJECT=<your-project>
SA_ID=<sa-id>                     # e.g. akeyless-migration-parent
SA_EMAIL="${SA_ID}@${PROJECT}.iam.gserviceaccount.com"

gcloud iam service-accounts create "$SA_ID" \
  --project "$PROJECT" \
  --display-name "Akeyless migration parent SA"

# Bind required roles project-wide (least-privilege: bind per child SA instead).
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

In `terraform.tfvars`:

```hcl
parent_sa_credentials = file("${path.module}/parent-sa.json")
```

(The Terraform variable is typed `string` and marked `sensitive`. The TF code
itself does no `file()` reads — you decide whether to inline the JSON or
`file()` it from your tfvars.)

## Rolesets

Vault rolesets work fundamentally differently from the rest of the GCP secrets
engine: each lease creates a **fresh** Google service account, applies the
configured IAM bindings to it, and tears it down on revoke. There is no
long-lived `service_account_email` on a roleset — the SA is per-lease and
ephemeral.

Akeyless `dynamic_secret_gcp` in fixed-SA mode (which is what this module
provisions) needs an existing email. To migrate a roleset 1:1 you have to
**pre-create** one durable Google service account per roleset, grant it the
same set of bindings the roleset would have applied to its ephemeral SAs, then
hand its email to this module via `var.roleset_sa_overrides`:

```hcl
roleset_sa_overrides = {
  "my-app-roleset"         = "my-app-roleset@<project>.iam.gserviceaccount.com"
  "ci-deploy-roleset"      = "ci-deploy-roleset@<project>.iam.gserviceaccount.com"
}
```

The keys are the Vault roleset names (the suffix Vault returned from
`LIST gcp/roleset`). The values are the durable SA emails you created.

If a roleset is discovered in Vault but has no entry in the override map, the
TF run fails at plan time with a precondition error naming the missing
rolesets. This is intentional — silently skipping rolesets would leave the
operator believing the migration was complete when it wasn't.

If you don't want to migrate a particular roleset, exclude it by removing it
from Vault before running (or set the override to a sentinel SA you've
designated for "intentionally skipped" entries).

## Variables

| Name                       | Type           | Default                          | Description                                                                                  |
|----------------------------|----------------|----------------------------------|----------------------------------------------------------------------------------------------|
| `vault_address`            | `string`       | (required)                       | Vault server URL. Easiest: `export TF_VAR_vault_address="$VAULT_ADDR"`.                      |
| `vault_token`              | `string` (sensitive) | (required)                 | Vault token with `read` + `list` on the GCP mount. Easiest: `export TF_VAR_vault_token="$VAULT_TOKEN"`. |
| `vault_gcp_mount`          | `string`       | `"gcp"`                          | Path of the Vault GCP secrets engine mount.                                                  |
| `akeyless_access_id`       | `string`       | (required)                       | Akeyless access ID used by the provider login block.                                         |
| `akeyless_gcp_audience`    | `string`       | `"akeyless.io"`                  | Audience used by the GCP-SA auth method.                                                     |
| `akeyless_api_url`         | `string`       | `"https://api.akeyless.io"`      | Akeyless API gateway URL.                                                                    |
| `akeyless_path_prefix`     | `string`       | `"/migrated-from-vault/gcp"`     | Path prefix under which migrated dynamic secrets are created.                                |
| `akeyless_target_name`     | `string`       | `"migrated-from-vault-gcp"`      | Name of the Akeyless GCP target this module creates.                                         |
| `parent_sa_credentials`    | `string` (sensitive) | (required)                 | Raw JSON content of the parent SA key. The module base64-encodes this before sending.        |
| `roleset_sa_overrides`     | `map(string)`  | `{}`                             | `{ "<vault-roleset-name>" = "<durable-sa-email>" }` mapping. See "Rolesets" above.           |

## Run

```bash
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars (akeyless_access_id, paths, parent_sa_credentials, ...)
export TF_VAR_vault_address="$VAULT_ADDR"
export TF_VAR_vault_token="$VAULT_TOKEN"
terraform init
terraform plan
terraform apply
```

Inspect `terraform output migration_summary` to see what was migrated and
under which Akeyless paths. `terraform output rolesets_missing_override`
should be `[]` after a successful apply.
