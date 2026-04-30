# First Plan and Apply

This runbook runs the migration end to end against a populated Vault and a
ready Akeyless gateway: configure tfvars, plan, apply, and verify with the
`akeyless` CLI.

## Step 1: configure tfvars

```bash
cd gcp/
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:

- `akeyless_access_id`: the access ID from
  [`02-prerequisites.md`](02-prerequisites.md).
- `akeyless_gateway_url`: your gateway's V2 SDK URL with `/v2` appended.
- `akeyless_target_name`: the default `migrated-from-vault-gcp` is fine
  for a single shared target.
- `roleset_sa_overrides`: one entry per `(env, app, roleset)` tuple, as
  documented in [`05-roleset-durable-sa.md`](05-roleset-durable-sa.md).

The remaining variables (`vault_address`, `vault_token`,
`parent_sa_credentials`) are easiest to set as env vars rather than in
the tfvars file.

## Step 2: set the env vars

```bash
export TF_VAR_vault_address="$VAULT_ADDR"
export TF_VAR_vault_token="$VAULT_TOKEN"
export TF_VAR_parent_sa_credentials="$(cat ./parent-sa.json)"
```

If `terraform.tfvars` already carries these values literally, the env
vars are not needed. Env vars override tfvars when both are present.

## Step 3: init

```bash
terraform init
```

Expected: the providers download and `Terraform has been successfully
initialized!` prints. The lockfile `.terraform.lock.hcl` is gitignored
(this is a customer-runtime tool, not a long-lived service); each
operator pins their own provider versions.

## Step 4: plan

```bash
terraform plan
```

What to look for in the plan output:

1. **One `akeyless_target_gcp.migrated_from_vault`** to create. Just
   one, regardless of how many apps you discovered.
2. **One `akeyless_dynamic_secret_gcp.migrated["..."]`** per discovered
   `(env, app, kind, name)` tuple. The count should equal:

   ```
   (number of GCP mounts in Vault)
     x (sum of static-account + impersonated-account + roleset entries
        across each mount)
   ```

   Use the curls from
   [`04-discovery-walkthrough.md`](04-discovery-walkthrough.md) to
   compute the expected count out-of-band before plan.
3. **Every resource `name` matches** `<env>/<app>/gcp/rolesets/<entity>`.
   The literal folder is `gcp/rolesets/` for static accounts,
   impersonated accounts, AND rolesets.
4. **`gcp_sa_email`** is populated for every resource. If any are
   `(known after apply)` or `null`, the plan will fail at the
   precondition; fix the offender before applying.

If plan fails on the rolesets-missing-override precondition, the error
message names every missing key. Add them to `var.roleset_sa_overrides`
(keyed `<env>/<app>/<roleset>`) and re-run.

## Step 5: apply

```bash
terraform apply
```

Review the prompt and type `yes`. Apply is idempotent: re-running with
no Vault changes is a no-op. The migration is safe to re-apply on every
Vault change.

## Verify with the akeyless CLI

### Check the target

```bash
akeyless target list --filter migrated-from-vault-gcp \
  | jq '.targets[] | { name: .target_name, type: .target_type }'
```

Expected:

```json
{
  "name": "/migrated-from-vault-gcp",
  "type": "gcp"
}
```

```bash
akeyless target get-details --name migrated-from-vault-gcp \
  | jq '.value | { type, gcp_service_account_email }'
```

Expected: `type` is `gcp` and the SA email matches your parent SA.

### Check the dynamic secrets

List everything created under one app's path:

```bash
akeyless dynamic-secret list --filter '/prod/app-1234-saas/' \
  | jq '.items[] | { name: .item_name, type: .item_type, target: .item_targets[0].target_name }'
```

Expected (one entry per discovered Vault entity, all under
`gcp/rolesets/`):

```json
{ "name": "/prod/app-1234-saas/gcp/rolesets/db-static", "type": "DYNAMIC_SECRET", "target": "/migrated-from-vault-gcp" }
{ "name": "/prod/app-1234-saas/gcp/rolesets/run-deploy", "type": "DYNAMIC_SECRET", "target": "/migrated-from-vault-gcp" }
{ "name": "/prod/app-1234-saas/gcp/rolesets/dyn-secret1", "type": "DYNAMIC_SECRET", "target": "/migrated-from-vault-gcp" }
```

### Get a value (token mode)

```bash
akeyless dynamic-secret get-value \
  --name '/prod/app-1234-saas/gcp/rolesets/dyn-secret1'
```

Expected:

```json
{
  "access_token": "ya29.c.XXXXXXXX...",
  "expires_at": 1735689600,
  "token_type": "Bearer"
}
```

### Get a value (key mode)

For a static account whose Vault `secret_type` is `service_account_key`:

```bash
akeyless dynamic-secret get-value \
  --name '/prod/app-1234-saas/gcp/rolesets/db-static-key'
```

Expected:

```json
{
  "private_key_data": "<base64 of the JSON key>",
  "private_key_id": "...",
  "service_account_email": "db-app@<project>.iam.gserviceaccount.com"
}
```

### Side-by-side compare with Vault

Pick one entity. Read both:

```bash
# Vault
vault read prod/app-1234-saas/gcp/static-account/db-static

# Akeyless
akeyless dynamic-secret get-details \
  --name '/prod/app-1234-saas/gcp/rolesets/db-static' \
  | jq '.value | { gcp_service_account_email, gcp_cred_type, gcp_token_scopes }'
```

Expected: the SA email matches Vault's `service_account_email`, the cred
type maps `service_account_key -> key` and `access_token -> token`, and
the scopes match the Vault `token_scopes` list.

### Inspect the migration summary output

```bash
terraform output -json migration_summary | jq '.[] | {env, app, vault_type, vault_name, akeyless_path}'
```

Expected: one record per dynamic secret, with `akeyless_path` matching
the Akeyless name verbatim. `terraform output rolesets_missing_override`
should be `[]` after a successful apply.

## What you have at this point

- One Akeyless target wraps the parent SA.
- One Akeyless dynamic secret per Vault entity, named
  `<env>/<app>/gcp/rolesets/<entity>` regardless of underlying type.
- Re-running `terraform plan && terraform apply` is idempotent and is
  the only thing the operator needs to do when Vault changes.

## Next steps

- [Day-2 operations](08-day-2-operations.md). Adding apps, adding
  rolesets, removing entities, rotating the parent SA.
