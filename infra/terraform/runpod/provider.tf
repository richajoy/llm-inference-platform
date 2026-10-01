###############################################################################
# RunPod Terraform Provider Configuration
# Provisions GPU pods on RunPod's serverless GPU cloud
###############################################################################

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    runpod = {
      source  = "runpod/runpod"
      version = "~> 1.3"
    }
  }
}

provider "runpod" {
  api_key = var.runpod_api_key
}
