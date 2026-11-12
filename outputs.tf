output "secret_store_id" {
  description = "ID of the secret store, i.e. the name of the Kubernetes `SecretStore` resource. This is either `secret_store_id` or the generated ID. Use it as the `store` in secret references."
  value       = local.secret_store_id
  # Consumers of the ID should wait for the SecretStore, once it can be created
  depends_on = [kubernetes_manifest.secret_store]
}
output "secret_store_namespace" {
  description = "Name of the Kubernetes namespace of the `SecretStore` resource. This is the Operator namespace for a cluster-wide store, or the Environment namespace for an Environment-local store."
  value       = local.secret_store_namespace
  depends_on  = [kubernetes_manifest.secret_store]
}
output "secret_store_ready" {
  description = "Whether the module manages the `SecretStore` resource. This is `false` if the `SecretStore` CRD was not present on the cluster during planning. In that case, apply the configuration again once the Operator is installed. See [Installation order](#installation-order)."
  value       = local.secret_store_crd_ready
}
output "secret_manager_project_id" {
  description = "ID of the Google Cloud project of the Secret Manager, used as the `projectID` of the secret store. This is either `secret_manager_project_id` or the project configured in the `google` provider."
  value       = local.secret_manager_project_id
}
output "secret_manager_location" {
  description = "Location of the regional Secret Manager, used as the `locationID` of the secret store. Returns `null` for the global Secret Manager."
  value       = var.secret_manager_location
}
output "secret_manager_role" {
  description = "IAM role granted to the Operator identity on the Secret Manager project: `secret_manager_role` if set, otherwise the name of the least-privilege custom role created by the module for the default store, e.g. `projects/my-gsm-project/roles/humanitec_operator_gcpsm_kxqp`, and `roles/secretmanager.secretAccessor` for any other store. Returns `null` for the default store if neither `secret_manager_role` is set nor `secret_manager_access_create` is `true`."
  value       = local.secret_manager_role
}
output "secret_manager_permissions" {
  description = "Permissions the Operator identity needs on the Secret Manager project: read/write permissions for the default store, and `secretmanager.versions.access` for any other store. The custom role created by the module for the default store has exactly these permissions. If you pass in a role or grant the access yourself, ensure the role has them."
  value       = local.secret_manager_permissions
}
output "secret_manager_custom_role_id" {
  description = "ID of the least-privilege custom role created by the module for the default store, i.e. `projects/<project>/roles/<role_id>`. Returns `null` if the module does not create it."
  value       = one(google_project_iam_custom_role.secret_manager[*].id)
}
output "secret_manager_iam_member_id" {
  description = "ID of the IAM role binding granting the Operator access to the Secret Manager project. Returns `null` if `secret_manager_access_create` is `false`."
  value       = one(google_project_iam_member.operator[*].id)
}
output "operator_iam_member" {
  description = "IAM member of the identity the Operator uses, e.g. to grant it access to further Google Cloud resources. This is `serviceAccount:<email>` if the Operator uses a Google service account, or the `principal://` identifier of the Operator service account if it uses Workload Identity Federation for GKE directly."
  value       = local.operator_iam_member
}
output "service_account_email" {
  description = "Email address of the Google service account used by the Operator. Returns `null` if the Operator does not use a Google service account."
  value       = local.service_account_email
}
output "service_account_id" {
  description = "Fully qualified ID of the Google service account used by the Operator, i.e. `projects/<project>/serviceAccounts/<email>`. Returns `null` if the Operator does not use a Google service account."
  value       = local.service_account_id
}
output "service_account_unique_id" {
  description = "Unique numeric ID of the Google service account used by the Operator. Returns `null` if the Operator does not use a Google service account."
  value       = local.service_account_unique_id
}
output "workload_identity_member" {
  description = "IAM member of the Operator service account in the Workload Identity pool of the GKE cluster, i.e. `serviceAccount:<gke_project_id>.svc.id.goog[<operator_namespace>/<operator_serviceaccount>]`, with `gke_project_id` falling back to the project configured in the `google` provider. If `workload_identity_binding_create` is `false`, grant it the role `roles/iam.workloadIdentityUser` on the Google service account yourself. Returns `null` if `auth_method` is not `workload_identity`, the Operator does not impersonate a Google service account, or neither `gke_project_id` nor a provider project is set."
  value       = local.workload_identity_member
}
output "workload_identity_binding_id" {
  description = "ID of the IAM role binding allowing the Operator service account to impersonate the Google service account. Returns `null` if the module does not create it."
  value       = one(google_service_account_iam_member.workload_identity[*].id)
}
output "operator_serviceaccount_annotations" {
  description = "Annotations to set on the Operator service account so that it impersonates the Google service account via Workload Identity, e.g. via the `controllerManager.serviceAccount.annotations` value of the Operator Helm chart. Restart the Operator after changing them. Returns an empty map if `auth_method` is not `workload_identity` or the Operator does not impersonate a Google service account."
  value       = local.use_workload_identity_service_account ? tomap({ "iam.gke.io/gcp-service-account" = local.service_account_email }) : tomap({})
}
output "service_account_credentials_secret_name" {
  description = "Name of the Kubernetes Secret holding the key of the Google service account, located in the `secret_store_namespace`. Returns `null` if `auth_method` is not `service_account_key`."
  value       = one(kubernetes_secret_v1.operator_credentials[*].metadata[0].name)
}
