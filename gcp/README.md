# GCP module

Terraform that discovers the HashiCorp Vault GCP secrets engine on a
per-app basis (one mount per `<env>/<app>/gcp/`) and creates one Akeyless
target plus one Akeyless dynamic secret per Vault entity. All three Vault
entity types (`static-account`, `impersonated-account`, `roleset`)
collapse into the same Akeyless folder:

```
<env>/<app>/gcp/rolesets/<entity_name>
```

Each app has one mount. The Kubernetes vs non-Kubernetes split is at
the entity level inside that mount: by convention, `<entity_name>` is
the non-Kubernetes variant and `<entity_name>-app` is the Kubernetes
variant. Both live under the same `<env>/<app>/gcp/` mount.

For the deep-dive, read the runbooks in order:

| File | Covers |
|---|---|
| [`runbooks/01-architecture-overview.md`](runbooks/01-architecture-overview.md) | Components, data flow, naming convention, the rolesets-collapse table. |
| [`runbooks/02-prerequisites.md`](runbooks/02-prerequisites.md) | Vault token policy, Akeyless access ID, gateway URL, parent SA, local tools. |
| [`runbooks/03-vault-structure.md`](runbooks/03-vault-structure.md) | The one-mount-per-app rule, entity-level `-app` runtime split, `vault secrets enable`, `vault write` for each kind. |
| [`runbooks/04-discovery-walkthrough.md`](runbooks/04-discovery-walkthrough.md) | Every HTTP call the module makes, in raw `curl` form, for out-of-band verification. |
| [`runbooks/05-roleset-durable-sa.md`](runbooks/05-roleset-durable-sa.md) | Why rolesets need a durable pre-created SA; minting and binding it; wiring `var.roleset_sa_overrides`. |
| [`runbooks/06-parent-sa-and-target.md`](runbooks/06-parent-sa-and-target.md) | Parent SA, IAM roles, JSON key handling, the single shared Akeyless target. |
| [`runbooks/07-first-plan-and-apply.md`](runbooks/07-first-plan-and-apply.md) | tfvars setup, env vars, `terraform plan` predictions, `akeyless` CLI verification. |
| [`runbooks/08-day-2-operations.md`](runbooks/08-day-2-operations.md) | Adding apps, adding rolesets, removing entities, rotating the parent SA. |
| [`runbooks/09-troubleshooting.md`](runbooks/09-troubleshooting.md) | Categorized failures with exact errors, diagnoses, and fixes. |

## Variables

| Name | Type | Default | Description |
|---|---|---|---|
| `vault_address` | `string` | required | Vault server URL. Easiest: `export TF_VAR_vault_address="$VAULT_ADDR"`. |
| `vault_token` | `string` (sensitive) | required | Token with `read` on `sys/mounts` plus `read` and `list` on every `<env>/<app>/gcp/{static-account,impersonated-account,roleset}` path. Easiest: `export TF_VAR_vault_token="$VAULT_TOKEN"`. |
| `akeyless_access_id` | `string` | required | Akeyless access ID used by the provider login block. |
| `akeyless_gcp_audience` | `string` | `"akeyless.io"` | Audience used by the GCP-SA auth method. |
| `akeyless_gateway_url` | `string` | required | Your gateway's V2 SDK URL with `/v2` appended (e.g. `https://gateway.example.com:8081/v2`). Not the public `api.akeyless.io`. |
| `akeyless_target_name` | `string` | `"migrated-from-vault-gcp"` | Name of the single Akeyless GCP target this module creates. Shared across all apps. |
| `parent_sa_credentials` | `string` (sensitive) | required | Raw JSON content of the parent SA key. The module base64-encodes it before sending. |
| `roleset_sa_overrides` | `map(string)` | `{}` | Map keyed `<env>/<app>/<roleset_name>` to a durable SA email. Required for every roleset discovered. See [`runbooks/05-roleset-durable-sa.md`](runbooks/05-roleset-durable-sa.md). |

## Outputs

- `migration_summary` (sensitive): one record per migrated dynamic secret
  with `env`, `app`, `vault_mount`, `vault_type`, `vault_name`,
  `akeyless_path`, `gcp_sa_email`, `cred_type`, `mode`.
- `rolesets_missing_override`: roleset paths discovered in Vault but
  missing from `var.roleset_sa_overrides`. Empty after a successful apply.
- `akeyless_target_name`: the name of the single shared Akeyless GCP target.

## Quick run

```bash
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars: akeyless_access_id, akeyless_gateway_url, roleset_sa_overrides
export TF_VAR_vault_address="$VAULT_ADDR"
export TF_VAR_vault_token="$VAULT_TOKEN"
export TF_VAR_parent_sa_credentials="$(cat ./parent-sa.json)"
terraform init
terraform plan
terraform apply
```

Detail and verification commands live in
[`runbooks/07-first-plan-and-apply.md`](runbooks/07-first-plan-and-apply.md).
