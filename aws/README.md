# AWS module (coming soon)

Will follow the same pattern as the GCP module, applied to Vault `aws/` mounts:

- IAM users (`aws/roles/<name>` with `credential_type = iam_user`)
- Assumed roles (`credential_type = assumed_role`)
- Federation tokens (`credential_type = federation_token`)

These will map to `akeyless_target_aws` plus one `akeyless_dynamic_secret_aws` per Vault entity. The parent IAM access key and secret are passed in as sensitive Terraform variables and forwarded into the Akeyless target.

See the top-level `README.md` for the overall migration model.
