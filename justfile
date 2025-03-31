set shell := ["/bin/bash", "-c"]

shebang := '/usr/bin/env bash
set -euxo pipefail
'

_default:
  @just --list

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

# Installs tofu
install-tofu:
  #!{{shebang}}
  curl --proto '=https' --tlsv1.2 -fsSL https://get.opentofu.org/install-opentofu.sh -o install-opentofu.sh
  chmod +x install-opentofu.sh
  ./install-opentofu.sh --install-method deb
  rm -f install-opentofu.sh
