variable "name" {
  type = string
}

variable "vm_id" {
  type = number
}

variable "node_name" {
  type    = string
  default = "tuns"
}

variable "template_id" {
  description = "VMID of the cloud-init template to clone."
  type        = number
}

variable "tags" {
  type    = list(string)
  default = []
}

variable "cores" {
  type    = number
  default = 2
}

variable "memory_mb" {
  type    = number
  default = 4096
}

variable "disk_gb" {
  description = "Must be >= the template's disk size (40G)."
  type        = number
  default     = 40

  validation {
    condition     = var.disk_gb >= 40
    error_message = "Disk cannot be smaller than the 40G template disk."
  }
}

variable "datastore_id" {
  type    = string
  default = "local-lvm"
}

variable "bridge" {
  type    = string
  default = "vmbr0"
}

variable "ipv4_address" {
  type = string
}

variable "ipv4_prefix" {
  type    = number
  default = 24
}

variable "gateway" {
  type = string
}

variable "dns_servers" {
  type = list(string)
}

variable "ci_user" {
  type    = string
  default = "tunsadmin"
}

variable "ssh_public_keys" {
  type = list(string)
}
