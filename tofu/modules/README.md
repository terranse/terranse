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

3. **Wire the module into the deployment's `ansible-wiring` call**

   Each deployment (e.g. `tofu/deployments/edholm/main.tf`) uses the shared
   `ansible-wiring` module to generate playbooks and inventory. Add your new
   module's `ansible_plays` output to the `ansible_plays` input of
   `module "ansible-wiring"`:

   ```hcl
   module "ansible-wiring" {
     ...
     ansible_plays = flatten(concat(
       [for instance in module.proxmox-lxc : instance.ansible_plays],
       [for instance in module.proxmox-vm  : instance.ansible_plays],
       [for instance in module.your-module : instance.ansible_plays],
     ))
   }
   ```
