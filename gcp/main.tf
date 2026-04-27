terraform {
  required_version = ">= 1.5"

  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = ">= 4.0"
    }
    akeyless = {
      source  = "akeyless-community/akeyless"
      version = ">= 1.7"
    }
    http = {
      source  = "hashicorp/http"
      version = ">= 3.4"
    }
  }
}

provider "vault" {
  address = var.vault_address
  token   = var.vault_token
}

# Default login is GCP-SA (gcp_login). The runner must be on a GCE instance
# whose service account is bound to the configured access_id, with the
# matching audience.
#
# To use a different auth method (api_key_login, jwt_login, token_login,
# email_login, etc.), comment out the gcp_login block below and uncomment
# the one you want. See:
# https://registry.terraform.io/providers/akeyless-community/akeyless/latest/docs
provider "akeyless" {
  api_gateway_address = var.akeyless_api_url

  gcp_login {
    access_id = var.akeyless_access_id
    audience  = var.akeyless_gcp_audience
  }

  # api_key_login {
  #   access_id  = var.akeyless_access_id
  #   access_key = var.akeyless_access_key
  # }
}
