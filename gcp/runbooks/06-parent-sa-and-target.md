# Parent SA and Akeyless Target

Akeyless does not generate Google credentials directly. Each migrated
dynamic secret references a child service account (Vault static account,
impersonated account, or the durable SA created for a roleset), and
Akeyless mints per-lease tokens or keys against that child by calling
Google's IAM Credentials API as a *parent* service account. This runbook
covers minting the parent SA and wiring its JSON into the single
`akeyless_target_gcp` resource the module creates.

## IAM roles required on the parent SA

Akeyless needs at minimum:

- `roles/iam.serviceAccountTokenCreator` on each child SA, for
  ACCESS_TOKEN-mode dynamic secrets (impersonated accounts, token-mode
  static accounts, and the durable SAs you mapped rolesets to).
- `roles/iam.serviceAccountKeyAdmin` on each child SA, for KEY-mode
  dynamic secrets (any static account whose Vault `secret_type` is
  `service_account_key`).

Bind project-wide for ease, or per child SA for least-privilege.

### Extra roles when the same SA is the Vault GCP config SA and any rolesets exist

In the per-app walkthrough in
[`03-vault-structure.md`](03-vault-structure.md), the parent SA's JSON
key is also the credentials handed to `vault write <mount>/gcp/config`.
Vault uses that identity at *roleset write time* to create one
ephemeral service account per roleset and bind IAM policies to it.
Those operations need IAM-admin authority that token-creator and
key-admin alone do not grant. When the parent SA doubles as the Vault
GCP config SA and any rolesets are in scope, also bind:

- `roles/iam.serviceAccountAdmin` (so Vault can create and delete
  per-roleset service accounts).
- `roles/resourcemanager.projectIamAdmin` (so Vault can edit the
  project IAM policy when a roleset's `bindings` block grants project
  roles).

Without these, `vault write <mount>/gcp/roleset/<name>` fails with
`Permission 'iam.serviceAccounts.create' denied` and the rolesets
section of [`03-vault-structure.md`](03-vault-structure.md) cannot be
executed verbatim.

If you prefer least-privilege, split the SAs: keep one parent SA with
just the two token/key roles for Akeyless to call as, and use a
separate "Vault config SA" with the four roles above (token-creator,
key-admin, serviceAccountAdmin, projectIamAdmin) for
`vault write <mount>/gcp/config`. Only the Akeyless-target SA's JSON
ends up in `var.parent_sa_credentials`.

## Minting the parent SA

These steps are IAM-admin work. The simplest path is to run them from
your workstation (where `gcloud auth list` already shows a user
identity) and `gcloud compute scp ./parent-sa.json <vm>:~/...` the
resulting key onto the VM before `terraform apply`. See the
"Local tools" bullet in
[`02-prerequisites.md`](02-prerequisites.md#local-tools).

If you are running these `gcloud` commands from a GCE VM, the default
identity is the VM's attached compute SA, whose scopes typically exclude
IAM admin. `gcloud iam service-accounts create` and
`gcloud projects add-iam-policy-binding` will return
`ACCESS_TOKEN_SCOPE_INSUFFICIENT` until you switch to a user identity or
an admin SA. Run `gcloud auth login` (interactive) or
`gcloud auth activate-service-account --key-file=<admin-key>.json` first.
Keep that identity separate from the VM SA used by the Akeyless
provider's `gcp_login`; you only need the IAM-admin identity for the
SA-creation and binding steps below.

Replace `<your-project>` and `<sa-id>` with your values:

```bash
PROJECT=<your-project>
SA_ID=<sa-id>                     # e.g. akeyless-migration-parent
SA_EMAIL="${SA_ID}@${PROJECT}.iam.gserviceaccount.com"

gcloud iam service-accounts create "$SA_ID" \
  --project "$PROJECT" \
  --display-name "Akeyless migration parent SA"

# Bind the required roles project-wide. For least-privilege, bind per
# child SA instead (see 05-roleset-durable-sa.md).
gcloud projects add-iam-policy-binding "$PROJECT" \
  --member "serviceAccount:${SA_EMAIL}" \
  --role   "roles/iam.serviceAccountTokenCreator"

gcloud projects add-iam-policy-binding "$PROJECT" \
  --member "serviceAccount:${SA_EMAIL}" \
  --role   "roles/iam.serviceAccountKeyAdmin"

# Add these two only if the same SA is also the Vault GCP config SA AND
# any rolesets are in scope. See "Extra roles when the same SA is the
# Vault GCP config SA and any rolesets exist" above.
gcloud projects add-iam-policy-binding "$PROJECT" \
  --member "serviceAccount:${SA_EMAIL}" \
  --role   "roles/iam.serviceAccountAdmin"

gcloud projects add-iam-policy-binding "$PROJECT" \
  --member "serviceAccount:${SA_EMAIL}" \
  --role   "roles/resourcemanager.projectIamAdmin"

# Mint and download the JSON key. Keep this file out of git
# (.gitignore already excludes parent-sa.json and *.json).
gcloud iam service-accounts keys create ./parent-sa.json \
  --iam-account "$SA_EMAIL" \
  --project     "$PROJECT"
```

Pass the JSON to Terraform as an env var (cleanest, since
`terraform.tfvars` does not accept the `file()` function):

```bash
export TF_VAR_parent_sa_credentials="$(cat ./parent-sa.json)"
```

Or via `-var` on the command line:

```bash
terraform plan -var "parent_sa_credentials=$(cat ./parent-sa.json)"
```

The variable is typed `string` and marked `sensitive`. The module
base64-encodes it before sending to the Akeyless target's `gcp_key`
field.

## Verify

### Confirm the JSON key works

```bash
gcloud auth activate-service-account --key-file=./parent-sa.json
gcloud config set project "$PROJECT"
gcloud auth list --format='value(account)'
```

Expected: the parent SA email appears as the active account.

### Confirm the parent has token-creator on a sample child

Pick any child SA the migration will reference (a static account email,
an impersonated account email, or a durable roleset SA email):

```bash
CHILD_SA_EMAIL=<one-of-your-child-sa-emails>

gcloud iam service-accounts get-iam-policy "$CHILD_SA_EMAIL" \
  --project "$PROJECT" \
  --format='table(bindings.role,bindings.members)'
```

Expected: a row listing `roles/iam.serviceAccountTokenCreator` (and, for
key-mode static accounts, `roles/iam.serviceAccountKeyAdmin`) with the
parent SA email in the `members` column. If you bound the roles
project-wide, this command may show no per-SA bindings; verify
project-wide instead:

```bash
gcloud projects get-iam-policy "$PROJECT" \
  --flatten='bindings[].members' \
  --filter="bindings.members:serviceAccount:${SA_EMAIL}" \
  --format='table(bindings.role)'
```

Expected: at least the two roles above.

### Confirm the parent can actually mint a token

```bash
gcloud iam service-accounts keys list --iam-account "$CHILD_SA_EMAIL" \
  --project "$PROJECT" >/dev/null

gcloud iam service-accounts get-access-token "$CHILD_SA_EMAIL" \
  --project "$PROJECT" \
  --scopes="https://www.googleapis.com/auth/cloud-platform" \
  | head -c 60; echo
```

Expected: a base64-ish token prefix prints. A `403` here means the parent
SA does not actually have token-creator on the child SA, even if the
policy lookup suggested it did. Fix bindings and retry.

## How the target is wired

The module's `target.tf` creates exactly one `akeyless_target_gcp`:

```hcl
resource "akeyless_target_gcp" "migrated_from_vault" {
  name        = var.akeyless_target_name
  description = "Created by vault-to-akeyless-dynamic-secrets migration TF. Wraps the parent SA used to mint child credentials for the migrated dynamic secrets."
  gcp_key     = base64encode(var.parent_sa_credentials)
}
```

Every `akeyless_dynamic_secret_gcp` references this target by name. There
is no per-app or per-env target by default; the parent SA's bindings
determine which children it can mint credentials for.

## Next steps

- [First plan and apply](07-first-plan-and-apply.md). Set the env vars,
  run `terraform plan`, and verify the result with the `akeyless` CLI.
