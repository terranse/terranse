# Adding a New Module

To add a new module:

1. **Expose a `configuration` variable**  
   Define a variable named `configuration` as a map of objects. The object
   structure should match the interface used by other modules, for example:

   ```hcl
   variable "configuration" {
     description = "Map of LXC configurations"
     type = map(object({
       memory          = optional(number, 2048)
       cores           = optional(number, 2)
       disk_size       = optional(string, "8GB")
       vmid            = optional(number)
       mounts          = optional(map(object({
         zfs_dataset   = string
         ct_mountpoint = string
       })), {})
       roles           = optional(list(string), [])
       services        = optional(list(string), [])
       docker_services = optional(list(string), [])
     }))
   }
   ```

2. **Provide an `ansible_plays` output**  
   Add an output named `ansible_plays` with the following structure:

   ```hcl
   output "ansible_plays" {
     value = [
       for host_name, host_config in var.configuration : {
         name  = "Configuration of ${host_name}"
         hosts = host_name
         roles = concat(["proxmox/lxc"], try(host_config.roles, []))
         vars  = try(host_config.ansible_vars, {})
       }
     ]
   }
   ```

   Match the variable interface and output format to ensure compatibility with
   other modules.

3. **Add an entry to the `all_plays` and `all_ansible_inventory` locals in
`tofu/ansible.tf`**  

   There is currently no way just collect all modules from a certain directory,
   and as such they will need to added explicitly for each output produced.
