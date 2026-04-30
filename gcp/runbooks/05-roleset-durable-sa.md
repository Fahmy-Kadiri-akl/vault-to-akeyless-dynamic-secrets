# Roleset Durable SA

Vault rolesets and Akeyless dynamic secrets handle the underlying Google
service account differently. This runbook explains why each Vault roleset
needs a pre-created durable SA, how to mint one, and how to wire it into
`var.roleset_sa_overrides`.

## Why rolesets need an override

| Concept                                 | Vault roleset                                            | Akeyless dynamic secret (fixed-SA mode)                |
|-----------------------------------------|----------------------------------------------------------|--------------------------------------------------------|
| Service account lifecycle               | Created on lease-issue, destroyed on lease-revoke.       | Long-lived; the SA exists before the dynamic secret.   |
| `service_account_email` in Vault config | Absent. Per-lease SAs are ephemeral.                     | Required. Stored on the dynamic secret resource.       |

The migration provisions Akeyless dynamic secrets in fixed-SA mode
(`access_type = "sa"`, `service_account_type = "fixed"`). That mode needs
an existing email up front. To migrate a roleset cleanly the operator
pre-creates one durable Google service account per `(env, app, roleset)`
tuple, applies the same IAM bindings the roleset would have applied to
its ephemeral SAs, then maps the email through
`var.roleset_sa_overrides`.

## Override map shape

Keys are `<env>/<app>/<roleset_name>`. The env and app prefix is required
because roleset names commonly collide across apps (`my-roleset` exists
in many mounts).

```hcl
roleset_sa_overrides = {
  "prod/app-1234-saas/dyn-secret1"     = "dyn-secret1@<project>.iam.gserviceaccount.com"
  "prod/app-1234-saas-app/dyn-secret1" = "dyn-secret1@<project>.iam.gserviceaccount.com"
}
```

If a discovered roleset has no entry, `terraform plan` fails at the
precondition with the offending keys named.

## Minting one durable SA

For a roleset `dyn-secret1` under `prod/app-1234-saas/gcp/`:

```bash
PROJECT=<your-project>
ENV=prod
APP=app-1234-saas
ROLESET=dyn-secret1

# Use a stable SA id. Match the Vault roleset name where length permits.
SA_ID="${ROLESET}"
SA_EMAIL="${SA_ID}@${PROJECT}.iam.gserviceaccount.com"

gcloud iam service-accounts create "$SA_ID" \
  --project "$PROJECT" \
  --display-name "Akeyless DS for ${ENV}/${APP}/${ROLESET}"
```

`gcloud iam service-accounts create` is idempotent only on the
"already exists" error code; if you re-run it, it will fail rather than
no-op. Wrap it in a check if you script this for many rolesets.

### Replicating the roleset's bindings

Read the roleset's `bindings` from Vault, then apply equivalent bindings
to the new durable SA:

```bash
curl -sH "X-Vault-Token: $VAULT_TOKEN" \
  "$VAULT_ADDR/v1/$ENV/$APP/gcp/roleset/$ROLESET" \
  | jq .data.bindings
```

For each `resource` and `roles` pair in that output, apply the matching
`gcloud projects add-iam-policy-binding` (or
`gcloud resource-manager folders add-iam-policy-binding`, etc.).
Example for a project-scoped role:

```bash
gcloud projects add-iam-policy-binding "$PROJECT" \
  --member "serviceAccount:${SA_EMAIL}" \
  --role   "roles/storage.objectViewer"
```

### Granting the parent SA permission to mint creds against this child

Whichever cred type the dynamic secret will produce, the parent SA
(the one whose JSON sits in the Akeyless target) needs the matching IAM
role *on this child SA*:

```bash
PARENT_SA_EMAIL=akeyless-migration-parent@${PROJECT}.iam.gserviceaccount.com

# For token-mode dynamic secrets (rolesets and impersonated accounts):
gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
  --project "$PROJECT" \
  --member  "serviceAccount:${PARENT_SA_EMAIL}" \
  --role    "roles/iam.serviceAccountTokenCreator"

# For key-mode static accounts (skip for rolesets):
gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
  --project "$PROJECT" \
  --member  "serviceAccount:${PARENT_SA_EMAIL}" \
  --role    "roles/iam.serviceAccountKeyAdmin"
```

If the parent SA already holds these roles project-wide
([`06-parent-sa-and-target.md`](06-parent-sa-and-target.md)), this step
is redundant. Per-SA bindings are the least-privilege option.

## Verify

Confirm the SA exists and carries the bindings you expect.

```bash
gcloud iam service-accounts describe "$SA_EMAIL" --project "$PROJECT"
```

Expected: a JSON document with `email`, `name`, and `displayName` matching
what you created.

```bash
gcloud projects get-iam-policy "$PROJECT" \
  --flatten='bindings[].members' \
  --filter="bindings.members:serviceAccount:${SA_EMAIL}" \
  --format='table(bindings.role)'
```

Expected: a one-column table listing every role bound to this SA. It
should match the roles the Vault roleset granted, plus
`roles/iam.serviceAccountTokenCreator` (and optionally
`roles/iam.serviceAccountKeyAdmin`) granted to the *parent* SA on this
child.

## Add to tfvars

After you mint and bind every durable SA, paste the map into your
`terraform.tfvars`:

```hcl
roleset_sa_overrides = {
  "prod/app-1234-saas/dyn-secret1"     = "dyn-secret1@<project>.iam.gserviceaccount.com"
  "prod/app-1234-saas-app/dyn-secret1" = "dyn-secret1@<project>.iam.gserviceaccount.com"
  # ... one entry per (env, app, roleset) tuple ...
}
```

`terraform plan` will report `rolesets_missing_override = []` once the
map is complete.

## Next steps

- [Parent SA and target](06-parent-sa-and-target.md). Create the parent
  SA whose JSON key sits inside the Akeyless target.
