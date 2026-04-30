# Vault Structure

This runbook covers the Vault-side layout the migration expects: two GCP
mounts per application (one for non-Kubernetes workloads, one for
Kubernetes), and how to populate each with static-account,
impersonated-account, and roleset entries.

## Two mounts per app

Every application gets two GCP secrets engine mounts:

| Mount path                     | Runtime               |
|--------------------------------|-----------------------|
| `<env>/<app>/gcp/`             | Non-Kubernetes        |
| `<env>/<app>-app/gcp/`         | Kubernetes            |

The `-app` suffix on the second mount is the convention the platform uses
to distinguish Kubernetes workloads. The migration tool does not enforce
it, and it does not synthesize the second mount if only one is present;
it simply discovers what exists.

### Worked example

For `app-1234-saas` in `prod`:

```
prod/app-1234-saas/gcp/        # non-Kubernetes
prod/app-1234-saas-app/gcp/    # Kubernetes
```

Each mount produces its own set of Akeyless dynamic secrets, all named
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

## Enabling the mounts

Replace `<env>`, `<app>`, and `<project>` with your values, and point
`-credentials=@...` at the parent SA's JSON key (the same one that ends
up in `var.parent_sa_credentials`).

```bash
ENV=prod
APP=app-1234-saas
PROJECT=<your-project>
PARENT_SA_KEY=./parent-sa.json

# Non-Kubernetes mount.
vault secrets enable -path="${ENV}/${APP}/gcp" gcp
vault write "${ENV}/${APP}/gcp/config" credentials=@"${PARENT_SA_KEY}"

# Kubernetes mount.
vault secrets enable -path="${ENV}/${APP}-app/gcp" gcp
vault write "${ENV}/${APP}-app/gcp/config" credentials=@"${PARENT_SA_KEY}"
```

### Verify

```bash
curl -sH "X-Vault-Token: $VAULT_TOKEN" "$VAULT_ADDR/v1/sys/mounts" \
  | jq '. | with_entries(select(.value.type=="gcp")) | keys'
```

Expected:

```json
[
  "prod/app-1234-saas-app/gcp/",
  "prod/app-1234-saas/gcp/"
]
```

## Populating entries

Each mount can hold any combination of static-account,
impersonated-account, and roleset entries. The migration enumerates all
three types per mount.

### static-account

A static account binds a long-lived service account to one of:
- `access_token` (default): Vault produces short-lived OAuth tokens.
- `service_account_key`: Vault produces JSON keys.

```bash
vault write "${ENV}/${APP}/gcp/static-account/db-static" \
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
```

### roleset

A roleset creates a fresh service account per lease and applies the
configured IAM bindings to it. There is no static `service_account_email`
on a roleset; the per-lease SA is ephemeral. The migration handles this
by asking you to pre-create one durable SA per `(env, app, roleset)`
tuple and pass its email through `var.roleset_sa_overrides`. See
[`05-roleset-durable-sa.md`](05-roleset-durable-sa.md) for the full
walkthrough.

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

Expected: a JSON array of names per kind, or `null` (which means 404,
empty path) for kinds the operator did not populate.

## What the migration sees

Given the example above, after running the discovery curls in
[`04-discovery-walkthrough.md`](04-discovery-walkthrough.md), the
migration's `local.migration_map` contains:

| Map key                                                       | Akeyless DS path                                        |
|---------------------------------------------------------------|---------------------------------------------------------|
| `prod/app-1234-saas/static-account/db-static`                 | `prod/app-1234-saas/gcp/rolesets/db-static`             |
| `prod/app-1234-saas/impersonated-account/run-deploy`          | `prod/app-1234-saas/gcp/rolesets/run-deploy`            |
| `prod/app-1234-saas/roleset/dyn-secret1`                      | `prod/app-1234-saas/gcp/rolesets/dyn-secret1`           |

Plus the mirror under `prod/app-1234-saas-app/...` if you populated the
Kubernetes mount with the same entities.

## Next steps

- [Discovery walkthrough](04-discovery-walkthrough.md). The exact HTTP
  calls the Terraform tool makes, so you can verify out-of-band before
  `terraform plan`.
