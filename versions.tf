terraform {
  # 1.11.0 introduced write-only attributes in Terraform and OpenTofu, and ephemeral variables in OpenTofu.
  required_version = ">= 1.11.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 7.0.0, < 9.0.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3"
    }
    # 3.3.0 introduced the numeric attribute of the random_string resource.
    random = {
      source  = "hashicorp/random"
      version = "~> 3.3"
    }
  }
}
