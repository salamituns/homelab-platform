variable "template_id" {
  description = "Default cloud-init template (109 = Template, Ubuntu 24.04)."
  type        = number
  default     = 109
}

variable "debian_template_id" {
  description = "Debian 13 cloud-init template, built by scripts/build-debian-template.sh."
  type        = number
  default     = 130
}

variable "gateway" {
  type    = string
  default = "192.168.1.254"
}

variable "dns_servers" {
  type    = list(string)
  default = ["1.1.1.1", "8.8.8.8"]
}

variable "ssh_public_keys" {
  description = "Public keys injected via cloud-init for the tunsadmin user."
  type        = list(string)
}
