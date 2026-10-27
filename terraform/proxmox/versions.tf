terraform {
  required_version = ">= 1.11" # S3 native locking (use_lockfile) is GA from 1.11

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.117"
    }
  }

  # State lives in bucket `tfstate` on SeaweedFS (sectools), ADR 0007. It holds cloud-init passwords,
  # so it travels over TLS only and the bucket is versioned. Keys: ~/.aws/credentials [homelab-tfstate].
  backend "s3" {
    bucket = "tfstate"
    key    = "proxmox/terraform.tfstate"
    region = "us-east-1" # the S3 client needs one; SeaweedFS ignores it

    endpoints        = { s3 = "https://s3.home.arpa" }
    profile          = "homelab-tfstate"
    custom_ca_bundle = "../../ansible/files/ca/sectools-caddy-root.crt" # Caddy local CA on sectools
    use_path_style   = true                                             # s3.home.arpa/tfstate/..., no wildcard DNS
    use_lockfile     = true                                             # lock = tfstate/<key>.tflock, If-None-Match write

    # Not AWS: there is no STS, account ID or region list to check.
    skip_credentials_validation = true
    skip_requesting_account_id  = true
    skip_region_validation      = true
    skip_metadata_api_check     = true
  }
}

# Endpoint and token come from the environment (see .envrc.example), never from files in git:
#   PROXMOX_VE_ENDPOINT, PROXMOX_VE_API_TOKEN
provider "proxmox" {
  # Proxmox ships a self-signed cert. Week 7 replaces it and flips this to false.
  insecure = true
}
