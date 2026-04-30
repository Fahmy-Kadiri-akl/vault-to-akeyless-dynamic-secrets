# Vault Structure

This runbook covers the Vault-side layout the migration expects: one GCP
secrets engine mount per application, and how to populate it with
static-account, impersonated-account, and roleset entries. The
Kubernetes vs non-Kubernetes split lives at the entity level inside the
single mount, by convention with an `-app` suffix on the entity name.

## One mount per app, two entities per logical secret

Every application gets exactly one GCP secrets engine mount:

| Mount path             | Holds                                           |
|------------------------|-------------------------------------------------|
| `<env>/<app>/gcp/`     | Every entity for the app, both runtimes.        |

Inside that single mount, the operator creates one entity per logical
secret per runtime:

| Entity name                   | Runtime         |
|-------------------------------|-----------------|
| `<entity_name>`               | Non-Kubernetes  |
| `<entity_name>-app`           | Kubernetes      |

The `-app` suffix on the entity name is the convention the platform
uses to distinguish Kubernetes workloads. The migration tool does not
enforce it and does not synthesize the `-app` variant; it discovers
whatever names the operator wrote.

### Worked example

For `app-1234-saas` in `prod`, with one logical roleset `dyn-secret1`:

```
prod/app-1234-saas/gcp/                              # the only mount
prod/app-1234-saas/gcp/roleset/dyn-secret1           # non-Kubernetes entity
prod/app-1234-saas/gcp/roleset/dyn-secret1-app       # Kubernetes entity
```

Each entity produces its own Akeyless dynamic secret, both named
`<env>/<app>/gcp/rolesets/<entity_name>`.

## Mount path constraint

A mount path must split on `/` into exactly three non-empty segments and
the third segment must be the literal `gcp`. Anything else (`gcp/`,
`team/env/app/gcp/`, `prod/app/gcp/extra/`) lands in
`local.invalid_mount_paths` and the plan fails with a precondition error
naming the offender.

Move a malformed mount with `vault secrets move`:

```bash
# From:  gcp/                            (one segment, missing env+app)
# To:    prod/app-1234-saas/gcp/
vault secrets move gcp/ prod/app-1234-saas/gcp/
```

`vault secrets move` rewrites internal references but does not migrate
existing leases. If the source mount has live leases, revoke them or
plan a maintenance window before moving.

### When the malformed mount is not yours

On shared Vault servers, the malformed mount may belong to another team
and `vault secrets move` would be destructive to their data. Use the
`vault_mount_paths` allowlist on the migration to scope discovery to
just your slice:

```hcl
vault_mount_paths = [
  "prod/app-1234-saas/gcp/",
  "stage/app-1234-saas/gcp/",
]
```

When non-empty, only mounts in the list are considered. Out-of-scope
mounts are silently skipped, so a sibling team's malformed `gcp/` mount
no longer crashes the plan. In-scope malformed mounts still fail the
precondition.

See also
[`09-troubleshooting.md`](09-troubleshooting.md#vault-gcp-mounts-do-not-match-the-required-envappgcp-layout).

## Enabling the mount

Replace `<env>`, `<app>`, and `<project>` with your values, and point
`-credentials=@...` at the parent SA's JSON key (the same one that ends
up in `var.parent_sa_credentials`).

```bash
ENV=prod
APP=app-1234-saas
PROJECT=<your-project>
PARENT_SA_KEY=./parent-sa.json

vault secrets enable -path="${ENV}/${APP}/gcp" gcp
vault write "${ENV}/${APP}/gcp/config" credentials=@"${PARENT_SA_KEY}"
```

### Verify

```bash
curl -sH "X-Vault-Token: $VAULT_TOKEN" "$VAULT_ADDR/v1/sys/mounts" \
  | jq '.data | with_entries(select(.value.type=="gcp")) | keys'
```

Expected:

```json
[
  "prod/app-1234-saas/gcp/"
]
```

One key per app, not two.

## Populating entries

The single mount holds any combination of static-account,
impersonated-account, and roleset entries. The migration enumerates all
three types per mount.

For each logical secret, create both the bare entity and the `-app`
variant if the app has a Kubernetes runtime. The two entities are
independent Vault objects under the same mount; nothing in Vault links
them.

### static-account

A static account binds a long-lived service account to one of:
- `access_token` (default): Vault produces short-lived OAuth tokens.
- `service_account_key`: Vault produces JSON keys.

Create both runtime variants:

```bash
# Non-Kubernetes variant.
vault write "${ENV}/${APP}/gcp/static-account/db-static" \
  service_account_email="db-app@${PROJECT}.iam.gserviceaccount.com" \
  secret_type="access_token" \
  token_scopes="https://www.googleapis.com/auth/cloud-platform"

# Kubernetes variant (same mount, "-app" entity-name suffix).
vault write "${ENV}/${APP}/gcp/static-account/db-static-app" \
  service_account_email="db-app@${PROJECT}.iam.gserviceaccount.com" \
  secret_type="access_token" \
  token_scopes="https://www.googleapis.com/auth/cloud-platform"
```

### impersonated-account

An impersonated account always produces access tokens via Google's IAM
Credentials API.

```bash
vault write "${ENV}/${APP}/gcp/impersonated-account/run-deploy" \
  service_account_email="run-deploy@${PROJECT}.iam.gserviceaccount.com" \
  token_scopes="https://www.googleapis.com/auth/cloud-platform"

vault write "${ENV}/${APP}/gcp/impersonated-account/run-deploy-app" \
  service_account_email="run-deploy@${PROJECT}.iam.gserviceaccount.com" \
  token_scopes="https://www.googleapis.com/auth/cloud-platform"
```

### roleset

> If `vault write <mount>/roleset/...` returns
> `Permission 'iam.serviceAccounts.create' denied`, your Vault GCP
> config SA needs the extra roles described in
> [`06-parent-sa-and-target.md`](06-parent-sa-and-target.md) under
> "Extra roles when the same SA is the Vault GCP config SA and any
> rolesets exist". Mint the parent SA per 06 first, then return here
> to populate rolesets.

A roleset creates a fresh service account per lease and applies the
configured IAM bindings to it. There is no static `service_account_email`
on a roleset; the per-lease SA is ephemeral. The migration handles this
by asking you to pre-create one durable SA per `(env, app, roleset_name)`
tuple and pass its email through `var.roleset_sa_overrides`. The
`roleset_name` is the literal Vault entity name and may itself end in
`-app`. See [`05-roleset-durable-sa.md`](05-roleset-durable-sa.md) for
the full walkthrough.

```bash
vault write "${ENV}/${APP}/gcp/roleset/dyn-secret1" \
  project="${PROJECT}" \
  secret_type="access_token" \
  token_scopes="https://www.googleapis.com/auth/cloud-platform" \
  bindings=-<<EOF
resource "//cloudresourcemanager.googleapis.com/projects/${PROJECT}" {
  roles = ["roles/storage.objectViewer"]
}
EOF

vault write "${ENV}/${APP}/gcp/roleset/dyn-secret1-app" \
  project="${PROJECT}" \
  secret_type="access_token" \
  token_scopes="https://www.googleapis.com/auth/cloud-platform" \
  bindings=-<<EOF
resource "//cloudresourcemanager.googleapis.com/projects/${PROJECT}" {
  roles = ["roles/storage.objectViewer"]
}
EOF
```

### Verify

```bash
curl -sH "X-Vault-Token: $VAULT_TOKEN" \
  "$VAULT_ADDR/v1/${ENV}/${APP}/gcp/static-account?list=true" \
  | jq .data.keys

curl -sH "X-Vault-Token: $VAULT_TOKEN" \
  "$VAULT_ADDR/v1/${ENV}/${APP}/gcp/impersonated-account?list=true" \
  | jq .data.keys

curl -sH "X-Vault-Token: $VAULT_TOKEN" \
  "$VAULT_ADDR/v1/${ENV}/${APP}/gcp/roleset?list=true" \
  | jq .data.keys
```

Expected for each kind: a JSON array containing both the bare names and
the `-app` variants the operator wrote, or `null` (which means 404,
empty path) for kinds the operator did not populate. For the worked
example above, the `roleset` LIST returns:

```json
["dyn-secret1", "dyn-secret1-app"]
```

## What the migration sees

Given the example above, after running the discovery curls in
[`04-discovery-walkthrough.md`](04-discovery-walkthrough.md), the
migration's `local.migration_map` contains:

| Map key                                                            | Akeyless DS path                                            |
|--------------------------------------------------------------------|-------------------------------------------------------------|
| `prod/app-1234-saas/static-account/db-static`                      | `prod/app-1234-saas/gcp/rolesets/db-static`                 |
| `prod/app-1234-saas/static-account/db-static-app`                  | `prod/app-1234-saas/gcp/rolesets/db-static-app`             |
| `prod/app-1234-saas/impersonated-account/run-deploy`               | `prod/app-1234-saas/gcp/rolesets/run-deploy`                |
| `prod/app-1234-saas/impersonated-account/run-deploy-app`           | `prod/app-1234-saas/gcp/rolesets/run-deploy-app`            |
| `prod/app-1234-saas/roleset/dyn-secret1`                           | `prod/app-1234-saas/gcp/rolesets/dyn-secret1`               |
| `prod/app-1234-saas/roleset/dyn-secret1-app`                       | `prod/app-1234-saas/gcp/rolesets/dyn-secret1-app`           |

Two rows per logical secret, one Akeyless dynamic secret per row, all
under the same `<env>/<app>/gcp/rolesets/` folder.

## Next steps

- [Discovery walkthrough](04-discovery-walkthrough.md). The exact HTTP
  calls the Terraform tool makes, so you can verify out-of-band before
  `terraform plan`.
