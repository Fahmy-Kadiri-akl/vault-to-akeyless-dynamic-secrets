# Day-2 Operations

This document covers ongoing operations after the migration is wired up:
adding apps, adding rolesets, removing entities, and rotating the parent
SA.

## Adding a new app

The migration discovers Vault mounts on every plan, so a new app is a
Vault-side change followed by a Terraform re-run. No module changes.

1. Mount both halves of the new app in Vault, using the parent SA's
   JSON for `config`:

   ```bash
   ENV=prod
   APP=app-9999-newco
   PARENT_SA_KEY=./parent-sa.json

   vault secrets enable -path="${ENV}/${APP}/gcp" gcp
   vault write "${ENV}/${APP}/gcp/config" credentials=@"${PARENT_SA_KEY}"

   vault secrets enable -path="${ENV}/${APP}-app/gcp" gcp
   vault write "${ENV}/${APP}-app/gcp/config" credentials=@"${PARENT_SA_KEY}"
   ```

2. Populate each mount with static-account, impersonated-account, and
   roleset entries as needed (see
   [`03-vault-structure.md`](03-vault-structure.md)).
3. For every roleset, mint a durable SA and add an entry to
   `var.roleset_sa_overrides` keyed `<env>/<app>/<roleset_name>` (see
   [`05-roleset-durable-sa.md`](05-roleset-durable-sa.md)).
4. Re-run:

   ```bash
   terraform plan
   terraform apply
   ```

   Plan should show only additions: one `akeyless_dynamic_secret_gcp`
   per new Vault entity, no destroys, no in-place updates against
   anything in other apps.

### Verify

```bash
akeyless dynamic-secret list --filter "/prod/${APP}/" \
  | jq '.items[].item_name'
```

Expected: one path per Vault entity in the new app, all under
`<env>/<app>/gcp/rolesets/`.

## Adding a new roleset to an existing app

1. Create the roleset in Vault:

   ```bash
   vault write "${ENV}/${APP}/gcp/roleset/another-roleset" \
     project="${PROJECT}" \
     secret_type="access_token" \
     token_scopes="https://www.googleapis.com/auth/cloud-platform" \
     bindings=-<<EOF
   resource "//cloudresourcemanager.googleapis.com/projects/${PROJECT}" {
     roles = ["roles/storage.objectViewer"]
   }
   EOF
   ```

2. Mint the durable SA and replicate the bindings (see
   [`05-roleset-durable-sa.md`](05-roleset-durable-sa.md)).
3. Add the entry to `var.roleset_sa_overrides`:

   ```hcl
   roleset_sa_overrides = {
     # ... existing entries ...
     "prod/app-1234-saas/another-roleset" = "another-roleset@<project>.iam.gserviceaccount.com"
   }
   ```

4. `terraform plan && terraform apply`.

## Removing a migrated entity

Delete from Vault first, then re-apply. Terraform will destroy the
matching `akeyless_dynamic_secret_gcp`.

```bash
vault delete "${ENV}/${APP}/gcp/roleset/dyn-secret1"

terraform plan    # should show one destroy
terraform apply
```

If the roleset is being decommissioned permanently, also remove its
entry from `var.roleset_sa_overrides` and (optionally) delete the
durable SA in GCP:

```bash
gcloud iam service-accounts delete \
  "dyn-secret1@<project>.iam.gserviceaccount.com" \
  --project "<project>"
```

## Removing an entire app

To migrate an app off the platform:

1. Disable both Vault mounts:

   ```bash
   vault secrets disable "${ENV}/${APP}/gcp"
   vault secrets disable "${ENV}/${APP}-app/gcp"
   ```

2. Remove the app's keys from `var.roleset_sa_overrides`.
3. `terraform plan` should show one destroy per dynamic secret across
   both mounts. Apply.
4. (Optional) Delete the per-roleset durable SAs in GCP.

The shared `akeyless_target_gcp` stays; it is still used by other apps.

## Rotating the parent SA

The parent SA's JSON key has a finite useful life. Rotate periodically.

1. Mint a new key for the existing parent SA:

   ```bash
   gcloud iam service-accounts keys create ./parent-sa.new.json \
     --iam-account "$PARENT_SA_EMAIL" \
     --project     "$PROJECT"
   ```

2. Swap the env var and re-apply:

   ```bash
   export TF_VAR_parent_sa_credentials="$(cat ./parent-sa.new.json)"
   terraform plan      # one in-place update on akeyless_target_gcp.migrated_from_vault
   terraform apply
   ```

   `terraform plan` shows an in-place update on the target's `gcp_key`.
   No dynamic secret resources change.

3. After confirming new leases work (issue a value via
   `akeyless dynamic-secret get-value`), delete the old key:

   ```bash
   # List keys to find the old key id.
   gcloud iam service-accounts keys list \
     --iam-account "$PARENT_SA_EMAIL" --project "$PROJECT"

   gcloud iam service-accounts keys delete <OLD_KEY_ID> \
     --iam-account "$PARENT_SA_EMAIL" --project "$PROJECT"
   ```

4. Move `parent-sa.new.json` to `parent-sa.json` for the next rotation.

## Rotating a child SA's bindings

For static and impersonated accounts, the child SA email lives in Vault.
Update Vault, re-apply Terraform; the dynamic secret's `gcp_sa_email`
follows.

```bash
vault write "${ENV}/${APP}/gcp/static-account/db-static" \
  service_account_email="db-app-v2@${PROJECT}.iam.gserviceaccount.com" \
  secret_type="access_token"

terraform plan       # one in-place update on the corresponding DS
terraform apply
```

For rolesets, the durable SA email lives in `var.roleset_sa_overrides`.
Update the map, re-apply.

## Re-running plan against an unchanged Vault

`terraform plan` with no Vault changes is a no-op:

```
No changes. Your infrastructure matches the configuration.
```

Discovery is idempotent and re-runs the same `sys/mounts` plus per-mount
LIST calls every time. There is no cached inventory to invalidate.

## Next steps

- [Troubleshooting](09-troubleshooting.md). Diagnoses for common failure
  modes.
