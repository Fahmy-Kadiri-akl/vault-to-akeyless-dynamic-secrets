# Prerequisites

Complete every item in this checklist before running `terraform plan`. Most
failures later in the runbook trace back to a missed prerequisite here.

## Vault

- [ ] Vault server reachable from the Terraform host. The address goes into
      `var.vault_address` (typically `export TF_VAR_vault_address="$VAULT_ADDR"`).
- [ ] At least one GCP secrets engine mounted at `<env>/<app>/gcp/`. If
      mounts are flat (e.g. `gcp/`), see
      [`03-vault-structure.md`](03-vault-structure.md) before continuing.
- [ ] A Vault token whose policy grants the capabilities below. The token
      goes into `var.vault_token`.

### Token policy

The token needs `read` on `sys/mounts` (so the migration can enumerate
mounts) plus `read` and `list` on every per-app GCP path. Minimum HCL:

```hcl
# Required: enumerate mounts to discover <env>/<app>/gcp/ paths.
path "sys/mounts" {
  capabilities = ["read"]
}

# Required: read and list every GCP entity under every app mount.
# Tighten the wildcard if your environment uses a stricter naming policy.
path "+/+/gcp/static-account"        { capabilities = ["list"] }
path "+/+/gcp/static-account/*"      { capabilities = ["read"] }
path "+/+/gcp/impersonated-account"  { capabilities = ["list"] }
path "+/+/gcp/impersonated-account/*"{ capabilities = ["read"] }
path "+/+/gcp/roleset"               { capabilities = ["list"] }
path "+/+/gcp/roleset/*"             { capabilities = ["read"] }
```

Save as `vault-to-akeyless-migration.hcl` and load:

```bash
vault policy write vault-to-akeyless-migration ./vault-to-akeyless-migration.hcl
vault token create -policy=vault-to-akeyless-migration -ttl=1h -format=json \
  | jq -r .auth.client_token
```

### Verify the token

```bash
export VAULT_TOKEN=<token-from-above>
curl -sH "X-Vault-Token: $VAULT_TOKEN" \
  "$VAULT_ADDR/v1/sys/mounts" \
  | jq '.data | with_entries(select(.value.type=="gcp")) | keys'
```

Expected: a JSON array of mount paths like
`["prod/app-1234-saas/gcp/", "prod/app-9999-newco/gcp/"]`, one per
application. An empty array means no GCP mounts exist yet; see
[`03-vault-structure.md`](03-vault-structure.md). A `403` means the policy
is missing.

## Akeyless

- [ ] An Akeyless access ID (`p-XXXXXXXXXXXXXX`) bound to an auth method
      Terraform can use. The default in `main.tf` is `gcp_login` (GCP-SA
      auth method); see [the GCP-SA caveat below](#gcp-sa-auth-vs-other-methods).
- [ ] An access role attached to that access ID with permission to create
      targets and dynamic secrets under every `<env>/<app>/gcp/rolesets/`
      path the migration will write to.
- [ ] Your gateway's V2 SDK URL. The provider's `api_gateway_address` must
      point at *your* gateway, not `https://api.akeyless.io`. The public
      API does not expose `dynamic-secret-create-gcp`.

### Find your access ID

```bash
akeyless auth-method list \
  | jq -r '.auth_methods[] | "\(.auth_method_access_id)  \(.auth_method_name)  \(.access_info.access_id_alias // "-")"'
```

Expected: a list with one row per auth method. The first column is the
access ID you put into `var.akeyless_access_id`. Filter by name if you
already know which auth method to use.

### Verify the gateway URL

There are two valid path suffixes depending on how your gateway is exposed:

- Gateway reachable on its native SDK port (e.g. `:8081` direct or
  port-forward) uses `/v2`, e.g. `https://gateway.example.com:8081/v2`.
- Gateway fronted by an ingress (nginx, Istio) that mounts the gateway
  behind a path-based route uses `/api/v2`, e.g.
  `https://gateway.example.com/api/v2`. The ingress strips or rewrites
  the prefix so the upstream still sees `/v2`.

If you do not know which form applies, try `/v2` first; if it 404s on a
known endpoint, switch to `/api/v2`.

```bash
URL="$AKEYLESS_GATEWAY_URL"
curl -sI "${URL}/configurations/get-status" -X POST
```

Expected: `HTTP/1.1 400` or `HTTP/2 400` (this endpoint requires a body;
the 400 only proves TLS reachability and routing). `HTTP/2 404` with a
`text/plain` body usually means the path suffix is wrong: switch
between `/v2` and `/api/v2` and retry. A network error means the URL is
wrong or the gateway is not reachable from your Terraform host.

### GCP-SA auth vs. other methods

The default `provider "akeyless"` block in `gcp/main.tf` uses `gcp_login`,
which only works on a GCE host whose service account is bound to the
configured access ID. If you are running Terraform off a GCE host, swap
the block:

```hcl
provider "akeyless" {
  api_gateway_address = var.akeyless_gateway_url

  api_key_login {
    access_id  = var.akeyless_access_id
    access_key = var.akeyless_access_key   # add this variable yourself
  }
}
```

See `gcp/main.tf` for the commented alternatives.

## Parent service account

- [ ] One Google service account designated as the parent. Its JSON key
      lives in `var.parent_sa_credentials` and is forwarded into the
      Akeyless target.
- [ ] Bindings: `roles/iam.serviceAccountTokenCreator` and
      `roles/iam.serviceAccountKeyAdmin`, either on every child SA or
      project-wide (less granular but easier).

The full creation walkthrough lives in
[`06-parent-sa-and-target.md`](06-parent-sa-and-target.md).

## Local tools

- [ ] Terraform 1.5 or newer.
- [ ] `gcloud` authenticated against the project that holds the parent
      and child SAs.
- [ ] `akeyless` CLI for verification commands.
- [ ] `jq` for parsing the verification snippets in this runbook.

When you run Terraform from a GCE VM, `gcloud` defaults to the VM's
attached compute service account. That identity is what the Akeyless
provider's `gcp_login` block uses, but its access scopes typically
exclude IAM admin, so the SA-management commands later in
[`06-parent-sa-and-target.md`](06-parent-sa-and-target.md) and
[`05-roleset-durable-sa.md`](05-roleset-durable-sa.md) will return
`ACCESS_TOKEN_SCOPE_INSUFFICIENT`. Authenticate a user identity (or an
admin SA whose key you trust on the VM) for those steps with
`gcloud auth login` or
`gcloud auth activate-service-account --key-file=<admin-key>.json`,
then switch back to the VM SA when you need `gcp_login`.

### Verify versions

```bash
terraform version | head -1
gcloud --version | head -1
akeyless --version
jq --version
```

Expected output (versions vary, what matters is each command resolves):

```
Terraform v1.5.7
Google Cloud SDK 470.0.0
Version: 1.139.0.fb23a68
jq-1.7.1
```

## Information to gather

Collect these before running `terraform plan`. They map 1:1 to the tfvars.

| Parameter | Description | Example |
|---|---|---|
| `vault_address` | Vault server URL. | `https://vault.example.com` |
| `vault_token` | Token with the policy above. | `hvs.XXXXX` |
| `akeyless_access_id` | Access ID of the Akeyless auth method. | `p-XXXXXXXXXXXXXX` |
| `akeyless_gcp_audience` | Audience claim for `gcp_login`. | `akeyless.io` |
| `akeyless_gateway_url` | Your gateway's V2 SDK URL. | `https://gateway.example.com:8081/v2` |
| `akeyless_target_name` | Name of the Akeyless GCP target. | `migrated-from-vault-gcp` |
| `parent_sa_credentials` | Raw JSON of the parent SA key. | `{...}` (load via env var) |
| `roleset_sa_overrides` | Map keyed `<env>/<app>/<roleset_name>`. | See [`05-roleset-durable-sa.md`](05-roleset-durable-sa.md). |

## Next steps

- [Vault structure](03-vault-structure.md). The one-mount-per-app
  layout, the entity-level `-app` runtime split, and how to populate it
  with `vault secrets enable` and `vault write`.
