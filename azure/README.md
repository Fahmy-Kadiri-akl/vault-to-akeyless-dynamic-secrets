# Azure module (coming soon)

Will follow the same pattern as the GCP module, applied to Vault `azure/` mounts:

- Existing service principals (Vault `azure/roles/<name>` with `application_object_id`)
- Dynamic service principals (Vault creates a new SP per lease; like the GCP roleset case, this needs an operator-supplied durable SP)

These will map to `akeyless_target_azure` plus one `akeyless_dynamic_secret_azure` per Vault entity. The parent client ID plus client secret (or federated credential) is passed in as sensitive Terraform variables.

See the top-level `README.md` for the overall migration model.
