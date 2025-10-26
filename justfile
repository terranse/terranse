set shell := ["/bin/bash", "-c"]

# Needs to be unstable in order to set the script-interpreter

set unstable := true
set script-interpreter := ['uv', 'run', '--script']

bash := '/usr/bin/env bash
set -euxo pipefail
'
domain := `grep -A 3 'variable "domain"' tofu/defaults.tf | grep 'default' | sed 's/.*"\(.*\)".*/\1/'`
vault-file := "secrets.yaml"

_default:
    @just --list

_python-venv:
    #!{{ bash }}
    if [[ -z "$VIRTUAL_ENV" ]]; then
      echo "You need to be in a virtual environment to do this operation"
      exit 1
    fi

[script]
_validate_flags *flags:
    import sys

    # Define allowed flags
    POSSIBLE_FLAGS = {"--debug", "--init"}

    # Parse flags from string
    flags_str = "{{ flags }}"
    opts = flags_str.split()

    # Validate each flag
    for opt in opts:
        if opt not in POSSIBLE_FLAGS:
            print(f"Error: Optional argument '{opt}' is not valid!", file=sys.stderr)
            sys.exit(1)

# Setup a certain machine, or default all, opt. with --debug or --init flags
[working-directory('ansible')]
setup machine="all" *flags: _python-venv (_validate_flags flags)
    ansible-playbook {{ if machine == "all" { "" } else if machine =~ '\.' { "--limit " + machine } else { "--limit " + machine + "." + domain } }} \
      playbook.yaml --extra-vars @./{{ vault-file }} \
      {{ if flags == "--init" { "-e 'ansible_user=root'" } else { "" } }} \
      {{ if flags == "--debug" { "-vvv" } else { "" } }}
    # TODO: Apply tags for debugging

# Setup each machine that has not already been initialized
[script]
[working-directory('ansible')]
init *flags: _python-venv (_validate_flags flags)
    from ansible.inventory.manager import InventoryManager
    from ansible.parsing.dataloader import DataLoader
    from sh import ssh, just

    # Load inventory using Ansible's Python API
    loader = DataLoader()
    inventory = InventoryManager(loader=loader, sources="inventory/terraform.yaml")

    for host in inventory.get_hosts():
        hostname = host.name
        ansible_host = host.vars.get('ansible_host', hostname)
        ansible_user = host.vars.get('ansible_user', 'default-user')

        print(f"Checking {hostname} ({ansible_host})...")

        # Try SSH with default user
        try:
            ssh(
                f"{ansible_user}@{ansible_host}",
                "ls",
                _timeout=3,
                _out=None  # Suppress output
            )
            print(f"  ✓ Already setup (connected as {ansible_user})")
            continue

        except (sh.TimeoutException, sh.ErrorReturnCode):
            print(f"  → Default user failed, trying root...")

            try:
                sh.ssh(
                    f"root@{ansible_host}",
                    "ls",
                    _timeout=3,
                    _out=None
                )
                print(f"  ⚙  Provisioned but not setup, running setup...")
                sh.just("setup", hostname, _fg=True)  # Run in foreground

            except (sh.TimeoutException, sh.ErrorReturnCode) as e:
                print(f"  ✗ Cannot connect with root either: {e}")


# Setup a ansible-vault with become secrets
[working-directory('ansible')]
setup-secrets vault-item='infra_default_user': _python-venv
    op item get {{ vault-item }} --reveal --fields password | \ 
    ansible-vault encrypt_string --stdin-name 'ansible_become_pass' --output {{ vault-file }} --vault-password-file getVaultPass.sh

# Plan and auto apply tofu config; deployment saved to ./tfplan
[working-directory('tofu')]
apply-tofu *flags: _python-venv (_validate_flags flags)
    tofu plan -var-file=configurations.tfvars -out=tfplan {{ if flags == "--debug" { "-var='debug_ansible=true'" } else { "" } }}
    tofu apply -auto-approve tfplan

# Installs ansible, galaxy and required components
install-ansible: _python-venv
    uv add -r requirements.txt
    ansible-galaxy collection install --upgrade community.general community.docker community.proxmox
    ansible-galaxy install -r ansible/requirements.yaml

# Installs tofu
install-tofu install-method="deb":
    curl --proto '=https' --tlsv1.2 -fsSL https://get.opentofu.org/install-opentofu.sh -o install-opentofu.sh
    chmod +x install-opentofu.sh
    ./install-opentofu.sh --install-method {{ install-method }}
    rm -f install-opentofu.sh

# Sets up tofu user on Proxmox cluster
setup-tofu-user:
    ./tofu/scripts/init-terraform-user-proxmox.sh
