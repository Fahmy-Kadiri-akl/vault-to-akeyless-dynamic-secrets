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
   `(env, app, kind, name)` tuple. The count equals the total number of
   Vault entities across all GCP mounts: every key returned by every
   per-kind LIST. A logical secret with both runtime variants
   contributes two rows (one for the bare entity, one for the `-app`
   entity), both under the same mount.

   Use the curls from
   [`04-discovery-walkthrough.md`](04-discovery-walkthrough.md) to
   compute the expected count out-of-band before plan.

   For example, if `prod/app-1234-saas/gcp/roleset?list=true` returns
   `["dyn-secret1", "dyn-secret1-app"]`, the plan adds:

   ```
   # akeyless_dynamic_secret_gcp.migrated["prod/app-1234-saas/roleset/dyn-secret1"]
   #   name = "prod/app-1234-saas/gcp/rolesets/dyn-secret1"
   #
   # akeyless_dynamic_secret_gcp.migrated["prod/app-1234-saas/roleset/dyn-secret1-app"]
   #   name = "prod/app-1234-saas/gcp/rolesets/dyn-secret1-app"
   ```

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

Every `akeyless dynamic-secret ...` invocation in this section needs
`--gateway-url <gateway-host>` (just the hostname; no `/v2` or `/api/v2`
suffix), unless your CLI profile already targets the right gateway. The
default endpoint is `http://localhost:8000`, so without the flag the
calls fail with `connection refused`. The examples below use
`https://gateway.example.com` as the placeholder; substitute your own.

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
  | jq '{ type: .target.target_type, gcp: .value.gcp_target_details }'
```

Expected: `type` is `gcp` and `gcp` is an object whose
`service_account_email` (or equivalent field) matches your parent SA.
Note that `target_type` lives at `.target.target_type`, not under
`.value`, and the GCP fields are nested under `.value.gcp_target_details`.

### Check the dynamic secrets

List everything created under one app's path. The CLI has no
server-side filter flag, so list and filter client-side with `jq`
against `.producers[].name`:

```bash
akeyless dynamic-secret list --gateway-url https://gateway.example.com --json \
  | jq '[.producers[] | select(.name | startswith("/prod/app-1234-saas/"))]'
```

Expected (one entry per discovered Vault entity, all under
`gcp/rolesets/`, with the `-app` runtime variants alongside the bare
names):

```json
[
  { "name": "/prod/app-1234-saas/gcp/rolesets/db-static" },
  { "name": "/prod/app-1234-saas/gcp/rolesets/db-static-app" },
  { "name": "/prod/app-1234-saas/gcp/rolesets/run-deploy" },
  { "name": "/prod/app-1234-saas/gcp/rolesets/run-deploy-app" },
  { "name": "/prod/app-1234-saas/gcp/rolesets/dyn-secret1" },
  { "name": "/prod/app-1234-saas/gcp/rolesets/dyn-secret1-app" }
]
```

### Get a value (token mode)

Fetch both runtime variants and compare. They are independent dynamic
secrets that happen to share a logical name.

```bash
akeyless dynamic-secret get-value --gateway-url https://gateway.example.com \
  --name '/prod/app-1234-saas/gcp/rolesets/dyn-secret1'

akeyless dynamic-secret get-value --gateway-url https://gateway.example.com \
  --name '/prod/app-1234-saas/gcp/rolesets/dyn-secret1-app'
```

Expected (one response per call):

```json
{
  "access_token": "ya29.c.XXXXXXXX...",
  "expires_at": 1735689600,
  "token_type": "Bearer"
}
```

If the two runtime variants point at the same durable SA in
`var.roleset_sa_overrides`, the two access tokens will represent the
same Google identity but be issued separately (different `access_token`
strings, same SA email under the hood). If they point at different SAs,
the tokens belong to different identities. Confirm by decoding each
token via `gcloud auth application-default print-access-token` style
introspection or by calling `tokeninfo`.

### Get a value (key mode)

For a static account whose Vault `secret_type` is `service_account_key`:

```bash
akeyless dynamic-secret get-value --gateway-url https://gateway.example.com \
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
akeyless dynamic-secret get --gateway-url https://gateway.example.com \
  --name '/prod/app-1234-saas/gcp/rolesets/db-static' \
  | jq '.value | { gcp_service_account_email, gcp_cred_type, gcp_token_scopes }'
```

Expected: the SA email matches Vault's `service_account_email`, the cred
type maps `service_account_key` to `key` and `access_token` to `token`,
and the scopes match the Vault `token_scopes` list.

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
