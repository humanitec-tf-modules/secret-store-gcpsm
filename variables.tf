# Secret store

variable "secret_store_id" {
  description = "ID of the secret store. It is the name of the Kubernetes `SecretStore` resource and the `store` value used in secret references. If you also register the secret store with the Platform Orchestrator, use the same ID there. If not set, the module generates an ID in the pattern `gcpsm-<random>`, with `<random>` being a random string of four lowercase letters, e.g. `gcpsm-kxqp`. Use the `secret_store_id` output to read it."
  type        = string
  nullable    = true
  default     = null

  validation {
    condition     = var.secret_store_id == null || (can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.secret_store_id)) && length(coalesce(var.secret_store_id, "-")) <= 63)
    error_message = "secret_store_id must consist of lowercase alphanumeric characters or '-', start and end with an alphanumeric character, and be at most 63 characters long"
  }
}
variable "secret_store_cluster_wide" {
  description = "Whether the secret store is cluster-wide, i.e. usable by all Deployments onto the cluster. A cluster-wide store is created in the `operator_namespace`. If `false`, the store is Environment-local and created in `secret_store_namespace`, so it can only be used by Deployments into that namespace."
  type        = bool
  nullable    = false
  default     = true
}
variable "secret_store_namespace" {
  description = "Name of the Kubernetes namespace of the Environment for an Environment-local secret store. Required if `secret_store_cluster_wide` is `false`, must not be set otherwise. The namespace must exist."
  type        = string
  nullable    = true
  default     = null

  validation {
    condition     = var.secret_store_cluster_wide ? var.secret_store_namespace == null : var.secret_store_namespace != null
    error_message = "secret_store_namespace must be set if secret_store_cluster_wide is false, and must not be set otherwise"
  }
}
variable "secret_store_default" {
  description = "Whether the secret store is the default secret store of the Operator. Only a cluster-wide secret store can be the default store, so set it to `false` for an Environment-local store. The Operator gets read/write access to the default store, and read-only access to any other store."
  type        = bool
  nullable    = false
  default     = true

  validation {
    condition     = !var.secret_store_default || var.secret_store_cluster_wide
    error_message = "secret_store_default can only be true if secret_store_cluster_wide is true. An Environment-local secret store cannot be the default store, so set secret_store_default to false"
  }
}

# Secret Manager

variable "secret_manager_project_id" {
  description = "ID of the Google Cloud project whose Secret Manager is used as the secret store, e.g. `my-gsm-project`. The Secret Manager API must be enabled in the project. This may be the project of the GKE cluster hosting the Operator, or a different one. If not set, the project configured in the `google` provider is used. Required if the provider has no project configured."
  type        = string
  nullable    = true
  default     = null

  validation {
    condition     = var.secret_manager_project_id == null || can(regex(local.project_id_pattern, var.secret_manager_project_id))
    error_message = "secret_manager_project_id must be a Google Cloud project ID, e.g. my-gsm-project"
  }
}
variable "secret_manager_location" {
  description = "Location of a regional Secret Manager, e.g. `europe-west3`. Leave it unset to use the global Secret Manager. Changing it replaces the `SecretStore` resource."
  type        = string
  nullable    = true
  default     = null

  validation {
    condition     = var.secret_manager_location == null || can(regex("^[a-z]+-[a-z]+[0-9]+$", var.secret_manager_location))
    error_message = "secret_manager_location must be a Google Cloud region, e.g. europe-west3"
  }
}
variable "secret_manager_access_create" {
  description = "Whether to grant the Operator identity access to the Secret Manager, via an IAM role binding on its project. Set it to `false` if the identity already has access, e.g. if several secret stores share one identity and one Secret Manager project: the bindings are non-authoritative, so if several module instances manage the same binding, destroying one instance revokes the access of the others. Grant the access yourself in that case, using the `operator_iam_member` output and a role with the permissions of the `secret_manager_permissions` output. The module then creates no custom role for the default store either."
  type        = bool
  nullable    = false
  default     = true
}
variable "secret_manager_role" {
  description = "IAM role granted to the Operator identity on the Secret Manager project, e.g. a custom role like `projects/my-gsm-project/roles/secretmanager.readwrite` or a built-in role like `roles/secretmanager.admin`. If not set, the module creates a least-privilege custom role for the default store, and uses the built-in role `roles/secretmanager.secretAccessor` otherwise. For the default store, also set `secret_manager_role_create` to `false` if the role is only known after apply. See the `secret_manager_permissions` output for the permissions the role needs. The module only creates the custom role if `secret_manager_access_create` is `true`."
  type        = string
  nullable    = true
  default     = null

  validation {
    condition     = var.secret_manager_role == null || can(regex("^(roles|projects/[^/]+/roles|organizations/[0-9]+/roles)/[a-zA-Z0-9_.]+$", var.secret_manager_role))
    error_message = "secret_manager_role must be an IAM role name like roles/secretmanager.secretAccessor, projects/my-project/roles/my-role, or organizations/123456789012/roles/my-role"
  }
}
variable "secret_manager_role_create" {
  description = "Whether to create a least-privilege custom role for the default store and grant it to the Operator identity. Set it to `false` to grant the `secret_manager_role` passed in instead. If not set, the module creates the custom role unless `secret_manager_role` is set. Set it explicitly to `false` if `secret_manager_role` is only known after apply, e.g. because it refers to a `google_project_iam_custom_role` in the same configuration: the module can only plan the custom role if it knows whether to create it. Only used for the default store if `secret_manager_access_create` is `true`."
  type        = bool
  nullable    = true
  default     = null

  validation {
    condition     = var.secret_manager_role_create != true || (var.secret_store_default && var.secret_manager_access_create && var.secret_manager_role == null)
    error_message = "secret_manager_role_create can only be true for the default store, if secret_manager_access_create is true and secret_manager_role is not set"
  }

  validation {
    condition     = var.secret_manager_role_create != false || !(var.secret_store_default && var.secret_manager_access_create) || var.secret_manager_role != null
    error_message = "secret_manager_role must be set if secret_manager_role_create is false for the default store"
  }
}

# Operator

variable "operator_namespace" {
  description = "Name of the Kubernetes namespace of the Humanitec Operator."
  type        = string
  nullable    = false
  default     = "humanitec-operator-system"
}
variable "operator_serviceaccount" {
  description = "Name of the Kubernetes service account of the Humanitec Operator. Used to identify the Operator via Workload Identity Federation for GKE if `auth_method` is `workload_identity`."
  type        = string
  nullable    = false
  default     = "humanitec-operator-controller-manager"
}
variable "auth_method" {
  description = "How the Operator authenticates against Google Cloud Secret Manager. `workload_identity` (recommended): the Operator uses its Kubernetes service account via Workload Identity Federation for GKE, either directly or by impersonating a Google service account. `service_account_key`: the Operator uses a key of a Google service account, stored in a Kubernetes Secret."
  type        = string
  nullable    = false
  default     = "workload_identity"

  validation {
    condition     = contains(["workload_identity", "service_account_key"], var.auth_method)
    error_message = "auth_method must be one of: workload_identity, service_account_key"
  }
}
variable "gke_project_id" {
  description = "ID of the Google Cloud project of the GKE cluster hosting the Operator. Its Workload Identity pool `<gke_project_id>.svc.id.goog` identifies the Operator service account. The cluster and the node pool running the Operator must have Workload Identity Federation for GKE enabled. If not set and `auth_method` is `workload_identity`, the project configured in the `google` provider is used. Required if `auth_method` is `workload_identity` and the provider has no project configured, unless the Operator impersonates a Google service account and `workload_identity_binding_create` is `false`. Must not be set if `auth_method` is `service_account_key`."
  type        = string
  nullable    = true
  default     = null

  validation {
    condition     = var.auth_method != "service_account_key" || var.gke_project_id == null
    error_message = "gke_project_id must not be set if auth_method is service_account_key"
  }

  validation {
    condition     = var.gke_project_id == null || can(regex(local.project_id_pattern, var.gke_project_id))
    error_message = "gke_project_id must be a Google Cloud project ID, e.g. my-gke-project"
  }
}

# Google service account

variable "service_account_create" {
  description = "Whether to create a Google service account for the Operator. If not set, the module creates one if `auth_method` is `service_account_key`, and none if `auth_method` is `workload_identity`. With `workload_identity`, the Operator service account impersonates the Google service account if the module creates one or `service_account_email` is set, and uses Workload Identity Federation for GKE directly otherwise. Set it to `false` to use an existing service account passed in via `service_account_email`, and, with `service_account_key`, its key passed in via `service_account_key`. With `workload_identity`, you can omit it if `service_account_email` is a literal value, but set it explicitly to `false` if `service_account_email` is only known after apply, e.g. because it refers to a `google_service_account` in the same configuration: the module can only plan its resources if it knows whether the Operator uses a Google service account."
  type        = bool
  nullable    = true
  default     = null
}
variable "service_account_name" {
  description = "Account ID of the Google service account to create for the Operator, i.e. the part of its email address before the `@`. Must be 6 to 30 characters long. Only used if the module creates the service account. If not set, the module generates an account ID from the secret store ID and a random four-letter suffix."
  type        = string
  nullable    = true
  default     = null

  validation {
    condition     = var.service_account_name == null || local.service_account_create
    error_message = "service_account_name must only be set if the module creates the Google service account. Use service_account_email to pass in an existing service account"
  }

  validation {
    condition     = var.service_account_name == null || can(regex("^[a-z][-a-z0-9]{4,28}[a-z0-9]$", var.service_account_name))
    error_message = "service_account_name must be 6 to 30 characters long, consist of lowercase letters, digits, or '-', start with a letter, and end with a letter or digit"
  }
}
variable "service_account_display_name" {
  description = "Display name of the Google service account to create for the Operator. Only used if the module creates the service account. If not set, the display name is `Humanitec Operator <secret store ID>`."
  type        = string
  nullable    = true
  default     = null

  validation {
    condition     = var.service_account_display_name == null || local.service_account_create
    error_message = "service_account_display_name must only be set if the module creates the Google service account"
  }

  validation {
    condition     = length(coalesce(var.service_account_display_name, "-")) <= 100
    error_message = "service_account_display_name must be at most 100 characters long"
  }
}
variable "service_account_project_id" {
  description = "ID of the Google Cloud project in which to create the Google service account for the Operator. If not set, the project of the Secret Manager is used, i.e. `secret_manager_project_id` or its fallback. Only used if the module creates the service account."
  type        = string
  nullable    = true
  default     = null

  validation {
    condition     = var.service_account_project_id == null || local.service_account_create
    error_message = "service_account_project_id must only be set if the module creates the Google service account"
  }

  validation {
    condition     = var.service_account_project_id == null || can(regex(local.project_id_pattern, var.service_account_project_id))
    error_message = "service_account_project_id must be a Google Cloud project ID, e.g. my-project"
  }
}
variable "service_account_email" {
  description = "Email address of an existing Google service account to be used by the Operator, e.g. `humanitec-operator@my-project.iam.gserviceaccount.com`. Required if `service_account_create` is `false`. With `workload_identity`, the Operator service account impersonates this service account. Must not be set if the module creates the service account."
  type        = string
  nullable    = true
  default     = null

  validation {
    condition     = var.service_account_create != false || var.service_account_email != null
    error_message = "service_account_email must be set if service_account_create is false"
  }

  validation {
    condition     = !local.service_account_create || var.service_account_email == null
    error_message = "service_account_email must not be set if the module creates the Google service account. Set service_account_create to false to use an existing service account"
  }

  validation {
    condition     = var.service_account_email == null || can(regex("^[^@\\s]+@[^@\\s]+\\.gserviceaccount\\.com$", var.service_account_email))
    error_message = "service_account_email must be the email address of a Google service account, e.g. humanitec-operator@my-project.iam.gserviceaccount.com"
  }
}
variable "workload_identity_binding_create" {
  description = "Whether to allow the Operator service account to impersonate the Google service account, by granting it the role `roles/iam.workloadIdentityUser` on the service account. Only used if `auth_method` is `workload_identity` and the Operator impersonates a Google service account. Set it to `false` if the binding already exists, e.g. because another instance of the module manages it for the same Google service account. Use the `workload_identity_member` output to create it yourself."
  type        = bool
  nullable    = false
  default     = true
}

# Service account key (auth_method = "service_account_key")

variable "service_account_key_keepers" {
  description = "Arbitrary map of values that, when changed, replace the key of the Google service account created for the Operator, e.g. the `id` of a `time_rotating` resource to rotate the key regularly. The module updates the Kubernetes Secret accordingly. Only used if `auth_method` is `service_account_key` and the module creates the service account."
  type        = map(string)
  nullable    = true
  default     = null

  validation {
    condition     = var.service_account_key_keepers == null || (local.use_service_account_key && local.service_account_create)
    error_message = "service_account_key_keepers must only be set if auth_method is service_account_key and the module creates the Google service account"
  }
}
# Not nullable with an empty string meaning "not set": Terraform tests cannot run an apply
# with an ephemeral variable that is null.
variable "service_account_key" {
  description = "Key of the existing Google service account passed in via `service_account_email`, i.e. the content of its JSON key file. Required if `auth_method` is `service_account_key` and `service_account_create` is `false`, must be empty otherwise. The variable is ephemeral, so the value can come from an ephemeral source. It is not stored in the state or plan, as the module only writes it to a write-only attribute of the Kubernetes Secret. The Kubernetes Secret is only updated if `service_account_email` or `service_account_key_version` changes as well."
  type        = string
  nullable    = false
  sensitive   = true
  ephemeral   = true
  default     = ""

  validation {
    condition     = (local.use_service_account_key && !local.service_account_create) == (var.service_account_key != "")
    error_message = "service_account_key must be set if auth_method is service_account_key and service_account_create is false, and must be empty otherwise"
  }

  validation {
    condition     = var.service_account_key == "" || can(jsondecode(var.service_account_key).private_key)
    error_message = "service_account_key must be the JSON key file of a Google service account, not base64-encoded"
  }
}
variable "service_account_key_version" {
  description = "Version of the key passed in via `service_account_key`. The module keeps it in the state to detect changes of the write-only key. Increase it whenever you pass in a new key, e.g. when rotating it, to make the module replace the Kubernetes Secret holding the key. Only used if `auth_method` is `service_account_key` and `service_account_create` is `false`."
  type        = number
  nullable    = true
  default     = null

  validation {
    condition     = var.service_account_key_version == null || (local.use_service_account_key && !local.service_account_create)
    error_message = "service_account_key_version must only be set if auth_method is service_account_key and service_account_create is false"
  }
}
variable "service_account_credentials_secret_name" {
  description = "Name of the Kubernetes Secret holding the key of the Google service account. It is created in the namespace of the secret store. The key is written to the Secret via a write-only attribute, so the Secret does not add it to the state. Only used if `auth_method` is `service_account_key`. If not set, the name is `<secret store ID>-credentials`."
  type        = string
  nullable    = true
  default     = null

  validation {
    condition     = var.service_account_credentials_secret_name == null || var.auth_method == "service_account_key"
    error_message = "service_account_credentials_secret_name must only be set if auth_method is service_account_key"
  }
}
