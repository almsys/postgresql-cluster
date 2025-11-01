output "vm_ips" {
  description = "IP addresses of all created VMs"
  value = {
    node1  = "192.168.100.201"
    node2  = "192.168.100.202"
    node3  = "192.168.100.203"
  }
}

output "vm_ids" {
  description = "VM IDs of all created VMs"
  value = {
    node1    = 300
    node2    = 301
    node3    = 302
  }
}

output "ssh_commands" {
  description = "SSH connection commands"
  value = {
    node1  = "ssh admin@192.168.100.200"
    node2  = "ssh admin@192.168.100.201"
    node3  = "ssh admin@192.168.100.202"
  }
}

output "vm_roles" {
  description = "Roles and purposes of all created VMs"
  value = {
    node1    = "Primary PostgresSQL node"
    node2    = "Replica 2"
    node3    = "Replica 3"
  }
}

output "network_summary" {
  description = "Network configuration summary"
  value = {
    external_network = "10.0.10.0/24 (vmbr0)"
    internal_network = "192.168.100.0/24 (vmbr1)"
    dual_homed_vms   = "dns-server (192.168.100.53), cf-tunnel gateway (192.168.100.60)"
    internal_only_vms = "node1, node2, node3"
  }
}