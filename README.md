# Google Cloud Secret Manager as an Operator secret store

This repository contains an OpenTofu/Terraform module to connect an instance of [Google Cloud Secret Manager](https://cloud.google.com/secret-manager/docs) as a secret store to the [Humanitec Operator](https://developer.humanitec.com/platform-orchestrator/docs/integration-and-extensions/humanitec-operator/overview/) running on a Google Kubernetes Engine (GKE) cluster. It implements the setup described in [Connect to Google Cloud Secret Manager](https://developer.humanitec.com/platform-orchestrator/guides/platform-engineers/security/connect-secret-stores/connect-to-google-cloud-secret-manager/).

The module creates:

- Depending on `auth_method`, the Google Cloud identity used by the Operator:
  - `workload_identity` (default, recommended): The Operator uses its Kubernetes service account via [Workload Identity Federation for GKE](https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity). By default, the module grants IAM roles to the Kubernetes service account directly, so it creates no further identity. Optionally, the Kubernetes service account impersonates a Google service account instead, and the module creates the service account and the IAM role binding allowing the impersonation
  - `service_account_key`: A Google service account with a key, plus a Kubernetes Secret holding the key
- The IAM role binding granting the Operator identity access to the Secret Manager on its Google Cloud project. The Operator gets read/write access to the [default secret store](https://developer.humanitec.com/platform-orchestrator/docs/integration-and-extensions/humanitec-operator/architecture/#the-default-secret-store) via a least-privilege custom role, which the module creates with only the [permissions it requires](https://developer.humanitec.com/platform-orchestrator/guides/platform-engineers/security/connect-secret-stores/connect-to-google-cloud-secret-manager/#add-policy-binding), and read-only access to any other store via the built-in role `roles/secretmanager.secretAccessor`. You can pass in another role instead
- The `SecretStore` Kubernetes resource registering the secret store with the Operator, either cluster-wide or Environment-local

You can also bring your own Google service account and key instead of having the module create them, and grant the Operator identity access to the Secret Manager yourself.

> [!NOTE]
> The module does not register the secret store with the Platform Orchestrator. Follow the [instructions](https://developer.humanitec.com/platform-orchestrator/guides/platform-engineers/security/connect-secret-stores/connect-to-google-cloud-secret-manager/#register-the-secret-store-with-the-platform-orchestrator) to do so, using the same secret store ID.

Prerequisites:

- The Secret Manager API is [enabled](https://cloud.google.com/secret-manager/docs/configuring-secret-manager) in the Google Cloud project of the Secret Manager
- The Humanitec Operator is installed on the cluster before you plan the module. See [Installation order](#installation-order)
- If you use Workload Identity, [Workload Identity Federation for GKE](https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity) is enabled on the GKE cluster and on the node pool running the Operator
- For an Environment-local secret store, the Environment namespace exists

The module requires a `google` provider that is allowed to manage IAM role bindings and, for the default store, custom roles on the Google Cloud project of the Secret Manager. Depending on the configuration, it also creates or reads Google service accounts, and reads the Google Cloud project of the GKE cluster.

## Installation order

The module creates the `SecretStore` resource using a `kubernetes_manifest`, which reads the `SecretStore` custom resource definition (CRD) from the cluster during planning. The Humanitec Operator Helm chart installs this CRD. Therefore, the Operator must already be installed when you plan the module.

If you install the Operator in the same OpenTofu/Terraform configuration as the present module, e.g. via a `helm_release`, apply the Operator before you add the module, e.g. in a separate stage or using `-target`. Adding a `depends_on` on the module is not sufficient, as the CRD is required during planning already.

> [!NOTE]
> **Architectural decision**
>
> A provider such as [alekc/kubectl](https://registry.terraform.io/providers/alekc/kubectl), which does not require the CRD to exist at plan time, would allow a single apply. However, it would introduce another external community provider, require users to configure and pass in a further provider, and require an additional module input to order the SecretStore after the Operator installation. It would also need retry handling, as a newly installed CRD can take a moment before the API server accepts resources of its type. The module therefore accepts the two-pass limitation. It only applies when the Operator is installed in the same run as the module, e.g. on a new cluster.

With the default Workload Identity setup, the Operator needs no further configuration. If the Operator impersonates a Google service account, its service account needs an annotation with the email address of the Google service account. See [Configure the Operator to impersonate the Google service account](#configure-the-operator-to-impersonate-the-google-service-account) for how to provide it.

> [!NOTE]
> **Architectural decision**
>
> The module grants the Operator access on the level of the Google Cloud project, as described in the [Humanitec documentation](https://developer.humanitec.com/platform-orchestrator/guides/platform-engineers/security/connect-secret-stores/connect-to-google-cloud-secret-manager/#add-policy-binding). The Operator creates new secrets in the default store, e.g. for resource cookies, so access to individual secrets would not suffice for the default store. Use a dedicated Google Cloud project for the Secret Manager to limit the access of the Operator to the secrets in it.

## Usage

### Common usage: Default secret store with Workload Identity

This configuration creates a cluster-wide secret store, and grants the Operator service account read/write access to the Secret Manager via Workload Identity Federation for GKE, using a least-privilege custom role created in the Secret Manager project. The secret store is the default store of the Operator, as `secret_store_default` is `true` by default.

The module identifies the Operator service account by the Workload Identity pool of the GKE cluster, i.e. `<gke_project_id>.svc.id.goog`, and reads the project number of the GKE project for its IAM principal. Unless you change `operator_namespace` and `operator_serviceaccount`, the principal is the default service account `humanitec-operator-controller-manager` in the namespace `humanitec-operator-system`.

```hcl
module "my_gcpsm_secret_store" {
  source = "github.com/humanitec-tf-modules/secret-store-gcpsm?ref=vX.Y.Z"
  providers = {
    google     = google
    kubernetes = kubernetes
  }

  secret_store_id           = "my-gcpsm"
  secret_manager_project_id = "my-gsm-project"
  gke_project_id            = "my-gke-project"
}
```

The Operator does not need any further configuration.

> [!NOTE]
> IAM role bindings can take several minutes to propagate. The Operator may fail to access the Secret Manager until then.

> [!IMPORTANT]
> The Operator uses exactly one Google Cloud identity for all secret stores using Workload Identity: if its Kubernetes service account carries the annotation `iam.gke.io/gcp-service-account`, it impersonates that Google service account, otherwise it uses the Kubernetes service account itself. IAM roles granted to the identity the Operator does not use have no effect. All secret stores on the cluster that use Workload Identity must therefore use the same setup, i.e. either all of them grant access to the Kubernetes service account, or all of them to the same Google service account.
>
> This does not apply to `auth_method = "service_account_key"`, where each secret store references its own key.

### Non-default secret store

Set `secret_store_default` to `false` to create a cluster-wide secret store that is not the default store, e.g. if you already have a default store. The Operator gets read-only access to this store.

This configuration adds a non-default secret store for the Secret Manager of a second Google Cloud project next to the [default secret store](#common-usage-default-secret-store-with-workload-identity).

```hcl
module "my_other_gcpsm_secret_store" {
  source = "github.com/humanitec-tf-modules/secret-store-gcpsm?ref=vX.Y.Z"
  providers = {
    google     = google
    kubernetes = kubernetes
  }

  secret_store_id           = "my-other-gcpsm"
  secret_store_default      = false
  secret_manager_project_id = "my-other-gsm-project"
  gke_project_id            = "my-gke-project"
}
```

If the second secret store uses the Secret Manager of the same project as the default store, set `secret_manager_access_create` to `false`: the role of the default store already includes read access to all secrets in the project.

### Several Environment-local secret stores

An Environment-local secret store is located in the namespace of an Environment, so that only Deployments into that namespace can use it. It cannot be the default store, so `secret_store_default` must be set to `false`, and the Operator gets read-only access to it.

The Operator reads the secrets on behalf of the Environments, so all secret stores using Workload Identity share the identity of the Operator. Whether the Environment-local stores need to grant this identity access to the Secret Manager depends on which Google Cloud project they use. If the Environment-local stores use service account keys instead of Workload Identity, none of this applies, see [With service account keys](#with-service-account-keys).

#### One Secret Manager project per Environment

If each Environment-local store uses the Secret Manager of its own Google Cloud project, no other secret store uses the access to it. Let each instance of the module grant the Operator read-only access to its project, i.e. leave `secret_manager_access_create` at `true`.

```hcl
locals {
  environment_projects = {
    "my-app-development" = "my-app-development-secrets"
    "my-app-staging"     = "my-app-staging-secrets"
  }
}

module "my_environment_gcpsm_secret_store" {
  source = "github.com/humanitec-tf-modules/secret-store-gcpsm?ref=vX.Y.Z"
  providers = {
    google     = google
    kubernetes = kubernetes
  }
  for_each = local.environment_projects

  secret_store_id           = "my-gcpsm-${each.key}"
  secret_store_default      = false
  secret_store_cluster_wide = false
  secret_store_namespace    = each.key
  secret_manager_project_id = each.value
  gke_project_id            = "my-gke-project"
}
```

#### One Secret Manager project shared by the Environments

If all Environment-local stores share the Secret Manager of one Google Cloud project, grant the Operator read-only access to it once outside of the module, and set `secret_manager_access_create` to `false` for the Environment-local stores. IAM role bindings created via `google_project_iam_member` are non-authoritative and identified by project, role, and member. If several instances of the module created the same binding, destroying one of them would revoke the access of all others. The `operator_iam_member` and `secret_manager_role` outputs of the module name the access to grant.

If the project is also the project of the default store, the role of the default store already includes read access, so no further binding is needed.

```hcl
locals {
  environment_namespaces = toset(["my-app-development", "my-app-staging"])
}

data "google_project" "my_gke_project" {
  project_id = "my-gke-project"
}

# Or the operator_iam_member output of any of the module instances
resource "google_project_iam_member" "humanitec_operator" {
  project = "my-environments-gsm-project"
  role    = "roles/secretmanager.secretAccessor"
  member  = "principal://iam.googleapis.com/projects/${data.google_project.my_gke_project.number}/locations/global/workloadIdentityPools/my-gke-project.svc.id.goog/subject/ns/humanitec-operator-system/sa/humanitec-operator-controller-manager"
}

module "my_environment_gcpsm_secret_store" {
  source = "github.com/humanitec-tf-modules/secret-store-gcpsm?ref=vX.Y.Z"
  providers = {
    google     = google
    kubernetes = kubernetes
  }
  for_each = local.environment_namespaces

  secret_store_id              = "my-gcpsm-${each.key}"
  secret_store_default         = false
  secret_store_cluster_wide    = false
  secret_store_namespace       = each.key
  secret_manager_project_id    = "my-environments-gsm-project"
  gke_project_id               = "my-gke-project"
  secret_manager_access_create = false
}
```

> [!NOTE]
> The Operator can read all secrets in the project, so Environment-local stores sharing one project do not isolate the secrets of the Environments from each other. Use one project per Environment for isolation.

#### With service account keys

With `auth_method = "service_account_key"`, each secret store references its own key, so the Environment-local stores do not share an identity. Each instance of the module creates a dedicated Google service account and key, a Kubernetes Secret holding the key in the Environment namespace, and the access of the service account to the Secret Manager. The IAM role bindings of different service accounts do not conflict, so this works for any combination of projects, and removing one secret store only revokes the access of its own service account.

This example gives each Environment the Secret Manager of its own Google Cloud project, so that each service account can only read the secrets of its own Environment.

```hcl
locals {
  environment_projects = {
    "my-app-development" = "my-app-development-secrets"
    "my-app-staging"     = "my-app-staging-secrets"
  }
}

module "my_environment_gcpsm_secret_store" {
  source = "github.com/humanitec-tf-modules/secret-store-gcpsm?ref=vX.Y.Z"
  providers = {
    google     = google
    kubernetes = kubernetes
  }
  for_each = local.environment_projects

  secret_store_id           = "my-gcpsm-${each.key}"
  secret_store_default      = false
  secret_store_cluster_wide = false
  secret_store_namespace    = each.key
  secret_manager_project_id = each.value

  auth_method = "service_account_key"
}
```

The module creates each service account in the project of its Secret Manager. Set `service_account_project_id` to create it in another project.

> [!WARNING]
> The Kubernetes Secret holding the key is located in the Environment namespace. Anyone who can read Secrets in that namespace can use the service account, and thus read the secrets in the Secret Manager of that Environment. Using a dedicated service account per secret store limits this to one secret store. The key is also stored in the OpenTofu/Terraform state, see [Use a service account key](#use-a-service-account-key).

### Regional Secret Manager

Set `secret_manager_location` to use a [regional Secret Manager](https://cloud.google.com/secret-manager/docs/locations) instead of the global one. The module sets it as the `locationID` of the secret store. Changing it replaces the `SecretStore` resource.

```hcl
module "my_gcpsm_secret_store" {
  source = "github.com/humanitec-tf-modules/secret-store-gcpsm?ref=vX.Y.Z"
  providers = {
    google     = google
    kubernetes = kubernetes
  }

  secret_store_id           = "my-gcpsm"
  secret_manager_project_id = "my-gsm-project"
  secret_manager_location   = "europe-west3"
  gke_project_id            = "my-gke-project"
}
```

### Passing in an IAM role

For the default store, the module creates a least-privilege custom role named `humanitec_operator_<secret store ID>_<random>` in the Secret Manager project. To use a role of your own instead, e.g. one custom role shared by the default stores of several clusters, or one adhering to your naming conventions, pass it in via `secret_manager_role`. The module then creates no custom role. You can pass in any role, also for a non-default store, as long as it has the permissions listed in the `secret_manager_permissions` output.

If the role is only known after apply, as in this example where the role is created in the same configuration, also set `secret_manager_role_create` to `false`. Otherwise, the module cannot tell during plan whether to create its own custom role, and the plan fails with an `Invalid count argument` error. For a literal role name like `roles/secretmanager.admin`, setting `secret_manager_role` is enough.

```hcl
resource "google_project_iam_custom_role" "humanitec_operator" {
  project     = "my-gsm-project"
  role_id     = "secretmanager.readwrite"
  title       = "Secret Reader/Writer"
  description = "Can create new and update existing secrets and read them"
  permissions = [
    "secretmanager.secrets.create",
    "secretmanager.secrets.delete",
    "secretmanager.secrets.update",
    "secretmanager.versions.add",
    "secretmanager.versions.access",
    "secretmanager.versions.list",
    "secretmanager.versions.destroy",
  ]
}

module "my_gcpsm_secret_store" {
  source = "github.com/humanitec-tf-modules/secret-store-gcpsm?ref=vX.Y.Z"
  providers = {
    google     = google
    kubernetes = kubernetes
  }

  secret_store_id           = "my-gcpsm"
  secret_manager_project_id = "my-gsm-project"
  gke_project_id            = "my-gke-project"
  # The role name is only known after apply, so tell the module explicitly not to create its own role
  secret_manager_role_create = false
  secret_manager_role        = google_project_iam_custom_role.humanitec_operator.name
}
```

### Workload Identity with a Google service account

Instead of granting access to the Operator service account directly, you can let it impersonate a Google service account, e.g. because the Operator already impersonates a Google service account for other purposes, such as the `gcp` auth method of [HashiCorp Vault](https://developer.humanitec.com/platform-orchestrator/guides/platform-engineers/security/connect-secret-stores/connect-to-hashicorp-vault/#configure-the-gcp-auth-method). Note that in that case, the Operator uses the Google service account for all secret stores using Workload Identity, see [this note](#common-usage-default-secret-store-with-workload-identity).

This configuration creates the default secret store, as well as a Google service account, a least-privilege custom role and the IAM role binding granting it to the service account on the Secret Manager project, and the IAM role binding with the role `roles/iam.workloadIdentityUser` allowing the Operator service account to impersonate it. The module generates the account ID of the service account from the secret store ID, and creates it in the project of the Secret Manager, unless you set `service_account_name` and `service_account_project_id`.

```hcl
module "my_gcpsm_secret_store" {
  source = "github.com/humanitec-tf-modules/secret-store-gcpsm?ref=vX.Y.Z"
  providers = {
    google     = google
    kubernetes = kubernetes
  }

  secret_store_id           = "my-gcpsm"
  secret_manager_project_id = "my-gsm-project"
  gke_project_id            = "my-gke-project"

  service_account_create = true
  # Optional: customize the service account
  service_account_name         = "humanitec-operator"
  service_account_display_name = "Humanitec Operator"
  service_account_project_id   = "my-gke-project"
}
```

Then [configure the Operator to impersonate the Google service account](#configure-the-operator-to-impersonate-the-google-service-account).

#### Configure the Operator to impersonate the Google service account

The Operator service account must be annotated with the email address of the Google service account. The module does not modify the Operator installation, so you need to set it via the Helm values of the Operator.

Use the `operator_serviceaccount_annotations` output of the module in the Helm values of the existing Operator installation:

```hcl
locals {
  humanitec_operator_helm_values = {
    controllerManager = {
      serviceAccount = {
        annotations = module.my_gcpsm_secret_store.operator_serviceaccount_annotations
      }
    }
  }
}
```

This corresponds to these Helm values:

```yaml
controllerManager:
  serviceAccount:
    annotations:
      iam.gke.io/gcp-service-account: <email address of the Google service account>
```

Then restart the Operator to pick up the Google service account:

```shell
kubectl rollout restart deployment -n humanitec-operator-system humanitec-operator-controller-manager
```

To set the Helm values when you first install the Operator instead, create the Google service account before the Operator and [bring your own Google service account](#bring-your-own-google-service-account).

#### Bring your own Google service account

This configuration creates the default secret store, using your own Google service account. The module grants it access to the Secret Manager, and allows the Operator service account to impersonate it.

Creating the Google service account yourself lets you set the annotation when you first install the Operator, before the module runs.

Set `service_account_create` to `false` to use the Google service account passed in via `service_account_email`. If you omit it, the module infers it from `service_account_email` being set, which only works for a literal email address: an email address only known after apply, as in this example, fails the plan with an `Invalid count argument` error.

```hcl
resource "google_service_account" "humanitec_operator" {
  project      = "my-gke-project"
  account_id   = "humanitec-operator"
  display_name = "Humanitec Operator"
}

# Set controllerManager.serviceAccount.annotations."iam.gke.io/gcp-service-account" to
# google_service_account.humanitec_operator.email in the Helm values of the Operator installation.

module "my_gcpsm_secret_store" {
  source = "github.com/humanitec-tf-modules/secret-store-gcpsm?ref=vX.Y.Z"
  providers = {
    google     = google
    kubernetes = kubernetes
  }

  secret_store_id           = "my-gcpsm"
  secret_manager_project_id = "my-gsm-project"
  gke_project_id            = "my-gke-project"

  service_account_create = false
  service_account_email  = google_service_account.humanitec_operator.email
}
```

If several secret stores use the same Google service account, let at most one instance of the module create the IAM role binding allowing the impersonation, and set `workload_identity_binding_create` to `false` for all other instances. As with the [access to the Secret Manager](#one-secret-manager-project-shared-by-the-environments), destroying one of several instances managing the same binding would revoke it for all of them. If you set `workload_identity_binding_create` to `false`, `gke_project_id` is optional. If you set it, the `workload_identity_member` output names the member to grant `roles/iam.workloadIdentityUser` on the service account yourself.

```hcl
module "my_other_gcpsm_secret_store" {
  source = "github.com/humanitec-tf-modules/secret-store-gcpsm?ref=vX.Y.Z"
  providers = {
    google     = google
    kubernetes = kubernetes
  }

  secret_store_id           = "my-other-gcpsm"
  secret_store_default      = false
  secret_manager_project_id = "my-other-gsm-project"

  service_account_create           = false
  service_account_email            = google_service_account.humanitec_operator.email
  workload_identity_binding_create = false
}
```

### Use a service account key

This configuration creates the default secret store, as well as a Google service account and a key for it. It stores the key in a Kubernetes Secret referenced by the secret store. Using a service account key requires you to maintain static credentials, so prefer Workload Identity where possible.

```hcl
resource "time_rotating" "humanitec_operator_key" {
  rotation_days = 90
}

module "my_gcpsm_secret_store" {
  source = "github.com/humanitec-tf-modules/secret-store-gcpsm?ref=vX.Y.Z"
  providers = {
    google     = google
    kubernetes = kubernetes
  }

  secret_store_id           = "my-gcpsm"
  secret_manager_project_id = "my-gsm-project"

  auth_method = "service_account_key"

  # Optional: rotate the key regularly
  service_account_key_keepers = {
    rotation = time_rotating.humanitec_operator_key.id
  }
}
```

The module creates the service account in the project of the Secret Manager unless you set `service_account_project_id`. The key does not expire, unless an organization policy sets an expiry for service account keys. Changing `service_account_key_keepers` replaces the key, and the module updates the Kubernetes Secret accordingly.

> [!WARNING]
> If the module creates the key, it is stored in the OpenTofu/Terraform state as part of the `google_service_account_key` resource. Make sure your state is stored securely, or [bring your own service account key](#bring-your-own-service-account-key) to keep the key out of the state.

> [!NOTE]
> Organizations created on or after May 3, 2024 enforce the organization policy `iam.disableServiceAccountKeyCreation` by default, which prevents creating service account keys. See [Secure by default organization resources](https://cloud.google.com/resource-manager/docs/secure-by-default-organizations).

### Bring your own service account key

This configuration creates the default secret store, using your own Google service account and key. The module grants the service account access to the Secret Manager, and stores the key in a Kubernetes Secret referenced by the secret store.

The key is not stored in the state or plan: `service_account_key` is an ephemeral variable, and the module only writes the key to the write-only `data_wo` attribute of the Kubernetes Secret. To keep the key out of your own state as well, read it from an ephemeral source, e.g. a secret in another Secret Manager:

```hcl
ephemeral "google_secret_manager_secret_version" "operator_key" {
  project = "my-admin-project"
  secret  = "humanitec-operator-key"
}

module "my_gcpsm_secret_store" {
  source = "github.com/humanitec-tf-modules/secret-store-gcpsm?ref=vX.Y.Z"
  providers = {
    google     = google
    kubernetes = kubernetes
  }

  secret_store_id           = "my-gcpsm"
  secret_manager_project_id = "my-gsm-project"

  auth_method                 = "service_account_key"
  service_account_create      = false
  service_account_email       = "humanitec-operator@my-gke-project.iam.gserviceaccount.com"
  service_account_key         = ephemeral.google_secret_manager_secret_version.operator_key.secret_data
  service_account_key_version = 1
}
```

The key must be the content of the JSON key file of the service account, not base64-encoded. The email address of the service account must not be ephemeral, as the module keeps it in the state to detect changes of the write-only key. When you rotate the key, pass in the new key and increase `service_account_key_version`. The new version makes the module replace the Kubernetes Secret with the new key. Changing only the key does not update the Kubernetes Secret.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.11.0 |
| <a name="requirement_google"></a> [google](#requirement\_google) | >= 7.0.0, < 9.0.0 |
| <a name="requirement_kubernetes"></a> [kubernetes](#requirement\_kubernetes) | ~> 3 |
| <a name="requirement_random"></a> [random](#requirement\_random) | ~> 3.3 |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [google_project_iam_custom_role.secret_manager](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/project_iam_custom_role) | resource |
| [google_project_iam_member.operator](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/project_iam_member) | resource |
| [google_service_account.operator](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account) | resource |
| [google_service_account_iam_member.workload_identity](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account_iam_member) | resource |
| [google_service_account_key.operator](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account_key) | resource |
| [kubernetes_manifest.secret_store](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/manifest) | resource |
| [kubernetes_secret_v1.operator_credentials](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret_v1) | resource |
| [random_string.secret_manager_role_suffix](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/string) | resource |
| [random_string.secret_store_id_suffix](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/string) | resource |
| [random_string.service_account_name_suffix](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/string) | resource |
| [terraform_data.secret_store_replacement_triggers](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |
| [terraform_data.service_account_key_version](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |
| [google_project.gke](https://registry.terraform.io/providers/hashicorp/google/latest/docs/data-sources/project) | data source |
| [google_service_account.operator](https://registry.terraform.io/providers/hashicorp/google/latest/docs/data-sources/service_account) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_auth_method"></a> [auth\_method](#input\_auth\_method) | How the Operator authenticates against Google Cloud Secret Manager. `workload_identity` (recommended): the Operator uses its Kubernetes service account via Workload Identity Federation for GKE, either directly or by impersonating a Google service account. `service_account_key`: the Operator uses a key of a Google service account, stored in a Kubernetes Secret. | `string` | `"workload_identity"` | no |
| <a name="input_gke_project_id"></a> [gke\_project\_id](#input\_gke\_project\_id) | ID of the Google Cloud project of the GKE cluster hosting the Operator. Its Workload Identity pool `<gke_project_id>.svc.id.goog` identifies the Operator service account. The cluster and the node pool running the Operator must have Workload Identity Federation for GKE enabled. Required if `auth_method` is `workload_identity`, unless the Operator impersonates a Google service account and `workload_identity_binding_create` is `false`. Must not be set if `auth_method` is `service_account_key`. | `string` | `null` | no |
| <a name="input_operator_namespace"></a> [operator\_namespace](#input\_operator\_namespace) | Name of the Kubernetes namespace of the Humanitec Operator. | `string` | `"humanitec-operator-system"` | no |
| <a name="input_operator_serviceaccount"></a> [operator\_serviceaccount](#input\_operator\_serviceaccount) | Name of the Kubernetes service account of the Humanitec Operator. Used to identify the Operator via Workload Identity Federation for GKE if `auth_method` is `workload_identity`. | `string` | `"humanitec-operator-controller-manager"` | no |
| <a name="input_secret_manager_access_create"></a> [secret\_manager\_access\_create](#input\_secret\_manager\_access\_create) | Whether to grant the Operator identity access to the Secret Manager, via an IAM role binding on the `secret_manager_project_id` project. Set it to `false` if the identity already has access, e.g. if several secret stores share one identity and one Secret Manager project: the bindings are non-authoritative, so if several module instances manage the same binding, destroying one instance revokes the access of the others. Grant the access yourself in that case, using the `operator_iam_member` output and a role with the permissions of the `secret_manager_permissions` output. The module then creates no custom role for the default store either. | `bool` | `true` | no |
| <a name="input_secret_manager_location"></a> [secret\_manager\_location](#input\_secret\_manager\_location) | Location of a regional Secret Manager, e.g. `europe-west3`. Leave it unset to use the global Secret Manager. Changing it replaces the `SecretStore` resource. | `string` | `null` | no |
| <a name="input_secret_manager_project_id"></a> [secret\_manager\_project\_id](#input\_secret\_manager\_project\_id) | ID of the Google Cloud project whose Secret Manager is used as the secret store, e.g. `my-gsm-project`. The Secret Manager API must be enabled in the project. This may be the project of the GKE cluster hosting the Operator, or a different one. | `string` | n/a | yes |
| <a name="input_secret_manager_role"></a> [secret\_manager\_role](#input\_secret\_manager\_role) | IAM role granted to the Operator identity on the Secret Manager project, e.g. a custom role like `projects/my-gsm-project/roles/secretmanager.readwrite` or a built-in role like `roles/secretmanager.admin`. If not set, the module creates a least-privilege custom role for the default store, and uses the built-in role `roles/secretmanager.secretAccessor` otherwise. For the default store, also set `secret_manager_role_create` to `false` if the role is only known after apply. See the `secret_manager_permissions` output for the permissions the role needs. The module only creates the custom role if `secret_manager_access_create` is `true`. | `string` | `null` | no |
| <a name="input_secret_manager_role_create"></a> [secret\_manager\_role\_create](#input\_secret\_manager\_role\_create) | Whether to create a least-privilege custom role for the default store and grant it to the Operator identity. Set it to `false` to grant the `secret_manager_role` passed in instead. If not set, the module creates the custom role unless `secret_manager_role` is set. Set it explicitly to `false` if `secret_manager_role` is only known after apply, e.g. because it refers to a `google_project_iam_custom_role` in the same configuration: the module can only plan the custom role if it knows whether to create it. Only used for the default store if `secret_manager_access_create` is `true`. | `bool` | `null` | no |
| <a name="input_secret_store_cluster_wide"></a> [secret\_store\_cluster\_wide](#input\_secret\_store\_cluster\_wide) | Whether the secret store is cluster-wide, i.e. usable by all Deployments onto the cluster. A cluster-wide store is created in the `operator_namespace`. If `false`, the store is Environment-local and created in `secret_store_namespace`, so it can only be used by Deployments into that namespace. | `bool` | `true` | no |
| <a name="input_secret_store_default"></a> [secret\_store\_default](#input\_secret\_store\_default) | Whether the secret store is the default secret store of the Operator. Only a cluster-wide secret store can be the default store, so set it to `false` for an Environment-local store. The Operator gets read/write access to the default store, and read-only access to any other store. | `bool` | `true` | no |
| <a name="input_secret_store_id"></a> [secret\_store\_id](#input\_secret\_store\_id) | ID of the secret store. It is the name of the Kubernetes `SecretStore` resource and the `store` value used in secret references. If you also register the secret store with the Platform Orchestrator, use the same ID there. If not set, the module generates an ID in the pattern `gcpsm-<random>`, with `<random>` being a random string of four lowercase letters, e.g. `gcpsm-kxqp`. Use the `secret_store_id` output to read it. | `string` | `null` | no |
| <a name="input_secret_store_namespace"></a> [secret\_store\_namespace](#input\_secret\_store\_namespace) | Name of the Kubernetes namespace of the Environment for an Environment-local secret store. Required if `secret_store_cluster_wide` is `false`, must not be set otherwise. The namespace must exist. | `string` | `null` | no |
| <a name="input_service_account_create"></a> [service\_account\_create](#input\_service\_account\_create) | Whether to create a Google service account for the Operator. If not set, the module creates one if `auth_method` is `service_account_key`, and none if `auth_method` is `workload_identity`. With `workload_identity`, the Operator service account impersonates the Google service account if the module creates one or `service_account_email` is set, and uses Workload Identity Federation for GKE directly otherwise. Set it to `false` to use an existing service account passed in via `service_account_email`, and, with `service_account_key`, its key passed in via `service_account_key`. With `workload_identity`, you can omit it if `service_account_email` is a literal value, but set it explicitly to `false` if `service_account_email` is only known after apply, e.g. because it refers to a `google_service_account` in the same configuration: the module can only plan its resources if it knows whether the Operator uses a Google service account. | `bool` | `null` | no |
| <a name="input_service_account_credentials_secret_name"></a> [service\_account\_credentials\_secret\_name](#input\_service\_account\_credentials\_secret\_name) | Name of the Kubernetes Secret holding the key of the Google service account. It is created in the namespace of the secret store. The key is written to the Secret via a write-only attribute, so the Secret does not add it to the state. Only used if `auth_method` is `service_account_key`. If not set, the name is `<secret store ID>-credentials`. | `string` | `null` | no |
| <a name="input_service_account_display_name"></a> [service\_account\_display\_name](#input\_service\_account\_display\_name) | Display name of the Google service account to create for the Operator. Only used if the module creates the service account. If not set, the display name is `Humanitec Operator <secret store ID>`. | `string` | `null` | no |
| <a name="input_service_account_email"></a> [service\_account\_email](#input\_service\_account\_email) | Email address of an existing Google service account to be used by the Operator, e.g. `humanitec-operator@my-project.iam.gserviceaccount.com`. Required if `service_account_create` is `false`. With `workload_identity`, the Operator service account impersonates this service account. Must not be set if the module creates the service account. | `string` | `null` | no |
| <a name="input_service_account_key"></a> [service\_account\_key](#input\_service\_account\_key) | Key of the existing Google service account passed in via `service_account_email`, i.e. the content of its JSON key file. Required if `auth_method` is `service_account_key` and `service_account_create` is `false`, must be empty otherwise. The variable is ephemeral, so the value can come from an ephemeral source. It is not stored in the state or plan, as the module only writes it to a write-only attribute of the Kubernetes Secret. The Kubernetes Secret is only updated if `service_account_email` or `service_account_key_version` changes as well. | `string` | `""` | no |
| <a name="input_service_account_key_keepers"></a> [service\_account\_key\_keepers](#input\_service\_account\_key\_keepers) | Arbitrary map of values that, when changed, replace the key of the Google service account created for the Operator, e.g. the `id` of a `time_rotating` resource to rotate the key regularly. The module updates the Kubernetes Secret accordingly. Only used if `auth_method` is `service_account_key` and the module creates the service account. | `map(string)` | `null` | no |
| <a name="input_service_account_key_version"></a> [service\_account\_key\_version](#input\_service\_account\_key\_version) | Version of the key passed in via `service_account_key`. The module keeps it in the state to detect changes of the write-only key. Increase it whenever you pass in a new key, e.g. when rotating it, to make the module replace the Kubernetes Secret holding the key. Only used if `auth_method` is `service_account_key` and `service_account_create` is `false`. | `number` | `null` | no |
| <a name="input_service_account_name"></a> [service\_account\_name](#input\_service\_account\_name) | Account ID of the Google service account to create for the Operator, i.e. the part of its email address before the `@`. Must be 6 to 30 characters long. Only used if the module creates the service account. If not set, the module generates an account ID from the secret store ID and a random four-letter suffix. | `string` | `null` | no |
| <a name="input_service_account_project_id"></a> [service\_account\_project\_id](#input\_service\_account\_project\_id) | ID of the Google Cloud project in which to create the Google service account for the Operator. If not set, the `secret_manager_project_id` is used. Only used if the module creates the service account. | `string` | `null` | no |
| <a name="input_workload_identity_binding_create"></a> [workload\_identity\_binding\_create](#input\_workload\_identity\_binding\_create) | Whether to allow the Operator service account to impersonate the Google service account, by granting it the role `roles/iam.workloadIdentityUser` on the service account. Only used if `auth_method` is `workload_identity` and the Operator impersonates a Google service account. Set it to `false` if the binding already exists, e.g. because another instance of the module manages it for the same Google service account. Use the `workload_identity_member` output to create it yourself. | `bool` | `true` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_operator_iam_member"></a> [operator\_iam\_member](#output\_operator\_iam\_member) | IAM member of the identity the Operator uses, e.g. to grant it access to further Google Cloud resources. This is `serviceAccount:<email>` if the Operator uses a Google service account, or the `principal://` identifier of the Operator service account if it uses Workload Identity Federation for GKE directly. |
| <a name="output_operator_serviceaccount_annotations"></a> [operator\_serviceaccount\_annotations](#output\_operator\_serviceaccount\_annotations) | Annotations to set on the Operator service account so that it impersonates the Google service account via Workload Identity, e.g. via the `controllerManager.serviceAccount.annotations` value of the Operator Helm chart. Restart the Operator after changing them. Returns an empty map if `auth_method` is not `workload_identity` or the Operator does not impersonate a Google service account. |
| <a name="output_secret_manager_custom_role_id"></a> [secret\_manager\_custom\_role\_id](#output\_secret\_manager\_custom\_role\_id) | ID of the least-privilege custom role created by the module for the default store, i.e. `projects/<project>/roles/<role_id>`. Returns `null` if the module does not create it. |
| <a name="output_secret_manager_iam_member_id"></a> [secret\_manager\_iam\_member\_id](#output\_secret\_manager\_iam\_member\_id) | ID of the IAM role binding granting the Operator access to the Secret Manager project. Returns `null` if `secret_manager_access_create` is `false`. |
| <a name="output_secret_manager_location"></a> [secret\_manager\_location](#output\_secret\_manager\_location) | Location of the regional Secret Manager, used as the `locationID` of the secret store. Returns `null` for the global Secret Manager. |
| <a name="output_secret_manager_permissions"></a> [secret\_manager\_permissions](#output\_secret\_manager\_permissions) | Permissions the Operator identity needs on the Secret Manager project: read/write permissions for the default store, and `secretmanager.versions.access` for any other store. The custom role created by the module for the default store has exactly these permissions. If you pass in a role or grant the access yourself, ensure the role has them. |
| <a name="output_secret_manager_project_id"></a> [secret\_manager\_project\_id](#output\_secret\_manager\_project\_id) | ID of the Google Cloud project of the Secret Manager, used as the `projectID` of the secret store. |
| <a name="output_secret_manager_role"></a> [secret\_manager\_role](#output\_secret\_manager\_role) | IAM role granted to the Operator identity on the Secret Manager project: `secret_manager_role` if set, otherwise the name of the least-privilege custom role created by the module for the default store, e.g. `projects/my-gsm-project/roles/humanitec_operator_gcpsm_kxqp`, and `roles/secretmanager.secretAccessor` for any other store. Returns `null` for the default store if neither `secret_manager_role` is set nor `secret_manager_access_create` is `true`. |
| <a name="output_secret_store_id"></a> [secret\_store\_id](#output\_secret\_store\_id) | ID of the secret store, i.e. the name of the Kubernetes `SecretStore` resource. This is either `secret_store_id` or the generated ID. Use it as the `store` in secret references. |
| <a name="output_secret_store_namespace"></a> [secret\_store\_namespace](#output\_secret\_store\_namespace) | Name of the Kubernetes namespace of the `SecretStore` resource. This is the Operator namespace for a cluster-wide store, or the Environment namespace for an Environment-local store. |
| <a name="output_service_account_credentials_secret_name"></a> [service\_account\_credentials\_secret\_name](#output\_service\_account\_credentials\_secret\_name) | Name of the Kubernetes Secret holding the key of the Google service account, located in the `secret_store_namespace`. Returns `null` if `auth_method` is not `service_account_key`. |
| <a name="output_service_account_email"></a> [service\_account\_email](#output\_service\_account\_email) | Email address of the Google service account used by the Operator. Returns `null` if the Operator does not use a Google service account. |
| <a name="output_service_account_id"></a> [service\_account\_id](#output\_service\_account\_id) | Fully qualified ID of the Google service account used by the Operator, i.e. `projects/<project>/serviceAccounts/<email>`. Returns `null` if the Operator does not use a Google service account. |
| <a name="output_service_account_unique_id"></a> [service\_account\_unique\_id](#output\_service\_account\_unique\_id) | Unique numeric ID of the Google service account used by the Operator. Returns `null` if the Operator does not use a Google service account. |
| <a name="output_workload_identity_binding_id"></a> [workload\_identity\_binding\_id](#output\_workload\_identity\_binding\_id) | ID of the IAM role binding allowing the Operator service account to impersonate the Google service account. Returns `null` if the module does not create it. |
| <a name="output_workload_identity_member"></a> [workload\_identity\_member](#output\_workload\_identity\_member) | IAM member of the Operator service account in the Workload Identity pool of the GKE cluster, i.e. `serviceAccount:<gke_project_id>.svc.id.goog[<operator_namespace>/<operator_serviceaccount>]`. If `workload_identity_binding_create` is `false`, grant it the role `roles/iam.workloadIdentityUser` on the Google service account yourself. Returns `null` if `auth_method` is not `workload_identity`, the Operator does not impersonate a Google service account, or `gke_project_id` is not set. |
<!-- END_TF_DOCS -->
