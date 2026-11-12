# Random suffix for the fallback ID of the secret store
resource "random_string" "secret_store_id_suffix" {
  count   = var.secret_store_id == null ? 1 : 0
  length  = 4
  upper   = false
  numeric = false
  special = false
}

# Random suffix for the fallback account ID of the Google service account
resource "random_string" "service_account_name_suffix" {
  count   = local.service_account_create && var.service_account_name == null ? 1 : 0
  length  = 4
  upper   = false
  numeric = false
  special = false
}

# Random suffix for the ID of the custom role, so that several clusters can share one Secret Manager project
resource "random_string" "secret_manager_role_suffix" {
  count   = local.secret_manager_role_create ? 1 : 0
  length  = 4
  upper   = false
  numeric = false
  special = false
}

# Configuration of the google provider, for its project as the fallback of the project ID variables.
# It is read unconditionally: a count depending on whether the project ID variables are set could not be
# planned if they are only known after apply.
data "google_client_config" "current" {
  lifecycle {
    postcondition {
      condition     = var.secret_manager_project_id != null || try(coalesce(self.project), null) != null
      error_message = "secret_manager_project_id must be set if no project is configured in the google provider"
    }
    postcondition {
      condition     = !local.gke_project_id_required || var.gke_project_id != null || try(coalesce(self.project), null) != null
      error_message = "gke_project_id must be set if auth_method is workload_identity and no project is configured in the google provider, unless the Operator impersonates a Google service account and workload_identity_binding_create is false"
    }
  }
}

locals {
  use_workload_identity   = var.auth_method == "workload_identity"
  use_service_account_key = var.auth_method == "service_account_key"

  # Create a Google service account if requested, and by default only if the Operator uses its key
  service_account_create = coalesce(var.service_account_create, local.use_service_account_key)
  # Whether the Operator uses a Google service account passed in. Resource counts depend on it, so it must be known
  # during plan even if service_account_email is not, e.g. because the service account is created in the same
  # configuration: service_account_create = false decides it. Only if service_account_create is not set and the
  # Operator uses Workload Identity, it is inferred from whether service_account_email is set.
  use_existing_service_account = (
    var.service_account_create != null ? !var.service_account_create
    : !local.use_workload_identity ? false
    : var.service_account_email != null
  )
  # Whether the Operator uses a Google service account, either created by the module or passed in
  use_service_account = local.service_account_create || local.use_existing_service_account
  # With Workload Identity, the Operator service account either accesses Secret Manager itself, as the principal
  # of Workload Identity Federation for GKE, or impersonates a Google service account
  use_workload_identity_federation      = local.use_workload_identity && !local.use_service_account
  use_workload_identity_service_account = local.use_workload_identity && local.use_service_account

  # ID of the secret store: the ID passed in, or the generated ID
  secret_store_id = var.secret_store_id != null ? var.secret_store_id : "gcpsm-${random_string.secret_store_id_suffix[0].result}"

  # A cluster-wide secret store lives in the Operator namespace, an Environment-local store in the Environment namespace
  secret_store_namespace = var.secret_store_cluster_wide ? var.operator_namespace : var.secret_store_namespace

  # The Operator needs write access to the default store only, e.g. for storing resource cookies.
  # These are the least-privilege permissions of the custom role for read/write access, see
  # https://developer.humanitec.com/platform-orchestrator/guides/platform-engineers/security/connect-secret-stores/connect-to-google-cloud-secret-manager/#add-policy-binding
  secret_manager_permissions = (
    var.secret_store_default
    ? [
      "secretmanager.secrets.create",
      "secretmanager.secrets.delete",
      "secretmanager.secrets.update",
      "secretmanager.versions.add",
      "secretmanager.versions.access",
      "secretmanager.versions.list",
      "secretmanager.versions.destroy",
    ]
    : ["secretmanager.versions.access"]
  )
  # For the default store, the module creates a custom role with these permissions unless a role is passed in.
  # It only does so together with the role binding: if the binding is managed elsewhere, so is the role,
  # because destroying a role used by other bindings would revoke their access.
  # Resource counts depend on it, so it must be known during plan even if secret_manager_role is not, e.g. because
  # the role is created in the same configuration: secret_manager_role_create decides it. Only if that is not set,
  # it is inferred from whether secret_manager_role is set.
  secret_manager_role_create = (
    !var.secret_manager_access_create || !var.secret_store_default ? false
    : var.secret_manager_role_create != null ? var.secret_manager_role_create
    : var.secret_manager_role == null
  )
  # Role IDs must be 3-64 characters long and consist of letters, digits, underscores, and periods.
  # "humanitec_operator_" (19) + at most 40 characters of the secret store ID + "_" + the random suffix (4) yields at most 64.
  # Trailing hyphens of the truncated secret store ID are removed, and the remaining ones replaced with underscores.
  secret_manager_role_id = (
    local.secret_manager_role_create
    ? "humanitec_operator_${replace(replace(substr(local.secret_store_id, 0, 40), "/-+$/", ""), "-", "_")}_${random_string.secret_manager_role_suffix[0].result}"
    : null
  )
  # Role granted to the Operator identity: the role passed in, the custom role for the default store, or the
  # built-in read-only role otherwise. It is null for the default store if the module creates neither the binding nor the role.
  secret_manager_role = (
    local.secret_manager_role_create ? one(google_project_iam_custom_role.secret_manager[*].name)
    : var.secret_manager_role != null ? var.secret_manager_role
    : var.secret_store_default ? null
    : "roles/secretmanager.secretAccessor"
  )

  # Google service account IDs must be 6-30 characters long, start with a letter, and end with a letter or digit.
  # "humanitec-" (10) + at most 15 characters of the secret store ID + "-" + the random suffix (4) yields at most 30.
  # Trailing hyphens of the truncated secret store ID are removed.
  service_account_generated_name = (
    local.service_account_create && var.service_account_name == null
    ? "humanitec-${replace(substr(local.secret_store_id, 0, 15), "/-+$/", "")}-${random_string.service_account_name_suffix[0].result}"
    : null
  )

  # Attributes read back from the Google service account, so that references depend on it existing.
  # At most one of each pair exists, so one() yields null if the Operator does not use a Google service account.
  service_account_email     = one(concat(google_service_account.operator[*].email, data.google_service_account.operator[*].email))
  service_account_id        = one(concat(google_service_account.operator[*].name, data.google_service_account.operator[*].name))
  service_account_unique_id = one(concat(google_service_account.operator[*].unique_id, data.google_service_account.operator[*].unique_id))

  # Project of the google provider, or null if none is configured. The provider reports an unset project
  # as an empty string, which coalesce() skips, and try() turns the error of coalesce() without a value into null.
  provider_project_id = try(coalesce(data.google_client_config.current.project), null)
  # Project IDs passed in, falling back to the project of the google provider
  secret_manager_project_id = try(coalesce(var.secret_manager_project_id, local.provider_project_id), null)
  # The GKE project is only used with Workload Identity, so it only falls back to the provider project then.
  # It is required unless the Operator impersonates a Google service account whose Workload Identity binding is
  # managed outside of the module: then it only serves the workload_identity_member output.
  gke_project_id_required = local.use_workload_identity && (!local.use_service_account || var.workload_identity_binding_create)
  gke_project_id          = local.use_workload_identity ? try(coalesce(var.gke_project_id, local.provider_project_id), null) : null

  # Workload Identity pool of the GKE cluster, and the Operator service account in it.
  # https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity
  workload_identity_pool = local.gke_project_id != null ? "${local.gke_project_id}.svc.id.goog" : null
  # Principal of the Operator service account for granting it IAM roles directly (Workload Identity Federation for GKE)
  workload_identity_principal = (
    local.use_workload_identity_federation
    ? "principal://iam.googleapis.com/projects/${one(data.google_project.gke[*].number)}/locations/global/workloadIdentityPools/${local.workload_identity_pool}/subject/ns/${var.operator_namespace}/sa/${var.operator_serviceaccount}"
    : null
  )
  # Member of the Operator service account for allowing it to impersonate a Google service account
  workload_identity_member = (
    local.use_workload_identity_service_account && local.gke_project_id != null
    ? "serviceAccount:${local.workload_identity_pool}[${var.operator_namespace}/${var.operator_serviceaccount}]"
    : null
  )

  # IAM member of the identity the Operator uses, either the Google service account or the Operator service account itself
  operator_iam_member = local.use_service_account ? "serviceAccount:${local.service_account_email}" : local.workload_identity_principal

  # Key of the Google service account, either from the key created by the module or passed in.
  # The key is ephemeral if passed in, and is only ever written to write-only attributes.
  # The key created by the module is a base64-encoded JSON key file.
  service_account_key = local.use_service_account_key && local.service_account_create ? base64decode(one(google_service_account_key.operator[*].private_key)) : var.service_account_key
  service_account_credentials_secret_name = (
    local.use_service_account_key
    ? coalesce(var.service_account_credentials_secret_name, "${local.secret_store_id}-credentials")
    : null
  )

  # SecretStore resource, see https://developer.humanitec.com/platform-orchestrator/guides/platform-engineers/security/connect-secret-stores/connect-to-google-cloud-secret-manager/
  secret_store_metadata = merge(
    {
      name      = local.secret_store_id
      namespace = local.secret_store_namespace
    },
    var.secret_store_default ? { labels = { "app.humanitec.io/default-store" = "true" } } : {},
  )
  # Authentication of the secret store, depending on the auth method.
  # With a service account key, the store references the key in the credentials Secret.
  # With Workload Identity, the Operator uses the identity of its service account, which requires an empty auth.
  # Select the value by key instead of using a conditional: a conditional would convert both values into a map,
  # and kubernetes_manifest cannot convert an empty map into the auth object of the SecretStore CRD.
  secret_store_auth = {
    service_account_key = {
      secretAccessKeySecretRef = {
        name = local.service_account_credentials_secret_name
        key  = "secret-access-credentials"
      }
    }
    workload_identity = {}
  }[var.auth_method]
  # The location is omitted for the global Secret Manager
  secret_store_spec = merge(
    {
      projectID = local.secret_manager_project_id
      auth      = local.secret_store_auth
    },
    var.secret_manager_location != null ? { locationID = var.secret_manager_location } : {},
  )

  # Pattern for Google Cloud project IDs, optionally with the domain of a domain-scoped project.
  # Also used by the validations of the project ID variables.
  project_id_pattern = "^([a-z0-9.-]+:)?[a-z][-a-z0-9]{4,28}[a-z0-9]$"
}

# Workload Identity Federation for GKE (auth_method = "workload_identity" without a Google service account)

# Project of the GKE cluster, for the project number in the principal of the Operator service account
data "google_project" "gke" {
  count      = local.use_workload_identity_federation ? 1 : 0
  project_id = local.gke_project_id
}

# Google service account for the Operator
# (auth_method = "service_account_key", or "workload_identity" with a Google service account)

resource "google_service_account" "operator" {
  count        = local.service_account_create ? 1 : 0
  project      = coalesce(var.service_account_project_id, local.secret_manager_project_id)
  account_id   = coalesce(var.service_account_name, local.service_account_generated_name)
  display_name = coalesce(var.service_account_display_name, "Humanitec Operator ${local.secret_store_id}")
  description  = "Humanitec Operator access to the Google Cloud Secret Manager secret store ${local.secret_store_id}"
}

data "google_service_account" "operator" {
  count = local.use_existing_service_account ? 1 : 0
  # The wildcard "-" lets the IAM API infer the project from the email address,
  # so that the provider does not need a default project
  account_id = "projects/-/serviceAccounts/${var.service_account_email}"
}

# Allows the Operator service account to impersonate the Google service account via Workload Identity
resource "google_service_account_iam_member" "workload_identity" {
  count              = local.use_workload_identity_service_account && var.workload_identity_binding_create ? 1 : 0
  service_account_id = local.service_account_id
  role               = "roles/iam.workloadIdentityUser"
  member             = local.workload_identity_member
}

# Service account key (auth_method = "service_account_key")

resource "google_service_account_key" "operator" {
  count              = local.use_service_account_key && local.service_account_create ? 1 : 0
  service_account_id = google_service_account.operator[0].name
  keepers            = var.service_account_key_keepers
}

# Version of the key in the Kubernetes Secret. Write-only data is not part of the state, so a change
# cannot be detected on the Secret itself. Tracking the service account and the ID of the key created by the
# module, or the version passed in, here detects any change of the key, e.g. a rotation, and replaces the Secret.
resource "terraform_data" "service_account_key_version" {
  count = local.use_service_account_key ? 1 : 0
  input = {
    service_account_email = local.service_account_email
    key_version           = local.service_account_create ? one(google_service_account_key.operator[*].id) : tostring(coalesce(var.service_account_key_version, 0))
  }
}

# Kubernetes Secret holding the service account key, in the namespace of the secret store referencing it.
# The key is written via the write-only data_wo attribute so that it is not stored in the state.
# Like the secret store, it waits for the SecretStore CRD, as the Operator namespace may not exist before that.
resource "kubernetes_secret_v1" "operator_credentials" {
  count = local.use_service_account_key && local.secret_store_crd_ready ? 1 : 0
  metadata {
    name      = local.service_account_credentials_secret_name
    namespace = local.secret_store_namespace
  }
  data_wo = {
    secret-access-credentials = local.service_account_key
  }
  # The provider only writes data_wo, and skips reading the Secret data back into the state, if the revision is
  # at least 1. It stays constant, as any change of the key replaces the Secret, which writes data_wo anew.
  data_wo_revision = 1

  lifecycle {
    replace_triggered_by = [terraform_data.service_account_key_version[count.index]]
  }
}

# Secret Manager access for the Operator identity

# Least-privilege custom role for read/write access to the default store
resource "google_project_iam_custom_role" "secret_manager" {
  count       = local.secret_manager_role_create ? 1 : 0
  project     = local.secret_manager_project_id
  role_id     = local.secret_manager_role_id
  title       = "Humanitec Operator ${local.secret_store_id}"
  description = "Humanitec Operator read/write access to the Google Cloud Secret Manager secret store ${local.secret_store_id}"
  permissions = local.secret_manager_permissions
}

resource "google_project_iam_member" "operator" {
  count   = var.secret_manager_access_create ? 1 : 0
  project = local.secret_manager_project_id
  role    = local.secret_manager_role
  member  = local.operator_iam_member
}

# Secret store registration with the Operator

# Tracks the auth method and the location, so that changing them replaces the secret store
resource "terraform_data" "secret_store_replacement_triggers" {
  input = {
    auth_method             = var.auth_method
    secret_manager_location = var.secret_manager_location
  }
}

# Guard against the "secretstores" CRD not yet being present on the cluster
data "kubernetes_resources" "secret_store_crd" {
  api_version    = "apiextensions.k8s.io/v1"
  kind           = "CustomResourceDefinition"
  field_selector = "metadata.name=secretstores.humanitec.io"
}

locals {
  secret_store_crd_ready = length([
    for crd in data.kubernetes_resources.secret_store_crd.objects : crd
    if try(crd.metadata.deletionTimestamp, null) == null
  ]) > 0
}

# Shown as a warning in plan/apply output, does not fail the run
check "secret_store_crd" {
  assert {
    condition     = local.secret_store_crd_ready
    error_message = "SecretStore CRD not found: the SecretStore object on the cluster was not created. Run apply again once the Operator is installed."
  }
}

resource "kubernetes_manifest" "secret_store" {
  count = local.secret_store_crd_ready ? 1 : 0
  manifest = {
    apiVersion = "humanitec.io/v1alpha1"
    kind       = "SecretStore"
    metadata   = local.secret_store_metadata
    spec = {
      gcpsm = local.secret_store_spec
    }
  }

  # Only register the store once the Operator identity has its permissions
  depends_on = [
    google_service_account_iam_member.workload_identity,
    google_project_iam_member.operator,
    kubernetes_secret_v1.operator_credentials,
  ]

  lifecycle {
    # kubernetes_manifest cannot update the auth object from the Secret reference of a service account key
    # to the empty object of Workload Identity, or remove the location: it sends null, which the Kubernetes
    # API server rejects. Recreate the secret store whenever the auth method or the location changes instead.
    replace_triggered_by = [terraform_data.secret_store_replacement_triggers]
  }
}
