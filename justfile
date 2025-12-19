set shell := ["/bin/bash", "-c"]

# Needs to be unstable in order to set the script-interpreter

set unstable := true
set script-interpreter := ['uv', 'run', '--script']

bash := '/usr/bin/env bash
set -euxo pipefail
'
domain := `grep -A 3 'variable "domain"' tofu/deployments/edholm/defaults.tf 2>/dev/null | grep 'default' | sed 's/.*"\(.*\)".*/\1/' || echo "edholm.cc"`
vault-file := "secrets.yaml"

_default:
    @just --list

_python-venv:
    #!{{ bash }}
    if [[ -z "$VIRTUAL_ENV" ]]; then
      echo "You need to be in a virtual environment to do this operation"
      exit 1
    fi

# Setup a machine with Ansible. Use init=true for first-time setup, debug=true for verbose output
[working-directory('ansible')]
setup machine="all" init="false" debug="false": _python-venv
    ansible-playbook {{ if machine == "all" { "" } else if machine =~ '\.' { "--limit " + machine } else { "--limit " + machine + "." + domain } }} \
      playbook.yaml --extra-vars @./{{ vault-file }} \
      {{ if init == "true" { "-e 'ansible_user=root'" } else { "" } }} \
      {{ if debug == "true" { "-vvv" } else { "" } }}

# Auto-discover and setup uninitialized machines
[script]
[working-directory('ansible')]
init-machines: _python-venv
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
                sh.just("setup", hostname, "init=true", _fg=True)

            except (sh.TimeoutException, sh.ErrorReturnCode) as e:
                print(f"  ✗ Cannot connect with root either: {e}")


# Setup a ansible-vault with become secrets
[working-directory('ansible')]
setup-secrets vault-item='infra_default_user': _python-venv
    op item get {{ vault-item }} --reveal --fields password | \ 
    ansible-vault encrypt_string --stdin-name 'ansible_become_pass' --output {{ vault-file }} --vault-password-file getVaultPass.sh

# Plan and auto apply tofu config for a deployment
[working-directory('tofu/deployments')]
apply-tofu deployment="edholm" debug="false": _python-venv
    cd {{ deployment }} && \
    tofu plan -var-file=configurations.tfvars -out=tfplan {{ if debug == "true" { "-var='debug_ansible=true'" } else { "" } }} && \
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

# ============== TESTING TASKS ==============

# Run all static analysis checks
lint: _python-venv
    yamllint -c tests/static/.yamllint.yaml ansible/
    ansible-lint -c tests/static/.ansible-lint ansible/
    cd tofu && tflint --config ../tests/static/.tflint.hcl --recursive

# Run OpenTofu validation for all deployments
validate-tofu:
    @for deployment in tofu/deployments/*/; do \
        echo "Validating $$deployment..."; \
        (cd "$$deployment" && tofu init -backend=false -input=false >/dev/null && tofu validate) || exit 1; \
    done

# Run unit tests (fast, no VMs)
test-unit: _python-venv
    uv run pytest tests/unit/ -v --tb=short

# Run Molecule tests for a specific role (supports nested roles like proxmox/lxc)
[working-directory('ansible/roles')]
test-role role scenario="default": _python-venv
    cd {{ role }} && molecule test -s {{ scenario }}

# List available Molecule scenarios for a role
[working-directory('ansible/roles')]
test-role-list role:
    @ls -1 {{ role }}/molecule/ 2>/dev/null || echo "No molecule scenarios found for {{ role }}"

# Pre-cache Vagrant boxes for offline testing
cache-boxes:
    vagrant box add debian/bookworm64 --provider libvirt || true

# Run full test suite (lint + unit + validation)
test-all: lint validate-tofu test-unit
    @echo "All tests passed!"

# Quick test run (lint + unit only, no VMs)
test-quick: lint test-unit
    @echo "Quick tests passed!"

# Cleanup test artifacts
test-clean:
    @echo "Cleaning up test artifacts..."
    find . -name "*.pyc" -delete 2>/dev/null || true
    find . -name "__pycache__" -type d -delete 2>/dev/null || true
    find . -name ".molecule" -type d -exec rm -rf {} + 2>/dev/null || true
    find . -name ".pytest_cache" -type d -exec rm -rf {} + 2>/dev/null || true

# Install test dependencies
install-test: _python-venv
    uv pip install -e ".[test]"
