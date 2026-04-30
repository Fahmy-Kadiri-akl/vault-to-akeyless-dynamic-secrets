# Troubleshooting

Categorized failure modes for this migration, with diagnoses and fixes.

## `Vault GET sys/mounts returned HTTP 403`

Diagnosis: the Vault token has no `read` capability on `sys/mounts`. The
migration cannot enumerate per-app GCP mounts without it.

Fix: extend the token's policy. Minimum addition:

```hcl
path "sys/mounts" {
  capabilities = ["read"]
}
```

Re-issue the token (or update the bound policy) and re-run plan. See the
full policy block in
[`02-prerequisites.md`](02-prerequisites.md#token-policy).

## `Vault GET sys/mounts returned HTTP 5xx` or a network error

Diagnosis: Vault is unreachable from the Terraform host, the address in
`var.vault_address` is wrong, or Vault itself is unwell.

Fix:

1. Confirm `var.vault_address` matches a working `VAULT_ADDR`:
   `curl -sI "$VAULT_ADDR/v1/sys/health"` should return `200`, `429`,
   `472`, `473`, or `501` (all valid health states; only network errors
   are wrong here).
2. Confirm the Terraform host can route to Vault. A 5xx persisting
   across retries means Vault itself is in trouble; talk to the Vault
   operator.

## `Vault GCP mounts do not match the required <env>/<app>/gcp layout`

Diagnosis: at least one mount of `type=gcp` has a path that does not
split into exactly three non-empty segments with `gcp` as the third.
Common causes:

- Mounted at the default `gcp/` (one segment).
- Mounted at `team/env/app/gcp/` (four segments).
- Mounted at `<env>/<app>/gcp/v2/` (four segments, third is not `gcp`).

Fix: rename with `vault secrets move`. Example:

```bash
vault secrets move gcp/ prod/app-1234-saas/gcp/
```

Move rewrites internal references but does not migrate live leases. If
the source mount has live leases, revoke them or schedule a window
before moving. See
[`03-vault-structure.md`](03-vault-structure.md#mount-path-constraint).

If the malformed mount belongs to another team on a shared Vault
server, do not move it. Set `var.vault_mount_paths` to the allowlist
of mounts you actually own:

```hcl
vault_mount_paths = [
  "prod/app-1234-saas/gcp/",
  "stage/app-1234-saas/gcp/",
]
```

Out-of-scope mounts are silently skipped; in-scope malformed mounts
still fail the precondition.

## `Vault LIST <mount>/<kind> returned HTTP 403`

Diagnosis: the token has `read` on `sys/mounts` but lacks `list` on
`<env>/<app>/gcp/<kind>`. 403 means "you cannot list this path"; 404
means "the path is empty".

Fix: extend the policy:

```hcl
path "+/+/gcp/<kind>"   { capabilities = ["list"] }
path "+/+/gcp/<kind>/*" { capabilities = ["read"] }
```

Re-issue the token and re-run plan.

## `Vault LIST <mount>/<kind> returned HTTP 404`

This is **not a failure**. 404 with body `{"errors":[]}` is Vault's way
of saying "no entries of that kind under this mount". The module treats
it as an empty list and continues.

If you expected entries to be there but the LIST returns 404, the entries
were never created. Re-run `vault write <mount>/<kind>/<name> ...`.

## `The following Vault rolesets have no entry in var.roleset_sa_overrides`

Diagnosis: a roleset is present in Vault but `var.roleset_sa_overrides`
has no key matching `<env>/<app>/<roleset_name>`. The bare
roleset name is not enough; the env/app prefix is required because
roleset names collide across apps.

Fix:

1. Mint a durable SA per missing roleset
   ([`05-roleset-durable-sa.md`](05-roleset-durable-sa.md)).
2. Add entries to the map keyed `<env>/<app>/<roleset_name>`:

   ```hcl
   roleset_sa_overrides = {
     "prod/app-1234-saas/dyn-secret1"     = "dyn-secret1@<project>.iam.gserviceaccount.com"
     "prod/app-1234-saas/dyn-secret1-app" = "dyn-secret1-app@<project>.iam.gserviceaccount.com"
   }
   ```

3. Re-run plan. The error should disappear.

## `Vault entity <key> has no service_account_email available`

Diagnosis: a static-account or impersonated-account entity exists in
Vault but its data has no `service_account_email` field. This is a Vault
config issue, not a tool bug.

Fix: rewrite the entity in Vault with the right fields:

```bash
vault write "${ENV}/${APP}/gcp/static-account/db-static" \
  service_account_email="db-app@${PROJECT}.iam.gserviceaccount.com" \
  secret_type="access_token" \
  token_scopes="https://www.googleapis.com/auth/cloud-platform"
```

Then re-run plan.

## Akeyless provider returns 404 / `dynamic-secret-create-gcp not found`

Diagnosis: `var.akeyless_gateway_url` points at `https://api.akeyless.io`
or another non-gateway endpoint, OR the path suffix on a real gateway
URL does not match how the gateway is exposed. The public API does not
expose the `dynamic-secret-create-gcp` operation; only customer
gateways do.

Fix: pick the suffix that matches how the gateway is reachable.

- Direct SDK port (e.g. `:8081` exposed by the service or a
  port-forward): use `/v2`.

  ```hcl
  akeyless_gateway_url = "https://gateway.example.com:8081/v2"
  ```

- Ingress-fronted gateway (nginx, Istio) on a path-based route: use
  `/api/v2`. The ingress rewrites the prefix so the gateway still sees
  `/v2` upstream.

  ```hcl
  akeyless_gateway_url = "https://gateway.example.com/api/v2"
  ```

Verify either form with
`curl -sI "${URL}/configurations/get-status" -X POST` and expect 400.
A 404 on that endpoint means the suffix is wrong; flip between `/v2`
and `/api/v2` and retry.

## Akeyless provider login fails with `gcp_login: ...`

Diagnosis: the default `provider "akeyless"` block uses `gcp_login`,
which only works on a GCE host whose service account is bound to the
configured access ID with the matching audience. The Terraform host
does not satisfy that.

Fix: swap the login block in `gcp/main.tf` to a method that fits where
Terraform actually runs:

```hcl
provider "akeyless" {
  api_gateway_address = var.akeyless_gateway_url

  api_key_login {
    access_id  = var.akeyless_access_id
    access_key = var.akeyless_access_key   # add this variable yourself
  }
}
```

Other supported methods: `jwt_login`, `token_login`, `email_login`,
`k8s_login`, `cert_login`. See the akeyless-community/akeyless provider
docs.

## `akeyless_target_gcp` already exists with a different `gcp_key`

Diagnosis: a target by the same name was created out-of-band (UI, CLI,
another Terraform stack) before this module was applied. Terraform
refuses to silently take it over.

Fix: either rename the module's target via
`var.akeyless_target_name`, or import the existing target into state:

```bash
terraform import \
  akeyless_target_gcp.migrated_from_vault \
  /migrated-from-vault-gcp
```

Then re-apply. Plan will show an in-place update on `gcp_key` if the
imported target has a different parent SA than `var.parent_sa_credentials`.

## `gcp_sa_email` is empty for an `impersonated-account`

Diagnosis: same root cause as the static-account variant. The Vault
entity was written without `service_account_email`. This is a Vault
config issue.

Fix:

```bash
vault write "${ENV}/${APP}/gcp/impersonated-account/run-deploy" \
  service_account_email="run-deploy@${PROJECT}.iam.gserviceaccount.com" \
  token_scopes="https://www.googleapis.com/auth/cloud-platform"
```

## `terraform plan` count does not match the curl prediction

Diagnosis: the operator predicted N dynamic secrets from the curls in
[`04-discovery-walkthrough.md`](04-discovery-walkthrough.md), but the
plan shows a different count.

Likely causes:

- The tfvars `vault_token` and the `$VAULT_TOKEN` used in the curls are
  different tokens with different policy. Re-run the curls with the
  exact token value Terraform receives.
- A LIST returned a different status between curl time and plan time
  (Vault was being modified concurrently). Re-run plan.
- A mount was added or removed between the two checks.

Fix: re-run both curls and `terraform plan` back-to-back from the same
shell. Counts should match exactly.

## A migrated dynamic secret returns the wrong `gcp_cred_type`

Diagnosis: the Vault static-account's `secret_type` field was not
`service_account_key`, so the module mapped it to `token` instead of
`key`. Or vice versa: a token-mode static-account is showing `key` on
the Akeyless side.

Fix: confirm Vault's view first:

```bash
curl -sH "X-Vault-Token: $VAULT_TOKEN" \
  "$VAULT_ADDR/v1/${MOUNT}/static-account/${NAME}" \
  | jq .data.secret_type
```

Expected: either `access_token` or `service_account_key`. The mapping
the module applies is:

| Vault `secret_type`    | Akeyless `gcp_cred_type` |
|------------------------|--------------------------|
| `service_account_key`  | `key`                    |
| anything else (incl. `access_token`, missing) | `token` |

Update Vault to the correct `secret_type` and re-apply.

## Where to look for plugin-side details

`terraform plan` and `terraform apply` print the full HTTP response body
in any postcondition error. For deeper inspection:

```bash
TF_LOG=DEBUG TF_LOG_PROVIDER=DEBUG terraform plan 2>&1 | tee plan.log
```

The log includes every Vault request (path, status, masked token) and
every Akeyless gateway call. Search for `vault` or `akeyless` to find
the relevant lines.

## Still stuck

Open an issue with:

1. Terraform version (`terraform version`).
2. The `terraform plan` output, with secret values redacted.
3. The output of the curls in
   [`04-discovery-walkthrough.md`](04-discovery-walkthrough.md) for the
   same Vault token.
4. The Akeyless gateway URL (without credentials).
