terraform {
  required_version = ">= 1.9"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.117"
    }
  }

  # Local state for week 1. Week 2 moves this to an S3 backend on MinIO (see ROADMAP.md).
}

# Endpoint and token come from the environment (see .envrc.example), never from files in git:
#   PROXMOX_VE_ENDPOINT, PROXMOX_VE_API_TOKEN
provider "proxmox" {
  # Proxmox ships a self-signed cert. Week 7 replaces it and flips this to false.
  insecure = true
}
