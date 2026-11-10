# Mock all providers so the tests run without access to Google Cloud or a Kubernetes cluster
mock_provider "kubernetes" {}
mock_provider "random" {
  # The mocked result does not honor the length attribute
  mock_resource "random_string" {
    defaults = {
      result = "abcd"
    }
  }
}
mock_provider "google" {
  # Project configured in the provider, the fallback of secret_manager_project_id and gke_project_id
  mock_data "google_client_config" {
    defaults = {
      project = "my-provider-project"
    }
  }
  mock_data "google_project" {
    defaults = {
      number = "123456789012"
    }
  }
  mock_resource "google_service_account" {
    defaults = {
      email     = "created-sa@my-gsm-project.iam.gserviceaccount.com"
      name      = "projects/my-gsm-project/serviceAccounts/created-sa@my-gsm-project.iam.gserviceaccount.com"
      unique_id = "111111111111111111111"
    }
  }
  mock_data "google_service_account" {
    defaults = {
      email     = "existing-sa@identity-project.iam.gserviceaccount.com"
      name      = "projects/identity-project/serviceAccounts/existing-sa@identity-project.iam.gserviceaccount.com"
      unique_id = "222222222222222222222"
    }
  }
  mock_resource "google_service_account_key" {
    defaults = {
      id = "projects/my-gsm-project/serviceAccounts/created-sa@my-gsm-project.iam.gserviceaccount.com/keys/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      # base64-encoded {"type":"service_account","private_key":"created-private-key"}
      private_key = "eyJ0eXBlIjoic2VydmljZV9hY2NvdW50IiwicHJpdmF0ZV9rZXkiOiJjcmVhdGVkLXByaXZhdGUta2V5In0="
    }
  }
  mock_resource "google_service_account_iam_member" {
    defaults = {
      id = "projects/my-gsm-project/serviceAccounts/created-sa@my-gsm-project.iam.gserviceaccount.com/roles/iam.workloadIdentityUser/serviceAccount:my-gke-project.svc.id.goog[humanitec-operator-system/humanitec-operator-controller-manager]"
    }
  }
  mock_resource "google_project_iam_custom_role" {
    defaults = {
      id   = "projects/my-gsm-project/roles/humanitec_operator_my_gcpsm_abcd"
      name = "projects/my-gsm-project/roles/humanitec_operator_my_gcpsm_abcd"
    }
  }
  mock_resource "google_project_iam_member" {
    defaults = {
      id = "my-gsm-project/projects/my-gsm-project/roles/humanitec_operator_my_gcpsm_abcd/member"
    }
  }
}

# The minimum set of variables
variables {
  secret_store_id           = "my-gcpsm"
  secret_manager_project_id = "my-gsm-project"
  gke_project_id            = "my-gke-project"
  # Terraform tests require ephemeral variables to be set explicitly in apply runs
  service_account_key = ""
}

# Default case: Workload Identity Federation for GKE without a Google service account

run "defaults" {
  # The random suffix of the generated names is only known after apply
  command = apply

  # Secret store ID
  assert {
    condition     = length(random_string.secret_store_id_suffix) == 0
    error_message = "No random suffix should be generated if secret_store_id is set"
  }

  # Workload Identity Federation for GKE
  assert {
    condition     = data.google_project.gke[0].project_id == "my-gke-project"
    error_message = "GKE project should be read by gke_project_id for its project number"
  }

  # No Google service account
  assert {
    condition = (
      length(random_string.service_account_name_suffix) == 0 &&
      length(google_service_account.operator) == 0 &&
      length(data.google_service_account.operator) == 0 &&
      length(google_service_account_iam_member.workload_identity) == 0
    )
    error_message = "No Google service account should be used with Workload Identity by default"
  }
  assert {
    condition = (
      length(google_service_account_key.operator) == 0 &&
      length(terraform_data.service_account_key_version) == 0 &&
      length(kubernetes_secret_v1.operator_credentials) == 0
    )
    error_message = "No service account key or credentials Secret should be used with Workload Identity"
  }

  # Secret Manager access
  assert {
    condition = (
      google_project_iam_custom_role.secret_manager[0].project == "my-gsm-project" &&
      google_project_iam_custom_role.secret_manager[0].role_id == "humanitec_operator_my_gcpsm_abcd"
    )
    error_message = "Custom role should be created in the Secret Manager project as humanitec_operator_<secret_store_id>_<suffix> for the default store, got ${google_project_iam_custom_role.secret_manager[0].role_id}"
  }
  assert {
    condition = (
      google_project_iam_custom_role.secret_manager[0].title == "Humanitec Operator my-gcpsm" &&
      google_project_iam_custom_role.secret_manager[0].description == "Humanitec Operator read/write access to the Google Cloud Secret Manager secret store my-gcpsm"
    )
    error_message = "Custom role should have a title and description naming the secret store"
  }
  assert {
    condition = google_project_iam_custom_role.secret_manager[0].permissions == toset([
      "secretmanager.secrets.create",
      "secretmanager.secrets.delete",
      "secretmanager.secrets.update",
      "secretmanager.versions.add",
      "secretmanager.versions.access",
      "secretmanager.versions.list",
      "secretmanager.versions.destroy",
    ])
    error_message = "Custom role should have the least-privilege read/write permissions for the default store"
  }
  assert {
    condition = (
      google_project_iam_member.operator[0].project == "my-gsm-project" &&
      google_project_iam_member.operator[0].role == google_project_iam_custom_role.secret_manager[0].name
    )
    error_message = "IAM role binding should grant the custom role on the Secret Manager project for the default store"
  }
  assert {
    condition     = google_project_iam_member.operator[0].member == "principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/my-gke-project.svc.id.goog/subject/ns/humanitec-operator-system/sa/humanitec-operator-controller-manager"
    error_message = "IAM role binding should be for the principal of the Operator service account, got ${google_project_iam_member.operator[0].member}"
  }
  assert {
    condition     = length(google_project_iam_member.operator[0].condition) == 0
    error_message = "IAM role binding should not have a condition"
  }

  # Secret store
  assert {
    condition = (
      kubernetes_manifest.secret_store.manifest.apiVersion == "humanitec.io/v1alpha1" &&
      kubernetes_manifest.secret_store.manifest.kind == "SecretStore"
    )
    error_message = "Secret store should be a humanitec.io/v1alpha1 SecretStore"
  }
  assert {
    condition = (
      kubernetes_manifest.secret_store.manifest.metadata.name == "my-gcpsm" &&
      kubernetes_manifest.secret_store.manifest.metadata.namespace == "humanitec-operator-system"
    )
    error_message = "Secret store should be named secret_store_id and be cluster-wide in the Operator namespace by default"
  }
  assert {
    condition     = kubernetes_manifest.secret_store.manifest.metadata.labels["app.humanitec.io/default-store"] == "true" && length(kubernetes_manifest.secret_store.manifest.metadata.labels) == 1
    error_message = "Secret store should be labelled as the default store by default"
  }
  assert {
    condition     = kubernetes_manifest.secret_store.manifest.spec.gcpsm.projectID == "my-gsm-project"
    error_message = "Secret store should use the Secret Manager project"
  }
  assert {
    condition     = !can(kubernetes_manifest.secret_store.manifest.spec.gcpsm.locationID)
    error_message = "Secret store should not have a location for the global Secret Manager"
  }
  assert {
    condition     = kubernetes_manifest.secret_store.manifest.spec.gcpsm.auth == {}
    error_message = "Secret store should have an empty auth object with Workload Identity. A map cannot be converted to the SecretStore CRD schema by kubernetes_manifest"
  }
  assert {
    condition = (
      terraform_data.secret_store_replacement_triggers.output.auth_method == "workload_identity" &&
      terraform_data.secret_store_replacement_triggers.output.secret_manager_location == null
    )
    error_message = "Auth method and location should be tracked, so that changing them replaces the secret store"
  }

  # Outputs
  assert {
    condition = (
      output.secret_store_id == "my-gcpsm" &&
      output.secret_store_namespace == "humanitec-operator-system" &&
      output.secret_manager_project_id == "my-gsm-project" &&
      output.secret_manager_location == null
    )
    error_message = "Secret store ID, namespace, Secret Manager project and location outputs should use the defaults"
  }
  assert {
    condition = (
      output.secret_manager_role == "projects/my-gsm-project/roles/humanitec_operator_my_gcpsm_abcd" &&
      output.secret_manager_custom_role_id == google_project_iam_custom_role.secret_manager[0].id &&
      output.secret_manager_iam_member_id == google_project_iam_member.operator[0].id
    )
    error_message = "Secret Manager role output should be the custom role for the default store, and the custom role and IAM member ID outputs should be set"
  }
  assert {
    condition     = length(output.secret_manager_permissions) == 7 && contains(output.secret_manager_permissions, "secretmanager.secrets.create")
    error_message = "Secret Manager permissions output should list the read/write permissions for the default store"
  }
  assert {
    condition     = output.operator_iam_member == "principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/my-gke-project.svc.id.goog/subject/ns/humanitec-operator-system/sa/humanitec-operator-controller-manager"
    error_message = "Operator IAM member output should be the principal of the Operator service account"
  }
  assert {
    condition = (
      output.service_account_email == null &&
      output.service_account_id == null &&
      output.service_account_unique_id == null &&
      output.workload_identity_member == null &&
      output.workload_identity_binding_id == null &&
      output.service_account_credentials_secret_name == null
    )
    error_message = "Google service account outputs should be null without a Google service account"
  }
  assert {
    condition     = length(output.operator_serviceaccount_annotations) == 0
    error_message = "Operator service account annotations output should be empty without a Google service account"
  }
}

# Variations of the secret store

run "generated_secret_store_id" {
  command = apply

  variables {
    secret_store_id = null
  }

  assert {
    condition     = length(random_string.secret_store_id_suffix) == 1 && random_string.secret_store_id_suffix[0].length == 4
    error_message = "A random suffix of four characters should be generated for the secret store ID"
  }
  assert {
    condition = (
      random_string.secret_store_id_suffix[0].upper == false &&
      random_string.secret_store_id_suffix[0].numeric == false &&
      random_string.secret_store_id_suffix[0].special == false
    )
    error_message = "The random suffix of the secret store ID should consist of lowercase letters only"
  }
  assert {
    condition     = kubernetes_manifest.secret_store.manifest.metadata.name == "gcpsm-abcd"
    error_message = "Secret store ID should be generated as gcpsm-<random>, got ${kubernetes_manifest.secret_store.manifest.metadata.name}"
  }
  assert {
    condition     = output.secret_store_id == "gcpsm-abcd"
    error_message = "Secret store ID output should be the generated ID"
  }
}

run "generated_secret_store_id_with_service_account_key" {
  command = apply

  variables {
    secret_store_id = null
    auth_method     = "service_account_key"
    gke_project_id  = null
  }

  assert {
    condition = (
      google_service_account.operator[0].account_id == "humanitec-gcpsm-abcd-abcd" &&
      google_service_account.operator[0].display_name == "Humanitec Operator gcpsm-abcd"
    )
    error_message = "Google service account account ID and display name should be based on the generated secret store ID, got ${google_service_account.operator[0].account_id}"
  }
  assert {
    condition     = kubernetes_secret_v1.operator_credentials[0].metadata[0].name == "gcpsm-abcd-credentials"
    error_message = "Credentials Secret name should be based on the generated secret store ID"
  }
}

run "non_default_store" {
  command = apply

  variables {
    secret_store_default = false
  }

  assert {
    condition     = !can(kubernetes_manifest.secret_store.manifest.metadata.labels)
    error_message = "Non-default secret store should not be labelled as the default store"
  }
  assert {
    condition     = kubernetes_manifest.secret_store.manifest.metadata.namespace == "humanitec-operator-system"
    error_message = "Non-default secret store should still be cluster-wide by default"
  }
  assert {
    condition = (
      length(random_string.secret_manager_role_suffix) == 0 &&
      length(google_project_iam_custom_role.secret_manager) == 0
    )
    error_message = "No custom role should be created for a non-default store"
  }
  assert {
    condition     = google_project_iam_member.operator[0].role == "roles/secretmanager.secretAccessor"
    error_message = "IAM role binding should only grant read access for a non-default store"
  }
  assert {
    condition = (
      output.secret_manager_role == "roles/secretmanager.secretAccessor" &&
      output.secret_manager_permissions == tolist(["secretmanager.versions.access"]) &&
      output.secret_manager_custom_role_id == null
    )
    error_message = "Secret Manager role and permissions outputs should be read-only for a non-default store"
  }
}

run "environment_local_store" {
  command = apply

  variables {
    secret_store_default      = false
    secret_store_cluster_wide = false
    secret_store_namespace    = "my-app-development"
  }

  assert {
    condition     = kubernetes_manifest.secret_store.manifest.metadata.namespace == "my-app-development"
    error_message = "Environment-local secret store should be created in secret_store_namespace"
  }
  assert {
    condition     = !can(kubernetes_manifest.secret_store.manifest.metadata.labels)
    error_message = "Environment-local secret store should not be labelled as the default store"
  }
  assert {
    condition     = output.secret_store_namespace == "my-app-development"
    error_message = "Secret store namespace output should be secret_store_namespace"
  }
  assert {
    condition     = google_project_iam_member.operator[0].member == "principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/my-gke-project.svc.id.goog/subject/ns/humanitec-operator-system/sa/humanitec-operator-controller-manager"
    error_message = "IAM role binding should still be for the Operator service account for an Environment-local store"
  }
}

run "regional_secret_manager" {
  command = apply

  variables {
    secret_manager_location = "europe-west3"
  }

  assert {
    condition = (
      kubernetes_manifest.secret_store.manifest.spec.gcpsm.projectID == "my-gsm-project" &&
      kubernetes_manifest.secret_store.manifest.spec.gcpsm.locationID == "europe-west3"
    )
    error_message = "Secret store should use the project and location of the regional Secret Manager"
  }
  assert {
    condition     = kubernetes_manifest.secret_store.manifest.spec.gcpsm.auth == {}
    error_message = "Secret store should still have an empty auth object with a location"
  }
  assert {
    condition     = terraform_data.secret_store_replacement_triggers.output.secret_manager_location == "europe-west3"
    error_message = "Location should be tracked, so that changing it replaces the secret store"
  }
  assert {
    condition     = output.secret_manager_location == "europe-west3"
    error_message = "Secret Manager location output should be secret_manager_location"
  }
}

# Variations of the Secret Manager access

run "custom_secret_manager_role" {
  command = apply

  variables {
    secret_manager_role = "projects/my-gsm-project/roles/secretmanager.readwrite"
  }

  assert {
    condition = (
      length(random_string.secret_manager_role_suffix) == 0 &&
      length(google_project_iam_custom_role.secret_manager) == 0
    )
    error_message = "No custom role should be created if secret_manager_role is set"
  }
  assert {
    condition     = google_project_iam_member.operator[0].role == "projects/my-gsm-project/roles/secretmanager.readwrite"
    error_message = "IAM role binding should use secret_manager_role"
  }
  assert {
    condition     = output.secret_manager_role == "projects/my-gsm-project/roles/secretmanager.readwrite"
    error_message = "Secret Manager role output should be secret_manager_role"
  }
}

run "without_secret_manager_access" {
  command = apply

  variables {
    secret_store_default         = false
    secret_manager_access_create = false
  }

  assert {
    condition     = length(google_project_iam_member.operator) == 0
    error_message = "No IAM role binding should be created if secret_manager_access_create is false"
  }
  assert {
    condition     = output.secret_manager_iam_member_id == null
    error_message = "IAM member ID output should be null if secret_manager_access_create is false"
  }
  assert {
    condition = (
      output.secret_manager_role == "roles/secretmanager.secretAccessor" &&
      output.operator_iam_member == "principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/my-gke-project.svc.id.goog/subject/ns/humanitec-operator-system/sa/humanitec-operator-controller-manager"
    )
    error_message = "Secret Manager role and Operator IAM member outputs should still name the access to grant if secret_manager_access_create is false"
  }
  assert {
    condition     = output.secret_store_id == "my-gcpsm"
    error_message = "Secret store should still be created if secret_manager_access_create is false"
  }
}

run "default_store_without_secret_manager_access" {
  command = apply

  variables {
    secret_manager_access_create = false
  }

  assert {
    condition = (
      length(random_string.secret_manager_role_suffix) == 0 &&
      length(google_project_iam_custom_role.secret_manager) == 0 &&
      length(google_project_iam_member.operator) == 0
    )
    error_message = "Neither a custom role nor an IAM role binding should be created if secret_manager_access_create is false"
  }
  assert {
    condition = (
      output.secret_manager_role == null &&
      output.secret_manager_custom_role_id == null &&
      length(output.secret_manager_permissions) == 7
    )
    error_message = "Secret Manager role output should be null, and the permissions output should list the read/write permissions to grant, if secret_manager_access_create is false for the default store"
  }
}

run "default_store_with_builtin_role" {
  command = apply

  variables {
    secret_manager_role = "roles/secretmanager.admin"
  }

  assert {
    condition     = length(google_project_iam_custom_role.secret_manager) == 0
    error_message = "No custom role should be created if a built-in role is passed in"
  }
  assert {
    condition = (
      google_project_iam_member.operator[0].role == "roles/secretmanager.admin" &&
      output.secret_manager_role == "roles/secretmanager.admin"
    )
    error_message = "IAM role binding and Secret Manager role output should use the built-in role passed in"
  }
}

# Workload Identity with a Google service account

run "complete_workload_identity_create_service_account" {
  command = apply

  variables {
    secret_store_id              = "complete-gcpsm"
    operator_namespace           = "my-operator"
    operator_serviceaccount      = "my-operator-sa"
    service_account_create       = true
    service_account_name         = "my-operator-gsa"
    service_account_display_name = "My Operator"
    service_account_project_id   = "my-identity-project"
  }

  # Google service account
  assert {
    condition     = length(random_string.service_account_name_suffix) == 0
    error_message = "No random suffix should be generated if service_account_name is set"
  }
  assert {
    condition = (
      google_service_account.operator[0].account_id == "my-operator-gsa" &&
      google_service_account.operator[0].display_name == "My Operator" &&
      google_service_account.operator[0].project == "my-identity-project"
    )
    error_message = "Google service account should use service_account_name, service_account_display_name and service_account_project_id"
  }
  assert {
    condition     = google_service_account.operator[0].description == "Humanitec Operator access to the Google Cloud Secret Manager secret store complete-gcpsm"
    error_message = "Google service account should have a description naming the secret store"
  }
  assert {
    condition     = length(data.google_service_account.operator) == 0 && length(data.google_project.gke) == 0
    error_message = "Neither an existing Google service account nor the GKE project should be read if the module creates the service account"
  }

  # Workload Identity binding
  assert {
    condition = (
      google_service_account_iam_member.workload_identity[0].service_account_id == "projects/my-gsm-project/serviceAccounts/created-sa@my-gsm-project.iam.gserviceaccount.com" &&
      google_service_account_iam_member.workload_identity[0].role == "roles/iam.workloadIdentityUser" &&
      google_service_account_iam_member.workload_identity[0].member == "serviceAccount:my-gke-project.svc.id.goog[my-operator/my-operator-sa]"
    )
    error_message = "Workload Identity binding should allow the custom Operator service account to impersonate the new Google service account"
  }

  # Secret Manager access
  assert {
    condition     = google_project_iam_member.operator[0].member == "serviceAccount:created-sa@my-gsm-project.iam.gserviceaccount.com"
    error_message = "IAM role binding should be for the new Google service account"
  }

  # No service account key
  assert {
    condition = (
      length(google_service_account_key.operator) == 0 &&
      length(terraform_data.service_account_key_version) == 0 &&
      length(kubernetes_secret_v1.operator_credentials) == 0
    )
    error_message = "No service account key or credentials Secret should be used with Workload Identity"
  }

  # Secret store
  assert {
    condition = (
      kubernetes_manifest.secret_store.manifest.metadata.name == "complete-gcpsm" &&
      kubernetes_manifest.secret_store.manifest.metadata.namespace == "my-operator"
    )
    error_message = "Secret store should use secret_store_id and operator_namespace"
  }
  assert {
    condition     = kubernetes_manifest.secret_store.manifest.spec.gcpsm.auth == {}
    error_message = "Secret store should have an empty auth object with Workload Identity and a Google service account"
  }

  # Outputs
  assert {
    condition = (
      output.service_account_email == "created-sa@my-gsm-project.iam.gserviceaccount.com" &&
      output.service_account_id == "projects/my-gsm-project/serviceAccounts/created-sa@my-gsm-project.iam.gserviceaccount.com" &&
      output.service_account_unique_id == "111111111111111111111" &&
      output.operator_iam_member == "serviceAccount:created-sa@my-gsm-project.iam.gserviceaccount.com"
    )
    error_message = "Google service account and Operator IAM member outputs should be those of the new Google service account"
  }
  assert {
    condition = (
      output.workload_identity_member == "serviceAccount:my-gke-project.svc.id.goog[my-operator/my-operator-sa]" &&
      output.workload_identity_binding_id == google_service_account_iam_member.workload_identity[0].id
    )
    error_message = "Workload Identity member and binding ID outputs should be set"
  }
  assert {
    condition     = output.operator_serviceaccount_annotations == tomap({ "iam.gke.io/gcp-service-account" = "created-sa@my-gsm-project.iam.gserviceaccount.com" })
    error_message = "Operator service account annotations output should contain the email of the new Google service account"
  }
  assert {
    condition     = output.secret_store_namespace == "my-operator"
    error_message = "Cluster-wide secret store should be in the custom Operator namespace"
  }
}

run "workload_identity_create_service_account_defaults" {
  command = apply

  variables {
    service_account_create = true
  }

  assert {
    condition = (
      google_service_account.operator[0].account_id == "humanitec-my-gcpsm-abcd" &&
      google_service_account.operator[0].display_name == "Humanitec Operator my-gcpsm" &&
      google_service_account.operator[0].project == "my-gsm-project"
    )
    error_message = "Google service account should be generated as humanitec-<secret_store_id>-<suffix> in the Secret Manager project, got ${google_service_account.operator[0].account_id}"
  }
  assert {
    condition     = random_string.service_account_name_suffix[0].length == 4
    error_message = "A random suffix of four characters should be generated for the Google service account"
  }
}

run "workload_identity_existing_service_account" {
  command = apply

  variables {
    service_account_email = "existing-sa@identity-project.iam.gserviceaccount.com"
  }

  assert {
    condition     = length(google_service_account.operator) == 0 && length(random_string.service_account_name_suffix) == 0
    error_message = "No Google service account should be created if service_account_email is set"
  }
  assert {
    condition     = data.google_service_account.operator[0].account_id == "projects/-/serviceAccounts/existing-sa@identity-project.iam.gserviceaccount.com"
    error_message = "Existing Google service account should be read by service_account_email"
  }
  assert {
    condition = (
      google_service_account_iam_member.workload_identity[0].service_account_id == "projects/identity-project/serviceAccounts/existing-sa@identity-project.iam.gserviceaccount.com" &&
      google_service_account_iam_member.workload_identity[0].member == "serviceAccount:my-gke-project.svc.id.goog[humanitec-operator-system/humanitec-operator-controller-manager]"
    )
    error_message = "Workload Identity binding should allow the Operator service account to impersonate the existing Google service account"
  }
  assert {
    condition     = google_project_iam_member.operator[0].member == "serviceAccount:existing-sa@identity-project.iam.gserviceaccount.com"
    error_message = "IAM role binding should be for the existing Google service account"
  }
  assert {
    condition = (
      output.service_account_email == "existing-sa@identity-project.iam.gserviceaccount.com" &&
      output.service_account_unique_id == "222222222222222222222" &&
      output.operator_iam_member == "serviceAccount:existing-sa@identity-project.iam.gserviceaccount.com"
    )
    error_message = "Google service account and Operator IAM member outputs should be those of the existing Google service account"
  }
  assert {
    condition     = output.operator_serviceaccount_annotations == tomap({ "iam.gke.io/gcp-service-account" = "existing-sa@identity-project.iam.gserviceaccount.com" })
    error_message = "Operator service account annotations output should contain the email of the existing Google service account"
  }
}

# Several secret stores sharing one existing Google service account.
# The Workload Identity binding and the Secret Manager access are managed outside of the module.

run "shared_service_account_without_bindings" {
  command = apply

  variables {
    secret_store_default             = false
    secret_store_cluster_wide        = false
    secret_store_namespace           = "my-app-development"
    gke_project_id                   = null
    service_account_email            = "existing-sa@identity-project.iam.gserviceaccount.com"
    workload_identity_binding_create = false
    secret_manager_access_create     = false
  }

  assert {
    condition = (
      length(google_service_account.operator) == 0 &&
      length(google_service_account_iam_member.workload_identity) == 0 &&
      length(google_project_iam_member.operator) == 0
    )
    error_message = "Neither a Google service account, a Workload Identity binding, nor an IAM role binding should be created"
  }
  assert {
    condition = (
      kubernetes_manifest.secret_store.manifest.metadata.namespace == "my-app-development" &&
      output.operator_iam_member == "serviceAccount:existing-sa@identity-project.iam.gserviceaccount.com"
    )
    error_message = "Secret store should still be created for the existing Google service account"
  }
  assert {
    condition = (
      output.workload_identity_member == "serviceAccount:my-provider-project.svc.id.goog[humanitec-operator-system/humanitec-operator-controller-manager]" &&
      output.workload_identity_binding_id == null &&
      output.secret_manager_iam_member_id == null
    )
    error_message = "Workload Identity member output should fall back to the provider project without gke_project_id, and binding ID outputs should be null"
  }
}

run "shared_service_account_without_bindings_or_any_gke_project" {
  command = apply

  variables {
    secret_store_default             = false
    gke_project_id                   = null
    service_account_email            = "existing-sa@identity-project.iam.gserviceaccount.com"
    workload_identity_binding_create = false
    secret_manager_access_create     = false
  }

  override_data {
    target = data.google_client_config.current
    values = {
      project = ""
    }
  }

  assert {
    condition     = output.workload_identity_member == null
    error_message = "Workload Identity member output should be null if neither gke_project_id nor a provider project is set"
  }
}

# Fallback of the project IDs to the project configured in the google provider

run "project_ids_fall_back_to_provider_project" {
  command = apply

  variables {
    secret_manager_project_id = null
    gke_project_id            = null
  }

  assert {
    condition = (
      kubernetes_manifest.secret_store.manifest.spec.gcpsm.projectID == "my-provider-project" &&
      output.secret_manager_project_id == "my-provider-project"
    )
    error_message = "Secret store should use the provider project if secret_manager_project_id is not set"
  }
  assert {
    condition = (
      google_project_iam_custom_role.secret_manager[0].project == "my-provider-project" &&
      google_project_iam_member.operator[0].project == "my-provider-project"
    )
    error_message = "Custom role and IAM role binding should be in the provider project if secret_manager_project_id is not set"
  }
  assert {
    condition = (
      data.google_project.gke[0].project_id == "my-provider-project" &&
      output.operator_iam_member == "principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/my-provider-project.svc.id.goog/subject/ns/humanitec-operator-system/sa/humanitec-operator-controller-manager"
    )
    error_message = "Workload Identity pool should be the one of the provider project if gke_project_id is not set"
  }
}

run "service_account_project_falls_back_to_provider_project" {
  command = apply

  variables {
    secret_manager_project_id = null
    service_account_create    = true
  }

  assert {
    condition     = google_service_account.operator[0].project == "my-provider-project"
    error_message = "Google service account should be created in the provider project if neither service_account_project_id nor secret_manager_project_id is set"
  }
  assert {
    condition     = output.workload_identity_member == "serviceAccount:my-gke-project.svc.id.goog[humanitec-operator-system/humanitec-operator-controller-manager]"
    error_message = "gke_project_id should take precedence over the provider project"
  }
}

run "service_account_key_ignores_provider_project_for_gke" {
  command = apply

  variables {
    auth_method    = "service_account_key"
    gke_project_id = null
  }

  assert {
    condition = (
      length(data.google_project.gke) == 0 &&
      output.workload_identity_member == null &&
      kubernetes_manifest.secret_store.manifest.spec.gcpsm.projectID == "my-gsm-project"
    )
    error_message = "The provider project should not be used as the GKE project with a service account key, and secret_manager_project_id should take precedence over it"
  }
}

run "create_service_account_without_workload_identity_binding" {
  command = apply

  # gke_project_id is still set from the file-level variables
  variables {
    service_account_create           = true
    workload_identity_binding_create = false
  }

  assert {
    condition     = length(google_service_account.operator) == 1 && length(google_service_account_iam_member.workload_identity) == 0
    error_message = "Google service account, but no Workload Identity binding should be created if workload_identity_binding_create is false"
  }
  assert {
    condition = (
      output.workload_identity_member == "serviceAccount:my-gke-project.svc.id.goog[humanitec-operator-system/humanitec-operator-controller-manager]" &&
      output.workload_identity_binding_id == null
    )
    error_message = "Workload Identity member output should provide the member to bind yourself if gke_project_id is set"
  }
}

# Service account key

run "complete_service_account_key_create_service_account" {
  command = apply

  variables {
    auth_method                             = "service_account_key"
    gke_project_id                          = null
    service_account_name                    = "my-operator-gsa"
    service_account_key_keepers             = { rotation = "2027-01-01" }
    service_account_credentials_secret_name = "my-credentials"
  }

  # Google service account and key
  assert {
    condition     = google_service_account.operator[0].account_id == "my-operator-gsa"
    error_message = "Google service account should be created by default with a service account key, using service_account_name"
  }
  assert {
    condition = (
      google_service_account_key.operator[0].service_account_id == "projects/my-gsm-project/serviceAccounts/created-sa@my-gsm-project.iam.gserviceaccount.com" &&
      google_service_account_key.operator[0].keepers == tomap({ rotation = "2027-01-01" })
    )
    error_message = "Service account key should be created for the new Google service account with service_account_key_keepers"
  }

  # Secret Manager access
  assert {
    condition     = google_project_iam_member.operator[0].member == "serviceAccount:created-sa@my-gsm-project.iam.gserviceaccount.com"
    error_message = "IAM role binding should be for the new Google service account"
  }

  # No Workload Identity
  assert {
    condition = (
      length(data.google_project.gke) == 0 &&
      length(data.google_service_account.operator) == 0 &&
      length(google_service_account_iam_member.workload_identity) == 0
    )
    error_message = "Neither the GKE project, an existing Google service account, nor a Workload Identity binding should be used with a service account key"
  }

  # Credentials Secret
  assert {
    condition = (
      kubernetes_secret_v1.operator_credentials[0].metadata[0].name == "my-credentials" &&
      kubernetes_secret_v1.operator_credentials[0].metadata[0].namespace == "humanitec-operator-system"
    )
    error_message = "Credentials Secret should be named service_account_credentials_secret_name and be in the namespace of the secret store"
  }
  assert {
    condition     = kubernetes_secret_v1.operator_credentials[0].data_wo_revision == 1
    error_message = "Credentials Secret should set data_wo_revision so that the provider writes data_wo and does not read the created key back into the state"
  }
  assert {
    condition     = kubernetes_secret_v1.operator_credentials[0].data_wo == null
    error_message = "Credentials Secret should not store the created key in the state via data_wo"
  }
  assert {
    condition = terraform_data.service_account_key_version[0].output == {
      service_account_email = "created-sa@my-gsm-project.iam.gserviceaccount.com"
      key_version           = "projects/my-gsm-project/serviceAccounts/created-sa@my-gsm-project.iam.gserviceaccount.com/keys/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    }
    error_message = "Google service account and ID of the created key should be tracked to replace the credentials Secret on change"
  }

  # Secret store
  assert {
    condition = kubernetes_manifest.secret_store.manifest.spec.gcpsm.auth == {
      secretAccessKeySecretRef = { name = "my-credentials", key = "secret-access-credentials" }
    }
    error_message = "Secret store should reference the key in the credentials Secret, as an object"
  }
  assert {
    condition     = terraform_data.secret_store_replacement_triggers.output.auth_method == "service_account_key"
    error_message = "Auth method should be tracked, so that changing it replaces the secret store"
  }

  # Outputs
  assert {
    condition = (
      output.service_account_email == "created-sa@my-gsm-project.iam.gserviceaccount.com" &&
      output.operator_iam_member == "serviceAccount:created-sa@my-gsm-project.iam.gserviceaccount.com"
    )
    error_message = "Google service account and Operator IAM member outputs should be those of the new Google service account"
  }
  assert {
    condition     = output.service_account_credentials_secret_name == "my-credentials"
    error_message = "Credentials Secret name output should be service_account_credentials_secret_name"
  }
  assert {
    condition = (
      output.workload_identity_member == null &&
      output.workload_identity_binding_id == null &&
      length(output.operator_serviceaccount_annotations) == 0
    )
    error_message = "Workload Identity outputs should be null or empty with a service account key"
  }
}

run "complete_service_account_key_existing_service_account" {
  command = apply

  variables {
    auth_method                 = "service_account_key"
    gke_project_id              = null
    service_account_create      = false
    service_account_email       = "existing-sa@identity-project.iam.gserviceaccount.com"
    service_account_key         = "{\"type\":\"service_account\",\"private_key\":\"existing-private-key\"}"
    service_account_key_version = 2
  }

  # Google service account and key
  assert {
    condition = (
      length(google_service_account.operator) == 0 &&
      length(google_service_account_key.operator) == 0
    )
    error_message = "Neither a Google service account nor a key should be created if service_account_create is false"
  }
  assert {
    condition     = data.google_service_account.operator[0].account_id == "projects/-/serviceAccounts/existing-sa@identity-project.iam.gserviceaccount.com"
    error_message = "Existing Google service account should be read by service_account_email"
  }
  assert {
    condition     = google_project_iam_member.operator[0].member == "serviceAccount:existing-sa@identity-project.iam.gserviceaccount.com"
    error_message = "IAM role binding should be for the existing Google service account"
  }

  # Credentials Secret
  assert {
    condition     = kubernetes_secret_v1.operator_credentials[0].metadata[0].name == "my-gcpsm-credentials"
    error_message = "Credentials Secret name should be generated as <secret_store_id>-credentials"
  }
  assert {
    condition     = kubernetes_secret_v1.operator_credentials[0].data_wo_revision == 1
    error_message = "Credentials Secret should set data_wo_revision so that the provider writes data_wo and does not read the key passed in back into the state"
  }
  assert {
    condition     = kubernetes_secret_v1.operator_credentials[0].data_wo == null
    error_message = "Credentials Secret should not store the key passed in in the state via data_wo"
  }
  assert {
    condition = terraform_data.service_account_key_version[0].output == {
      service_account_email = "existing-sa@identity-project.iam.gserviceaccount.com"
      key_version           = "2"
    }
    error_message = "Google service account and service_account_key_version should be tracked to replace the credentials Secret on change"
  }

  # Outputs
  assert {
    condition = (
      output.service_account_email == "existing-sa@identity-project.iam.gserviceaccount.com" &&
      output.service_account_id == "projects/identity-project/serviceAccounts/existing-sa@identity-project.iam.gserviceaccount.com" &&
      output.operator_iam_member == "serviceAccount:existing-sa@identity-project.iam.gserviceaccount.com"
    )
    error_message = "Google service account and Operator IAM member outputs should be those of the existing Google service account"
  }
  assert {
    condition     = length(output.operator_serviceaccount_annotations) == 0
    error_message = "Operator service account annotations output should be empty with a service account key"
  }
}

run "existing_service_account_key_without_version" {
  command = apply

  variables {
    auth_method            = "service_account_key"
    gke_project_id         = null
    service_account_create = false
    service_account_email  = "existing-sa@identity-project.iam.gserviceaccount.com"
    service_account_key    = "{\"type\":\"service_account\",\"private_key\":\"existing-private-key\"}"
  }

  assert {
    condition     = terraform_data.service_account_key_version[0].output.key_version == "0"
    error_message = "Key version should default to 0 if service_account_key_version is not set"
  }
}

run "environment_local_store_with_service_account_key" {
  command = apply

  variables {
    auth_method               = "service_account_key"
    gke_project_id            = null
    secret_store_default      = false
    secret_store_cluster_wide = false
    secret_store_namespace    = "my-app-development"
  }

  assert {
    condition     = kubernetes_secret_v1.operator_credentials[0].metadata[0].namespace == "my-app-development"
    error_message = "Credentials Secret should be in the namespace of the Environment-local secret store"
  }
  assert {
    condition     = google_service_account.operator[0].account_id == "humanitec-my-gcpsm-abcd"
    error_message = "Google service account should be generated as humanitec-<secret_store_id>-<suffix>, got ${google_service_account.operator[0].account_id}"
  }
  assert {
    condition     = google_project_iam_member.operator[0].role == "roles/secretmanager.secretAccessor"
    error_message = "IAM role binding should only grant read access for an Environment-local store"
  }
}

# Edge cases

run "generated_service_account_name_is_truncated" {
  command = apply

  variables {
    secret_store_id        = "my-very-long-secret-store-id"
    service_account_create = true
  }

  assert {
    condition     = google_service_account.operator[0].account_id == "humanitec-my-very-long-se-abcd"
    error_message = "Generated Google service account ID should contain at most 15 characters of the secret store ID, got ${google_service_account.operator[0].account_id}"
  }
  assert {
    condition     = length(google_service_account.operator[0].account_id) <= 30
    error_message = "Generated Google service account ID should be at most 30 characters long"
  }
}

run "generated_service_account_name_trims_hyphens" {
  command = apply

  variables {
    secret_store_id        = "abcdefghijklm--secret-store"
    service_account_create = true
  }

  assert {
    condition     = google_service_account.operator[0].account_id == "humanitec-abcdefghijklm-abcd"
    error_message = "Generated Google service account ID should not contain trailing hyphens of the truncated secret store ID, got ${google_service_account.operator[0].account_id}"
  }
}

run "generated_custom_role_id_is_truncated" {
  command = apply

  variables {
    # The 40th character is a hyphen
    secret_store_id = "abcdefghij-abcdefghij-abcdefghij-abcdef--secret-store-id"
  }

  assert {
    condition     = google_project_iam_custom_role.secret_manager[0].role_id == "humanitec_operator_abcdefghij_abcdefghij_abcdefghij_abcdef_abcd"
    error_message = "Generated custom role ID should contain at most 40 characters of the secret store ID, without trailing hyphens and with underscores instead of hyphens, got ${google_project_iam_custom_role.secret_manager[0].role_id}"
  }
  assert {
    condition     = can(regex("^[a-zA-Z0-9_.]{3,64}$", google_project_iam_custom_role.secret_manager[0].role_id))
    error_message = "Generated custom role ID should be a valid role ID"
  }
}

run "domain_scoped_gke_project" {
  command = apply

  variables {
    gke_project_id = "example.com:my-gke-project"
  }

  assert {
    condition     = google_project_iam_member.operator[0].member == "principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/example.com:my-gke-project.svc.id.goog/subject/ns/humanitec-operator-system/sa/humanitec-operator-controller-manager"
    error_message = "IAM role binding should be for the principal in the Workload Identity pool of a domain-scoped project"
  }
}

# Validation failures

run "rejects_invalid_secret_store_id" {
  command = plan

  variables {
    secret_store_id = "My_Store"
  }

  expect_failures = [var.secret_store_id]
}

run "rejects_invalid_auth_method" {
  command = plan

  variables {
    auth_method = "access_token"
  }

  expect_failures = [var.auth_method]
}

run "default_store_must_be_cluster_wide" {
  command = plan

  # secret_store_default is true by default
  variables {
    secret_store_cluster_wide = false
    secret_store_namespace    = "my-app-development"
  }

  expect_failures = [var.secret_store_default]
}

run "environment_local_store_requires_namespace" {
  command = plan

  variables {
    secret_store_default      = false
    secret_store_cluster_wide = false
  }

  expect_failures = [var.secret_store_namespace]
}

run "cluster_wide_store_rejects_namespace" {
  command = plan

  variables {
    secret_store_namespace = "my-app-development"
  }

  expect_failures = [var.secret_store_namespace]
}

run "rejects_invalid_secret_manager_project_id" {
  command = plan

  variables {
    secret_manager_project_id = "My Project"
  }

  expect_failures = [var.secret_manager_project_id]
}

run "rejects_invalid_secret_manager_location" {
  command = plan

  variables {
    secret_manager_location = "global"
  }

  expect_failures = [var.secret_manager_location]
}

run "rejects_invalid_secret_manager_role" {
  command = plan

  variables {
    secret_manager_role = "secretmanager.admin"
  }

  expect_failures = [var.secret_manager_role]
}

run "passed_in_role_requires_secret_manager_role" {
  command = plan

  variables {
    secret_manager_role_create = false
  }

  expect_failures = [var.secret_manager_role_create]
}

run "custom_role_rejects_secret_manager_role" {
  command = plan

  variables {
    secret_manager_role_create = true
    secret_manager_role        = "roles/secretmanager.admin"
  }

  expect_failures = [var.secret_manager_role_create]
}

run "custom_role_requires_default_store" {
  command = plan

  variables {
    secret_store_default       = false
    secret_manager_role_create = true
  }

  expect_failures = [var.secret_manager_role_create]
}

run "existing_service_account_requires_email_with_workload_identity" {
  command = plan

  variables {
    service_account_create = false
  }

  expect_failures = [var.service_account_email]
}

run "requires_secret_manager_project_id_without_provider_project" {
  command = plan

  variables {
    secret_manager_project_id = null
  }

  override_data {
    target = data.google_client_config.current
    values = {
      project = ""
    }
  }

  expect_failures = [data.google_client_config.current]
}

run "workload_identity_federation_requires_gke_project_id_without_provider_project" {
  command = plan

  variables {
    gke_project_id = null
  }

  override_data {
    target = data.google_client_config.current
    values = {
      project = ""
    }
  }

  expect_failures = [data.google_client_config.current]
}

run "workload_identity_binding_requires_gke_project_id_without_provider_project" {
  command = plan

  variables {
    gke_project_id        = null
    service_account_email = "existing-sa@identity-project.iam.gserviceaccount.com"
  }

  override_data {
    target = data.google_client_config.current
    values = {
      project = ""
    }
  }

  expect_failures = [data.google_client_config.current]
}

run "rejects_invalid_gke_project_id" {
  command = plan

  variables {
    gke_project_id = "my_gke_project"
  }

  expect_failures = [var.gke_project_id]
}

run "service_account_key_rejects_gke_project_id" {
  command = plan

  # gke_project_id is still set from the file-level variables
  variables {
    auth_method = "service_account_key"
  }

  expect_failures = [var.gke_project_id]
}

run "create_service_account_rejects_service_account_email" {
  command = plan

  variables {
    service_account_create = true
    service_account_email  = "existing-sa@identity-project.iam.gserviceaccount.com"
  }

  expect_failures = [var.service_account_email]
}

run "service_account_key_creates_service_account_by_default_and_rejects_service_account_email" {
  command = plan

  variables {
    auth_method           = "service_account_key"
    gke_project_id        = null
    service_account_email = "existing-sa@identity-project.iam.gserviceaccount.com"
  }

  expect_failures = [var.service_account_email]
}

run "rejects_invalid_service_account_email" {
  command = plan

  variables {
    service_account_email = "existing-sa"
  }

  expect_failures = [var.service_account_email]
}

run "rejects_invalid_service_account_name" {
  command = plan

  variables {
    service_account_create = true
    service_account_name   = "gsa"
  }

  expect_failures = [var.service_account_name]
}

run "rejects_too_long_service_account_display_name" {
  command = plan

  variables {
    service_account_create       = true
    service_account_display_name = "Humanitec Operator access to the Google Cloud Secret Manager secret store my-gcpsm in the project my-gsm-project"
  }

  expect_failures = [var.service_account_display_name]
}

run "workload_identity_federation_rejects_service_account_settings" {
  command = plan

  variables {
    service_account_name         = "my-operator-gsa"
    service_account_display_name = "My Operator"
    service_account_project_id   = "my-identity-project"
  }

  expect_failures = [
    var.service_account_name,
    var.service_account_display_name,
    var.service_account_project_id,
  ]
}

run "existing_service_account_rejects_service_account_settings" {
  command = plan

  variables {
    service_account_email        = "existing-sa@identity-project.iam.gserviceaccount.com"
    service_account_name         = "my-operator-gsa"
    service_account_display_name = "My Operator"
    service_account_project_id   = "my-identity-project"
  }

  expect_failures = [
    var.service_account_name,
    var.service_account_display_name,
    var.service_account_project_id,
  ]
}

run "workload_identity_rejects_service_account_key_settings" {
  command = plan

  variables {
    service_account_create                  = true
    service_account_key_keepers             = { rotation = "2027-01-01" }
    service_account_key                     = "{\"type\":\"service_account\",\"private_key\":\"existing-private-key\"}"
    service_account_key_version             = 2
    service_account_credentials_secret_name = "my-credentials"
  }

  expect_failures = [
    var.service_account_key_keepers,
    var.service_account_key,
    var.service_account_key_version,
    var.service_account_credentials_secret_name,
  ]
}

run "create_service_account_key_rejects_existing_service_account_key_settings" {
  command = plan

  variables {
    auth_method                 = "service_account_key"
    gke_project_id              = null
    service_account_key         = "{\"type\":\"service_account\",\"private_key\":\"existing-private-key\"}"
    service_account_key_version = 2
  }

  expect_failures = [
    var.service_account_key,
    var.service_account_key_version,
  ]
}

run "existing_service_account_key_requires_email_and_key" {
  command = plan

  variables {
    auth_method            = "service_account_key"
    gke_project_id         = null
    service_account_create = false
  }

  expect_failures = [
    var.service_account_email,
    var.service_account_key,
  ]
}

run "existing_service_account_key_rejects_key_keepers" {
  command = plan

  variables {
    auth_method                 = "service_account_key"
    gke_project_id              = null
    service_account_create      = false
    service_account_email       = "existing-sa@identity-project.iam.gserviceaccount.com"
    service_account_key         = "{\"type\":\"service_account\",\"private_key\":\"existing-private-key\"}"
    service_account_key_keepers = { rotation = "2027-01-01" }
  }

  expect_failures = [var.service_account_key_keepers]
}

run "existing_service_account_key_rejects_invalid_key" {
  command = plan

  variables {
    auth_method            = "service_account_key"
    gke_project_id         = null
    service_account_create = false
    service_account_email  = "existing-sa@identity-project.iam.gserviceaccount.com"
    # A base64-encoded key file
    service_account_key = "eyJ0eXBlIjoic2VydmljZV9hY2NvdW50IiwicHJpdmF0ZV9rZXkiOiJjcmVhdGVkLXByaXZhdGUta2V5In0="
  }

  expect_failures = [var.service_account_key]
}
