# Azure module — coming soon

Will mirror the GCP module pattern for Vault `azure/` mounts:

- Existing service principals (Vault `azure/roles/<name>` with `application_object_id`)
- Dynamic service principals (Vault creates a new SP per lease — needs an
  operator-supplied durable SP, like the GCP roleset case)

Mapped to `akeyless_target_azure` + `akeyless_dynamic_secret_azure`. Same
provider constraints as GCP: only `hashicorp/vault` +
`akeyless-community/akeyless`, no `azurerm` provider, no Azure SDK calls.
The customer-supplied parent client ID + client secret (or federated cred)
will be passed in as sensitive tfvars.

See the top-level `README.md` for the overall migration model.
