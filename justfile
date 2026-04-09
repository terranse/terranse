set shell := ["/bin/bash", "-c"]

# Needs to be unstable in order to set the script-interpreter

set unstable := true
set script-interpreter := ['uv', 'run', '--script']

bash := '/usr/bin/env bash
set -euxo pipefail
'
domain := `grep -A 3 'variable "domain"' tofu/deployments/edholm/defaults.tf 2>/dev/null | grep 'default' | sed 's/.*"\(.*\)".*/\1/' || echo "edholm.cc"`
default_node := "jupiter"
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

# Installs packer
install-packer:
    curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
    sudo apt-get update && sudo apt-get install -y packer

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

# Test all docker service scenarios (default, serverarr, vikunja, authentik)
[working-directory('ansible/roles/docker')]
test-docker-all: _python-venv
    #!/usr/bin/env bash
    set -e
    for scenario in $(ls molecule/); do
        if [[ "$scenario" != "vagrant" ]]; then
            echo "=== Testing scenario: $scenario ==="
            molecule test -s "$scenario"
        fi
    done
    echo "All docker scenarios passed!"

# Pre-cache Vagrant boxes for offline testing
cache-boxes:
    vagrant box add debian/bookworm64 --provider libvirt || true

# Run full test suite (lint + unit + validation)
test-all: lint validate-tofu test-unit
    @echo "All tests passed!"

# Quick test run (lint + unit only, no VMs)
test-quick: lint test-unit
    @echo "Quick tests passed!"

# Run docker molecule tests (quick sanity check with default scenario)
test-docker: _python-venv
    just test-role docker default

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

# ============== PACKER / VM TEMPLATES ==============

# Build a VM template on a deployment's Proxmox node.
# Linux: imports a cloud image directly (fast, no installer).
# Windows: runs Packer with ISO + autounattend (via SSH on the node).
# Target is "deployment" or "node.deployment" (defaults to first host in config).
[script]
build-template target os_family="ubuntu" os_version="2510" variant="base": _python-venv
    import re, sys, shlex, tempfile
    from pathlib import Path
    from sh import ssh, scp, ErrorReturnCode

    # Parse target: "node.deployment" or just "deployment"
    target = "{{ target }}"
    parts = target.split(".", 1)
    node_override, deployment = (parts[0], parts[1]) if len(parts) == 2 else (None, parts[0])

    deploy_dir = Path("tofu/deployments") / deployment
    if not deploy_dir.is_dir():
        available = sorted(p.name for p in Path("tofu/deployments").iterdir() if p.is_dir())
        sys.exit(f"Unknown deployment '{deployment}'. Available: {', '.join(available)}")

    # Derive node from config (host key or proxmox_node override)
    config = (deploy_dir / "configurations.tfvars").read_text()
    if node_override:
        host_key = node_override
    else:
        m = re.search(r'^\s*"([^"]+)"\s*=\s*\{', config, re.MULTILINE)
        if not m:
            sys.exit(f"No host found in {deploy_dir}/configurations.tfvars")
        host_key = m.group(1)

    # host_key = SSH hostname, pve_node = Proxmox node name for API calls
    host_pattern = r'"' + re.escape(host_key) + r'"\s*=\s*\{([\s\S]*?\n\s*\})'
    host_block = re.search(host_pattern, config)
    pve_node_match = re.search(r'proxmox_node\s*=\s*"([^"]+)"', host_block.group(1)) if host_block else None
    pve_node = pve_node_match.group(1) if pve_node_match else host_key
    storage_match = re.search(r'storage_pool\s*=\s*"([^"]+)"', host_block.group(1)) if host_block else None
    storage_pool = storage_match.group(1) if storage_match else "local-lvm"

    # Load OS catalog
    import hcl2
    with open("packer/os-catalog.pkrvars.hcl") as f:
        catalog_raw = hcl2.load(f)
    os_key = f"{{ os_family }}-{{ os_version }}"
    catalog = catalog_raw["os_catalog"]
    os_entry = catalog.get(os_key)
    if not os_entry:
        sys.exit(f"OS '{os_key}' not found in os-catalog.pkrvars.hcl. Available: {', '.join(catalog.keys())}")

    template_name = "{{ os_family }}-{{ os_version }}-{{ variant }}"
    cloud_img_url = os_entry.get("cloud_img_url", "")

    if cloud_img_url:
        # ── Linux: import cloud image as Proxmox template ──
        cloud_img_checksum = os_entry.get("cloud_img_checksum", "")
        os_type = os_entry.get("os_type", "l26")

        print(f"Building {template_name} on {host_key} (node={pve_node}, storage={storage_pool}) via cloud image")

        # Build checksum verification command
        checksum_cmd = "true"
        if cloud_img_checksum:
            algo, digest = cloud_img_checksum.split(":", 1)
            checksum_cmd = f'echo "{digest}  $IMG_FILE" | {algo}sum -c'

        # Build template creation script
        lines = [
            "#!/bin/bash",
            "set -euxo pipefail",
            "",
            f'TEMPLATE_NAME="{template_name}"',
            f'STORAGE="{storage_pool}"',
            f'OS_TYPE="{os_type}"',
            "",
            "# Remove existing template with same name",
            "EXISTING=$(qm list | grep -w \"$TEMPLATE_NAME\" | awk '{print $1}' || true)",
            'if [ -n "$EXISTING" ]; then',
            '    echo "Replacing existing template $TEMPLATE_NAME (VMID: $EXISTING)"',
            '    qm destroy "$EXISTING" --purge',
            "fi",
            "",
            "VMID=$(pvesh get /cluster/nextid)",
            'echo "Creating template $TEMPLATE_NAME (VMID: $VMID)"',
            "",
            "# Download cloud image",
            'IMG_FILE="/tmp/$TEMPLATE_NAME.img"',
            f'wget -q --show-progress -O "$IMG_FILE" "{cloud_img_url}"',
            checksum_cmd,
            "",
            "# Create VM",
            'qm create "$VMID" \\',
            '    --name "$TEMPLATE_NAME" \\',
            "    --memory 2048 \\",
            "    --cores 2 \\",
            "    --cpu host \\",
            "    --net0 virtio,bridge=vmbr0 \\",
            "    --bios ovmf \\",
            "    --machine q35 \\",
            "    --agent enabled=1 \\",
            '    --ostype "$OS_TYPE" \\',
            "    --scsihw virtio-scsi-pci",
            "",
            "# EFI disk",
            'qm set "$VMID" --efidisk0 "$STORAGE:0,efitype=4m,pre-enrolled-keys=0"',
            "",
            "# Import cloud image as disk and attach",
            'qm importdisk "$VMID" "$IMG_FILE" "$STORAGE"',
            'DISK=$(qm config "$VMID" | awk \'/^unused0/{print $2}\')',
            'qm set "$VMID" --scsi0 "$DISK"',
            "",
            "# Cloud-init drive and boot order",
            'qm set "$VMID" --ide2 "$STORAGE:cloudinit"',
            'qm set "$VMID" --boot order=scsi0',
            "",
            "# Convert to template",
            'qm template "$VMID"',
            'rm -f "$IMG_FILE"',
            "",
            'echo "Template $TEMPLATE_NAME created (VMID: $VMID)"',
        ]

        script = tempfile.NamedTemporaryFile(mode="w", suffix=".sh", delete=False)
        script.write("\n".join(lines) + "\n")
        script.close()
        scp(script.name, f"root@{host_key}:/tmp/build-template.sh")
        Path(script.name).unlink()
        try:
            ssh(f"root@{host_key}", "bash", "/tmp/build-template.sh", _fg=True)
        except ErrorReturnCode:
            sys.exit(1)

    else:
        # ── Windows: Packer ISO build ──
        from sh import op, rsync

        template_dir = Path("packer") / f"{{ os_family }}-{{ variant }}"
        if not template_dir.is_dir():
            available = sorted(p.name for p in Path("packer").iterdir() if p.is_dir() and "-" in p.name)
            sys.exit(f"No template directory '{template_dir}'. Available: {', '.join(available)}")

        # Derive 1Password item from deployment's secrets.tf
        secrets = (deploy_dir / "secrets.tf").read_text()
        m = re.search(r'item\s*=\s*"([^"]+)"', secrets)
        if not m:
            sys.exit(f"No 1Password item found in {deploy_dir}/secrets.tf")
        op_item = m.group(1)

        print(f"Building {template_name} on {host_key} (node={pve_node}, storage={storage_pool}, {deployment}) via Packer")

        def op_get(field):
            try:
                return op("item", "get", op_item, "--fields", field, "--reveal").strip()
            except ErrorReturnCode as e:
                sys.exit(f"Failed to get '{field}' from 1Password item '{op_item}': {e.stderr.strip()}")

        proxmox_url = "https://127.0.0.1:8006/api2/json"
        proxmox_username = op_get("terraform-token-id")
        proxmox_token = op_get("terraform-api-key")

        # Template-specific credentials from a 1Password item named after the
        # template (e.g. "windows-11-base"). The Packer HCL reads these via
        # sensitive variables and templatefile()s them into autounattend.xml.
        def op_template_field(field):
            try:
                return op("item", "get", template_name, "--vault", "IPID",
                          "--fields", field, "--reveal").strip()
            except ErrorReturnCode as e:
                sys.exit(f"Failed to get '{field}' from 1Password item '{template_name}' in IPID: {e.stderr.strip()}")
        winrm_username = op_template_field("username")
        winrm_password = op_template_field("password")

        # Upload ISO if needed
        iso_url = os_entry.get("iso_url", "")
        iso_checksum = os_entry.get("iso_checksum", "")
        iso_filename = None
        if iso_url:
            iso_filename = iso_url.rsplit("/", 1)[-1]
            remote_iso = f"/var/lib/vz/template/iso/{iso_filename}"
            try:
                ssh(f"root@{host_key}", f"test -f {remote_iso}")
                print(f"ISO already on {host_key}")
            except ErrorReturnCode:
                print(f"Downloading {iso_filename} on {host_key}...")
                ssh(f"root@{host_key}", f"wget -q --show-progress -O {remote_iso} {shlex.quote(iso_url)}", _fg=True)
                if iso_checksum.startswith("sha256:"):
                    expected = iso_checksum.split(":", 1)[1]
                    actual = ssh(f"root@{host_key}", f"sha256sum {remote_iso}").strip().split()[0]
                    if actual != expected:
                        ssh(f"root@{host_key}", f"rm -f {remote_iso}")
                        sys.exit(f"Checksum mismatch: expected {expected}, got {actual}")
                    print("Checksum verified.")

        # Ensure VirtIO ISO is on the node (no SHA256 available, skip checksum)
        virtio_url = "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"
        virtio_remote = "/var/lib/vz/template/iso/virtio-win.iso"
        try:
            ssh(f"root@{host_key}", f"test -f {virtio_remote}")
            print("VirtIO ISO already on node")
        except ErrorReturnCode:
            print("Downloading VirtIO ISO on node...")
            ssh(f"root@{host_key}", f"wget -q --show-progress -O {virtio_remote} {shlex.quote(virtio_url)}", _fg=True)

        # Ensure Packer is installed on the node
        try:
            ssh(f"root@{host_key}", "packer version")
        except ErrorReturnCode:
            print("Installing Packer on node...")
            script = tempfile.NamedTemporaryFile(mode="w", suffix=".sh", delete=False)
            script.write("#!/bin/bash\nset -euxo pipefail\n")
            script.write("curl -fsSL https://apt.releases.hashicorp.com/gpg | gpg --batch --yes --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg\n")
            script.write('echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(. /etc/os-release && echo $VERSION_CODENAME) main" > /etc/apt/sources.list.d/hashicorp.list\n')
            script.write("apt-get update && apt-get install -y packer\n")
            script.close()
            scp(script.name, f"root@{host_key}:/tmp/install-packer.sh")
            Path(script.name).unlink()
            ssh(f"root@{host_key}", "bash", "/tmp/install-packer.sh", _fg=True)

        # Sync packer directory and build remotely
        remote_packer = "/root/packer"
        rsync("-a", "--delete",
            "--exclude=downloaded_iso_path/",
            "--exclude=.packer.d/",
            "packer/",
            f"root@{host_key}:{remote_packer}/",
            _fg=True,
        )

        remote_template = f"{remote_packer}/{{ os_family }}-{{ variant }}"
        import json
        iso_override = []
        if iso_filename:
            overridden = {**catalog, os_key: {**os_entry, "iso_url": "", "iso_checksum": "", "iso_file": f"local:iso/{iso_filename}"}}
            iso_override = [f"-var=os_catalog={shlex.quote(json.dumps(overridden))}"]

        build_cmd = " ".join([
            f"cd {shlex.quote(remote_template)}",
            "&& packer init .",
            "&& packer build",
            "-var-file=../os-catalog.pkrvars.hcl",
            *iso_override,
            # Force VirtIO to use pre-uploaded iso_file (catalog has placeholder checksum)
            "-var=virtio_iso_url=", "-var=virtio_iso_checksum=",
            f"-var={shlex.quote(f'proxmox_url={proxmox_url}')}",
            f"-var={shlex.quote(f'proxmox_username={proxmox_username}')}",
            f"-var={shlex.quote(f'proxmox_token={proxmox_token}')}",
            f"-var={shlex.quote(f'proxmox_node={pve_node}')}",
            f"-var={shlex.quote(f'storage_pool={storage_pool}')}",
            f"-var={shlex.quote(f'winrm_username={winrm_username}')}",
            f"-var={shlex.quote(f'winrm_password={winrm_password}')}",
            "-var=os_family={{ os_family }}",
            "-var=os_version={{ os_version }}",
            ".",
        ])

        try:
            ssh(f"root@{host_key}", "bash", "-c", shlex.quote(build_cmd), _fg=True)
        except ErrorReturnCode:
            sys.exit(1)

# Upload an ISO to Proxmox (for Windows or other non-downloadable ISOs)
upload-iso path node=default_node:
    #!/usr/bin/env bash
    set -euxo pipefail
    filename=$(basename "{{ path }}")
    echo "Uploading $filename to {{ node }}..."
    scp "{{ path }}" root@{{ node }}:/var/lib/vz/template/iso/
    echo "Uploaded. Available as local:iso/$filename"
    ssh root@{{ node }} "test -f /var/lib/vz/template/iso/$filename" && echo "Verified on {{ node }}"

# Quick-create a VM from an existing template (no tofu)
create-vm name template="debian-13-base" cores="2" memory="2048" disk="32G" node=default_node:
    #!/usr/bin/env bash
    set -euxo pipefail
    TEMPLATE_VMID=$(ssh root@{{ node }} "qm list" | grep -w "{{ template }}" | awk '{print $1}' | head -1)
    if [ -z "$TEMPLATE_VMID" ]; then
      echo "Template '{{ template }}' not found on {{ node }}. Run 'just build-template' first."
      exit 1
    fi
    # Clone, configure, and start in minimal SSH round-trips
    NEXT_VMID=$(ssh root@{{ node }} "pvesh get /cluster/nextid")
    ssh root@{{ node }} "qm clone $TEMPLATE_VMID $NEXT_VMID --name {{ name }} --full && \
      qm set $NEXT_VMID --cores {{ cores }} --memory {{ memory }} && \
      qm resize $NEXT_VMID scsi0 {{ disk }}"
    # Inject SSH key if available
    if [ -f ~/.ssh/id_ed25519.pub ]; then
      ssh root@{{ node }} "qm set $NEXT_VMID --sshkeys /dev/stdin" < ~/.ssh/id_ed25519.pub
    fi
    ssh root@{{ node }} "qm start $NEXT_VMID"
    echo "VM '{{ name }}' (VMID: $NEXT_VMID) created and started from '{{ template }}'"

# Destroy a test VM
destroy-vm vmid node=default_node:
    #!/usr/bin/env bash
    set -euo pipefail
    ssh root@{{ node }} "qm stop {{ vmid }} --skiplock 2>/dev/null || true; qm destroy {{ vmid }}"

# List available templates on Proxmox
list-templates node=default_node:
    ssh root@{{ node }} "qm list" | awk 'NR==1 || /template|base|gaming/i' || echo "No templates found"
