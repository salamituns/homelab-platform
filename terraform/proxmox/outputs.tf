output "vms" {
  description = "name => IP, consumed by the Ansible inventory."
  value       = { for k, m in module.vm : k => m.ipv4_address }
}
