# Passes inputs into the module that are only known after apply, as when the role or the Google service account
# are created in the same configuration. The module must still be able to plan, i.e. its resource counts must not
# depend on these inputs.

terraform {
  required_providers {
    google = {
      source = "hashicorp/google"
    }
    kubernetes = {
      source = "hashicorp/kubernetes"
    }
    random = {
      source = "hashicorp/random"
    }
  }
}

resource "google_project_iam_custom_role" "operator" {
  project     = "my-gsm-project"
  role_id     = "secretmanager.readwrite"
  title       = "Secret Reader/Writer"
  permissions = ["secretmanager.versions.access"]
}

resource "google_service_account" "operator" {
  project    = "my-gke-project"
  account_id = "humanitec-operator"
}

resource "google_service_account_key" "operator" {
  service_account_id = google_service_account.operator.name
}

module "passed_in_role" {
  source = "../../.."

  secret_store_id            = "passed-in-role"
  secret_manager_project_id  = "my-gsm-project"
  gke_project_id             = "my-gke-project"
  secret_manager_role_create = false
  secret_manager_role        = google_project_iam_custom_role.operator.name
}

module "workload_identity_with_existing_service_account" {
  source = "../../.."

  secret_store_id           = "existing-sa-wi"
  secret_store_default      = false
  secret_manager_project_id = "my-gsm-project"
  gke_project_id            = "my-gke-project"
  service_account_create    = false
  service_account_email     = google_service_account.operator.email
}

module "service_account_key_with_existing_service_account" {
  source = "../../.."

  secret_store_id           = "existing-sa-key"
  secret_store_default      = false
  secret_manager_project_id = "my-gsm-project"
  auth_method               = "service_account_key"
  service_account_create    = false
  service_account_email     = google_service_account.operator.email
  service_account_key       = base64decode(google_service_account_key.operator.private_key)
}

output "passed_in_role_custom_role_id" {
  value = module.passed_in_role.secret_manager_custom_role_id
}
output "workload_identity_with_existing_service_account_member" {
  value = module.workload_identity_with_existing_service_account.workload_identity_member
}
output "service_account_key_with_existing_service_account_secret_name" {
  value = module.service_account_key_with_existing_service_account.service_account_credentials_secret_name
}
