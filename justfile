set shell := ["/bin/bash", "-c"]

shebang := '/usr/bin/env bash
set -euxo pipefail
'

_default:
  @just --list
  echo "NOT CURRENTLY UPDATED, USE tofu AND ansible-playbook SEPARATELY!"

_python-venv:
  #!{{shebang}}
  if [[ -z "$VIRTUAL_ENV" ]]; then
    echo "You need to be in a virtual environment to do this operation"
    exit 1
  fi

# Setup a certain machine
[working-directory: 'ansible']
setup machine: _python-venv
  ansible-playbook --limit {{machine}} main.yaml

# Installs ansible, galaxy and required components
install-ansible: _python-venv
  #!{{shebang}}
  pip install -r requirements.txt
  ansible-galaxy collection install community.general
  ansible-galaxy install -r ansible/requirements.yaml

# Installs tofu
install-tofu install-method="deb":
  #!{{shebang}}
  curl --proto '=https' --tlsv1.2 -fsSL https://get.opentofu.org/install-opentofu.sh -o install-opentofu.sh
  chmod +x install-opentofu.sh
  ./install-opentofu.sh --install-method {{install-method}}
  rm -f install-opentofu.sh

# Sets up tofu user on Proxmox cluster
setup-tofu-user:
  ./tofu/scripts/init-terraform-user-proxmox.sh
