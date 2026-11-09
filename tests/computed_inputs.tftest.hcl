# Inputs only known after apply must not prevent planning the module.
# Terraform leaves computed attributes of mocked resources unknown during plan, so it reproduces this.
# OpenTofu fills them with the mocked values already during plan, which are set here so that they pass validation.
mock_provider "kubernetes" {}
mock_provider "random" {}
mock_provider "google" {
  mock_data "google_project" {
    defaults = {
      number = "123456789012"
    }
  }
  mock_resource "google_project_iam_custom_role" {
    defaults = {
      id   = "projects/my-gsm-project/roles/secretmanager.readwrite"
      name = "projects/my-gsm-project/roles/secretmanager.readwrite"
    }
  }
  mock_resource "google_service_account" {
    defaults = {
      email     = "humanitec-operator@my-gke-project.iam.gserviceaccount.com"
      name      = "projects/my-gke-project/serviceAccounts/humanitec-operator@my-gke-project.iam.gserviceaccount.com"
      unique_id = "111111111111111111111"
    }
  }
  mock_data "google_service_account" {
    defaults = {
      email     = "humanitec-operator@my-gke-project.iam.gserviceaccount.com"
      name      = "projects/my-gke-project/serviceAccounts/humanitec-operator@my-gke-project.iam.gserviceaccount.com"
      unique_id = "111111111111111111111"
    }
  }
  mock_resource "google_service_account_key" {
    defaults = {
      # base64-encoded {"type":"service_account","private_key":"created-private-key"}
      private_key = "eyJ0eXBlIjoic2VydmljZV9hY2NvdW50IiwicHJpdmF0ZV9rZXkiOiJjcmVhdGVkLXByaXZhdGUta2V5In0="
    }
  }
}

run "plans_with_inputs_known_after_apply" {
  command = plan

  module {
    source = "./tests/fixtures/computed_inputs"
  }

  assert {
    condition     = output.passed_in_role_custom_role_id == null
    error_message = "No custom role should be created if secret_manager_role_create is false"
  }
  assert {
    condition     = output.workload_identity_with_existing_service_account_member == "serviceAccount:my-gke-project.svc.id.goog[humanitec-operator-system/humanitec-operator-controller-manager]"
    error_message = "Operator service account should impersonate the Google service account passed in"
  }
  assert {
    condition     = output.service_account_key_with_existing_service_account_secret_name == "existing-sa-key-credentials"
    error_message = "Credentials Secret should be created for the key of the Google service account passed in"
  }
}
