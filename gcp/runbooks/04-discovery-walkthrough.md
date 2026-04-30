# Discovery Walkthrough

This runbook walks through every HTTP call the Terraform module makes
against Vault, in raw `curl` form. Run them yourself before
`terraform plan` to confirm the token, the mount layout, and the entity
data are all what you expect. If the curls succeed, the plan will
succeed; if the curls produce surprises, fix Vault, not Terraform.

Prep:

```bash
export VAULT_ADDR="https://vault.example.com"
export VAULT_TOKEN="hvs.XXXXX"
```

## Step 1: enumerate GCP mounts

The module starts with `data "http" "list_mounts"`:

```bash
curl -sH "X-Vault-Token: $VAULT_TOKEN" \
  "$VAULT_ADDR/v1/sys/mounts" \
  | jq '.data | with_entries(select(.value.type=="gcp"))'
```

Expected output (trimmed to the relevant fields), one entry per app:

```json
{
  "prod/app-1234-saas/gcp/": {
    "type": "gcp",
    "accessor": "gcp_XXXXXXXX",
    "config": { "default_lease_ttl": 0, "max_lease_ttl": 0 }
  }
}
```

How the tool parses this:

1. Strip the trailing `/` from each key.
2. Split each on `/`. Must be exactly three non-empty segments.
3. The third segment must be the literal `gcp`.
4. The first two segments become `env` and `app`.

For `prod/app-1234-saas/gcp/`:

```
env = "prod"
app = "app-1234-saas"
```

If you see a key like `gcp/` (one segment) or `team/env/app/gcp/` (four),
the plan will fail at the precondition with the offending mount path
named. Fix with `vault secrets move`; see
[`03-vault-structure.md`](03-vault-structure.md).

### Verify

```bash
curl -sH "X-Vault-Token: $VAULT_TOKEN" \
  "$VAULT_ADDR/v1/sys/mounts" \
  | jq -r '.data | to_entries[] | select(.value.type=="gcp") | .key' \
  | while read mp; do
      mp="${mp%/}"
      n=$(echo "$mp" | awk -F/ '{print NF}')
      last=$(echo "$mp" | awk -F/ '{print $NF}')
      if [ "$n" -eq 3 ] && [ "$last" = "gcp" ]; then
        echo "OK    $mp"
      else
        echo "BAD   $mp  (segments=$n, last=$last)"
      fi
    done
```

Every line should start with `OK`. Anything `BAD` will fail
`terraform plan`.

## Step 2: per-mount LIST (one per kind)

For each surviving mount, the tool LISTs three paths. The Vault HTTP API
exposes LIST as either the `LIST` HTTP verb or as `GET ?list=true`. The
module uses the latter form because `data "http"` cannot send custom
verbs.

For the example mount `prod/app-1234-saas/gcp/`:

```bash
MOUNT="prod/app-1234-saas/gcp"

# static-account
curl -sH "X-Vault-Token: $VAULT_TOKEN" \
  "$VAULT_ADDR/v1/$MOUNT/static-account?list=true" | jq .

# impersonated-account
curl -sH "X-Vault-Token: $VAULT_TOKEN" \
  "$VAULT_ADDR/v1/$MOUNT/impersonated-account?list=true" | jq .

# roleset
curl -sH "X-Vault-Token: $VAULT_TOKEN" \
  "$VAULT_ADDR/v1/$MOUNT/roleset?list=true" | jq .
```

Expected when entries exist (note both runtime variants of each logical
secret appear side by side under the same mount):

```json
{
  "request_id": "...",
  "lease_id": "",
  "renewable": false,
  "data": {
    "keys": ["dyn-secret1", "dyn-secret1-app", "another-name", "another-name-app"]
  },
  "warnings": null
}
```

Names ending in `-app` are the Kubernetes-runtime variant of the
adjacent bare name. The migration treats each key as an independent
Vault entity; nothing inside the tool links a bare name to its `-app`
sibling.

Expected when the path has no entries (this is normal):

```json
{ "errors": [] }
```

with HTTP status `404`. The module treats 200 as "parse `data.keys`" and
404 as "empty list, continue". Anything else (401, 403, 5xx) fails the
plan with the offending path and HTTP code.

### Verify

A quick one-liner that mirrors what the tool does:

```bash
for MOUNT in $(curl -sH "X-Vault-Token: $VAULT_TOKEN" "$VAULT_ADDR/v1/sys/mounts" \
                | jq -r '.data | to_entries[] | select(.value.type=="gcp") | .key | rtrimstr("/")'); do
  for KIND in static-account impersonated-account roleset; do
    code=$(curl -s -o /dev/null -w '%{http_code}' \
      -H "X-Vault-Token: $VAULT_TOKEN" \
      "$VAULT_ADDR/v1/$MOUNT/$KIND?list=true")
    echo "$code  $MOUNT/$KIND"
  done
done
```

Expected: every line is `200` (entries exist) or `404` (path empty).
Anything else means the token is missing capability or Vault is unwell.

## Step 3: per-entity READ

For each entity name returned by the LIST, the tool reads the entity to
pull `service_account_email`, `secret_type`, and `token_scopes`.

```bash
MOUNT="prod/app-1234-saas/gcp"
KIND="static-account"
NAME="db-static"

curl -sH "X-Vault-Token: $VAULT_TOKEN" \
  "$VAULT_ADDR/v1/$MOUNT/$KIND/$NAME" \
  | jq .data
```

Expected for a static-account:

```json
{
  "service_account_email": "db-app@<project>.iam.gserviceaccount.com",
  "secret_type": "access_token",
  "token_scopes": ["https://www.googleapis.com/auth/cloud-platform"]
}
```

Expected for an impersonated-account: same shape, `secret_type` always
`access_token`.

Expected for a roleset:

```json
{
  "secret_type": "access_token",
  "token_scopes": ["https://www.googleapis.com/auth/cloud-platform"],
  "bindings": "..."
}
```

A roleset has no `service_account_email`. The tool fills that field from
`var.roleset_sa_overrides[<env>/<app>/<roleset_name>]`.

### What the tool extracts per kind

| Kind                   | `gcp_sa_email` source                                    | `gcp_cred_type`                                           | `gcp_token_scopes`                              |
|------------------------|----------------------------------------------------------|-----------------------------------------------------------|-------------------------------------------------|
| `static-account`       | Vault `data.service_account_email`                       | `key` if `secret_type=service_account_key`, else `token`. | Vault `data.token_scopes` joined with `,`.      |
| `impersonated-account` | Vault `data.service_account_email`                       | Always `token`.                                           | Vault `data.token_scopes` joined with `,`.      |
| `roleset`              | `var.roleset_sa_overrides["<env>/<app>/<roleset_name>"]` | Always `token`.                                           | Vault `data.token_scopes` joined with `,`.      |

## Predicting the plan

After running the curls above, you should be able to predict every
`akeyless_dynamic_secret_gcp` resource that `terraform plan` will create.
For each successful LIST + READ tuple `(<mount>, <kind>, <name>)`, the
plan adds one resource:

```
akeyless_dynamic_secret_gcp.migrated["<env>/<app>/<kind>/<name>"]

  name             = "<env>/<app>/gcp/rolesets/<name>"
  target_name      = var.akeyless_target_name
  gcp_cred_type    = <token|key>
  gcp_sa_email     = <from Vault, or from var.roleset_sa_overrides for rolesets>
  gcp_token_scopes = "<scope1>,<scope2>,..."
```

Each logical secret with both runtime variants produces two such
resources: one for `<name>` and one for `<name>-app`. Both share the
same `<env>/<app>/gcp/rolesets/` folder. For the example LIST result
`["dyn-secret1", "dyn-secret1-app"]` under the `roleset` kind, the plan
adds:

```
akeyless_dynamic_secret_gcp.migrated["prod/app-1234-saas/roleset/dyn-secret1"]
  name = "prod/app-1234-saas/gcp/rolesets/dyn-secret1"

akeyless_dynamic_secret_gcp.migrated["prod/app-1234-saas/roleset/dyn-secret1-app"]
  name = "prod/app-1234-saas/gcp/rolesets/dyn-secret1-app"
```

Plus exactly one `akeyless_target_gcp.migrated_from_vault` for the parent
SA wrapper.

If your prediction matches `terraform plan`, the migration is doing
exactly what Vault told it to. If they diverge, run the curls again and
compare against
[`09-troubleshooting.md`](09-troubleshooting.md).

## Next steps

- [Roleset durable SA](05-roleset-durable-sa.md). For every roleset the
  curls returned, mint a durable Google service account and add it to
  `var.roleset_sa_overrides`.
