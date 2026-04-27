# AWS module — coming soon

Will mirror the GCP module pattern for Vault `aws/` mounts:

- IAM users (`aws/roles/<name>` with `credential_type = iam_user`)
- Assumed roles (`credential_type = assumed_role`)
- Federation tokens (`credential_type = federation_token`)

Mapped to `akeyless_target_aws` + `akeyless_dynamic_secret_aws`. Same provider
constraints as GCP: only `hashicorp/vault` + `akeyless-community/akeyless`,
no `aws` provider, no AWS SDK calls. The customer-supplied parent IAM access
key + secret will be passed in as sensitive tfvars and forwarded into the
Akeyless target.

See the top-level `README.md` for the overall migration model.
