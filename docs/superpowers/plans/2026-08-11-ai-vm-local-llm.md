# AI VM Local LLM Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up a new `ai-vm` VM on the `workstation` Proxmox host that claims the full 24Q vGPU slice and runs Ollama (serving Qwen3.6-27B Q4 and Devstral-Small-2-24B Q4) plus the Hermes agentic-coding CLI wired to it.

**Architecture:** New tofu-provisioned VM (`ai-vm`, cloned from `ubuntu-2604-base`) added next to the existing `gaming` VM under `workstation.vms`, sharing the same `RTX-A5000` PCI mapping at `vgpu_slice_gb = 24`. A new `llm` ansible role installs Ollama + Hermes on it. The vGPU guest driver + nvlts licensing tasks currently duplicated-in-spirit are extracted from the `gaming` role into the shared `drivers` role first, so both `gaming` and `llm` consume the same code.

**Tech Stack:** OpenTofu (Proxmox provider), Ansible, Ollama, Hermes agent CLI (Nous Research), systemd.

## Global Constraints

- `ai-vm` and `gaming` are mutually exclusive on the GPU — only one may be running at a time (spec: "VM & GPU allocation"). No mdev reset is needed when switching; Proxmox tears the mdev down automatically on VM stop.
- `ai-vm` VM name must stay exactly `ai-vm` — matches `gpu-manager`'s existing example config (`config.example.yaml`) for future integration (spec: "Future gpu-manager integration").
- The `drivers`-role refactor must not change behavior for the existing `gaming` role (spec: "Driver refactor").
- Ollama binds all interfaces (`0.0.0.0:11434`), not just localhost (spec: "New ansible role: llm", item 5).
- Model tags (`qwen3.6:27b-q4_K_M`, `devstral-small2:24b-q4_K_M`) and the Hermes provider wiring are best-effort per the spec's "Open items" — verify against the live Ollama library / a real `hermes` run during Task 6, and adjust `llm_ollama_models` / the Hermes env vars in Task 4's files if the exact tags or config keys differ.

---

## Task 1: Move shared vGPU guest driver + licensing into the `drivers` role

**Files:**
- Move: `ansible/roles/gaming/tasks/nvidia-guest.yaml` → `ansible/roles/drivers/tasks/nvidia-guest.yaml`
- Move: `ansible/roles/gaming/tasks/nvlts-license.yaml` → `ansible/roles/drivers/tasks/nvlts-license.yaml`
- Move: `ansible/roles/gaming/files/nvlts` → `ansible/roles/drivers/files/nvlts`
- Move: `ansible/roles/gaming/templates/nvlts-generate-license.sh.j2` → `ansible/roles/drivers/templates/nvlts-generate-license.sh.j2`
- Move: `ansible/roles/gaming/templates/gridd-guest.conf.j2` → `ansible/roles/drivers/templates/gridd-guest.conf.j2`
- Modify: `ansible/roles/gaming/defaults/main.yaml` (remove the 7 vars listed below)
- Modify: `ansible/roles/drivers/defaults/main.yaml` (add the same 7 vars)
- Modify: `ansible/roles/gaming/tasks/main.yaml:78` (swap the include)
- Modify: `ansible/roles/drivers/handlers/main.yaml` (add the `Reboot for NVIDIA driver` handler)

**Interfaces:**
- Produces: `drivers` role task entry points `tasks_from: nvidia-guest` (installs the guest driver, then internally includes `nvlts-license.yaml` and notifies `Restart nvidia-gridd` / `Reboot for NVIDIA driver`) — Task 2's `llm` role consumes this exact `include_role` call.
- Produces: `drivers` role defaults `vgpu_product_name`, `vgpu_feature_name`, `vgpu_feature_version`, `vgpu_feature_type`, `nvlts_repo_url`, `nvlts_vendored_commit`, `nvlts_fallback_driver_version`.

- [x] **Step 1: Move the task files, keeping git history**

```bash
git mv ansible/roles/gaming/tasks/nvidia-guest.yaml ansible/roles/drivers/tasks/nvidia-guest.yaml
git mv ansible/roles/gaming/tasks/nvlts-license.yaml ansible/roles/drivers/tasks/nvlts-license.yaml
git mv ansible/roles/gaming/files/nvlts ansible/roles/drivers/files/nvlts
git mv ansible/roles/gaming/templates/nvlts-generate-license.sh.j2 ansible/roles/drivers/templates/nvlts-generate-license.sh.j2
git mv ansible/roles/gaming/templates/gridd-guest.conf.j2 ansible/roles/drivers/templates/gridd-guest.conf.j2
```

- [x] **Step 2: Update the "managed by" comments in the moved files to say `drivers` instead of `gaming`**

In `ansible/roles/drivers/templates/nvlts-generate-license.sh.j2`, change:
```
# Managed by Ansible (terranse gaming role) — DO NOT EDIT.
```
to:
```
# Managed by Ansible (terranse drivers role) — DO NOT EDIT.
```

In `ansible/roles/drivers/tasks/nvlts-license.yaml`, change the `content:` block's comment line:
```
      # Managed by Ansible (terranse gaming role)
```
to:
```
      # Managed by Ansible (terranse drivers role)
```

- [x] **Step 3: Move the vGPU-licensing vars from `gaming/defaults` to `drivers/defaults`**

Delete from `ansible/roles/gaming/defaults/main.yaml` (the block currently near the end of the file):
```yaml
nvlts_repo_url: https://git.collinwebdesigns.de/vgpu/nvlts
nvlts_vendored_commit: e639414
# Used only if the live driver version can't be read when the license is generated.
nvlts_fallback_driver_version: "595.58.03"
# License product/feature. Defaults match FeatureType 2 (RTX Virtual Workstation,
# e.g. the A5000 RTXA5000-8Q profile). For other profiles set these to the
# matching values (e.g. vPC: "NVIDIA Virtual PC" / "GRID-Virtual-PC" / "2.0").
vgpu_product_name: "NVIDIA RTX Virtual Workstation"
vgpu_feature_name: "Quadro-Virtual-DWS"
vgpu_feature_version: "5.0"

# vGPU FeatureType: 2 = RTX vWS (A5000 Q-series profile). 1 = vGPU/vPC, 4 = vCS.
vgpu_feature_type: 2
```

Keep the comment block above it that explains nvlts licensing is deleted along with the vars (it describes the vars, not gaming). Also remove the now-dangling comment line right above `nvlts_repo_url:` that starts with `# vGPU licensing via nvlts...` through `# The legacy FastAPI-DLS flow was removed...` — move that whole explanatory comment along with the vars in Step 4.

Append to `ansible/roles/drivers/defaults/main.yaml` (end of file):
```yaml

# vGPU licensing via nvlts (NVIDIA Local Trusted Store): forge a permanent
# node-locked license into the driver's local store — fully offline, no DLS
# server, no cert chain, no driver patching. This is the only supported method;
# it works on all vGPU branches incl. 20.x/595 (which FastAPI-DLS cannot license
# because the NLS root CA moved into unpatchable GSP firmware). The legacy
# FastAPI-DLS flow was removed — see git history if it's ever needed for < 20.x.
nvlts_repo_url: https://git.collinwebdesigns.de/vgpu/nvlts
nvlts_vendored_commit: e639414
# Used only if the live driver version can't be read when the license is generated.
nvlts_fallback_driver_version: "595.58.03"
# License product/feature. Defaults match FeatureType 2 (RTX Virtual Workstation,
# e.g. the A5000 RTXA5000-8Q/24Q profiles). For other profiles set these to the
# matching values (e.g. vPC: "NVIDIA Virtual PC" / "GRID-Virtual-PC" / "2.0").
vgpu_product_name: "NVIDIA RTX Virtual Workstation"
vgpu_feature_name: "Quadro-Virtual-DWS"
vgpu_feature_version: "5.0"

# vGPU FeatureType: 2 = RTX vWS (A5000 Q-series profile). 1 = vGPU/vPC, 4 = vCS.
vgpu_feature_type: 2
```

- [x] **Step 4: Point the `gaming` role at the moved tasks**

In `ansible/roles/gaming/tasks/main.yaml`, find:
```yaml
- name: Include NVIDIA vGPU guest driver setup
  ansible.builtin.include_tasks: nvidia-guest.yaml
  when: gpu_type == "nvidia_vgpu"
```
Replace with:
```yaml
- name: Include NVIDIA vGPU guest driver setup
  ansible.builtin.include_role:
    name: drivers
    tasks_from: nvidia-guest
  when: gpu_type == "nvidia_vgpu"
```

- [x] **Step 5: Add the guest-side reboot handler to the `drivers` role**

Append to `ansible/roles/drivers/handlers/main.yaml`:
```yaml

- name: Reboot for NVIDIA driver
  ansible.builtin.debug:
    msg: |
      NVIDIA driver installed. A reboot is recommended.
      Run: sudo reboot
```

- [x] **Step 6: Lint and syntax-check**

Run:
```bash
just lint
ansible-playbook --syntax-check ansible/playbooks/edholm.yaml
```
Expected: both succeed with no errors. (`just lint` runs yamllint + ansible-lint + tflint; the syntax-check confirms the `include_role` change and moved template/file paths resolve.)

- [x] **Step 7: Commit**

```bash
git add ansible/roles/gaming ansible/roles/drivers
git commit -m "refactor(ansible): move vGPU guest driver + nvlts licensing into drivers role

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

## Task 2: Scaffold the `llm` ansible role (base setup)

**Files:**
- Create: `ansible/roles/llm/defaults/main.yaml`
- Create: `ansible/roles/llm/tasks/main.yaml`
- Create: `ansible/roles/llm/handlers/main.yaml`

**Interfaces:**
- Consumes: `drivers` role `tasks_from: nvidia-guest` (Task 1).
- Produces: role variables `llm_user` (default `llm`), `llm_ollama_bind` (default `0.0.0.0:11434`), `llm_ollama_models` (list, default `["qwen3.6:27b-q4_K_M", "devstral-small2:24b-q4_K_M"]`), `llm_default_model` (default `llm_ollama_models[0]`) — consumed by Task 3 and Task 4.
- Produces: `ansible/roles/llm/tasks/main.yaml` includes `ollama.yaml` and `hermes.yaml` (Tasks 3 and 4 create those files) via relative `include_tasks`.

- [x] **Step 1: Create the role directories**

```bash
mkdir -p ansible/roles/llm/{defaults,tasks,handlers,templates}
```

- [x] **Step 2: Write the role defaults**

Create `ansible/roles/llm/defaults/main.yaml`:
```yaml
---
# Default variables for the llm role
#
# Deploys Ollama (serving local coding models) and the Hermes agent CLI on a
# VM holding the full 24Q vGPU slice. See docs/superpowers/specs/2026-08-11-ai-vm-local-llm-design.md.

# System user that owns the Hermes CLI and its config. Ollama runs as its own
# "ollama" user, created by the upstream install script.
llm_user: llm

gpu_type: nvidia_vgpu

# Bind all interfaces, not just localhost, so the OpenAI-compatible API is
# reachable over the LAN/Netbird for future clients, not only Hermes on-box.
llm_ollama_bind: "0.0.0.0:11434"

# Models to `ollama pull` on deploy. Verify these tags against the live Ollama
# library before relying on them — see the plan's Global Constraints.
llm_ollama_models:
  - "qwen3.6:27b-q4_K_M"
  - "devstral-small2:24b-q4_K_M"

# Model Hermes defaults to on first run.
llm_default_model: "{{ llm_ollama_models[0] }}"
```

- [x] **Step 3: Write the role's main task list**

Create `ansible/roles/llm/tasks/main.yaml`:
```yaml
---
# llm role - local LLM inference (Ollama) + Hermes agentic coding CLI
#
# Required variables:
#   gpu_type: "nvidia_vgpu" | "intel_sriov" | "none"
#
# Optional variables: see defaults/main.yaml

- name: Validate gpu_type variable
  ansible.builtin.assert:
    that:
      - gpu_type is defined
      - gpu_type in ['nvidia_vgpu', 'intel_sriov', 'none']
    fail_msg: "gpu_type must be one of: nvidia_vgpu, intel_sriov, none"

- name: Install base packages
  ansible.builtin.apt:
    name:
      - curl
      - git
      - htop
      - jq
      - build-essential
      - qemu-guest-agent
    state: present
    update_cache: true

- name: Ensure llm user exists
  ansible.builtin.user:
    name: "{{ llm_user }}"
    shell: /bin/bash
    groups: video,render
    append: true
    create_home: true

- name: Enable qemu-guest-agent
  ansible.builtin.systemd:
    name: qemu-guest-agent
    enabled: true
    state: started

- name: Install NVIDIA vGPU guest driver + licensing
  ansible.builtin.include_role:
    name: drivers
    tasks_from: nvidia-guest
  when: gpu_type == "nvidia_vgpu"

- name: Set up Ollama
  ansible.builtin.include_tasks: ollama.yaml

- name: Set up Hermes agent CLI
  ansible.builtin.include_tasks: hermes.yaml
```

- [x] **Step 4: Write the role's handlers**

Create `ansible/roles/llm/handlers/main.yaml`:
```yaml
---
# Handlers for the llm role

- name: Reload systemd
  ansible.builtin.systemd:
    daemon_reload: true

- name: Restart ollama
  ansible.builtin.systemd:
    name: ollama
    state: restarted
```

- [x] **Step 5: Lint (task/handler files reference `ollama.yaml`/`hermes.yaml`, which don't exist yet — syntax-check is deferred to Task 4)**

Run:
```bash
yamllint -c tests/static/.yamllint.yaml ansible/roles/llm/defaults/main.yaml ansible/roles/llm/tasks/main.yaml ansible/roles/llm/handlers/main.yaml
```
Expected: no errors (this only checks YAML syntax/style of the files that exist so far — full `ansible-lint`/`--syntax-check` runs at the end of Task 4, once `ollama.yaml` and `hermes.yaml` exist).

- [x] **Step 6: Commit**

```bash
git add ansible/roles/llm/defaults ansible/roles/llm/tasks/main.yaml ansible/roles/llm/handlers
git commit -m "feat(ansible): scaffold llm role base setup

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

## Task 3: Ollama install, systemd bind override, model pull

**Files:**
- Create: `ansible/roles/llm/tasks/ollama.yaml`
- Create: `ansible/roles/llm/templates/ollama-bind.conf.j2`

**Interfaces:**
- Consumes: `llm_ollama_bind`, `llm_ollama_models` (Task 2 defaults).
- Produces: running `ollama` systemd service bound to `llm_ollama_bind`, with every tag in `llm_ollama_models` pulled — consumed by Task 4 (Hermes points at `http://localhost:11434/v1`) and Task 6 (verification).

- [x] **Step 1: Write the systemd drop-in template**

Create `ansible/roles/llm/templates/ollama-bind.conf.j2`:
```jinja
# Managed by Ansible (terranse llm role) — DO NOT EDIT.
[Service]
Environment="OLLAMA_HOST={{ llm_ollama_bind }}"
```

- [x] **Step 2: Write the Ollama install/config/pull tasks**

Create `ansible/roles/llm/tasks/ollama.yaml`:
```yaml
---
# Ollama install, network bind, and model pull.
#
# The upstream installer (https://ollama.com/install.sh) creates the `ollama`
# system user, the systemd unit, and detects the NVIDIA GPU via nvidia-smi —
# so this must run after the vGPU guest driver task in main.yaml.

- name: Check whether Ollama is already installed
  ansible.builtin.command: ollama --version
  register: ollama_check
  changed_when: false
  failed_when: false

- name: Install Ollama
  ansible.builtin.shell: curl -fsSL https://ollama.com/install.sh | sh
  args:
    executable: /bin/bash
  when: ollama_check.rc != 0

- name: Ensure the ollama systemd drop-in directory exists
  ansible.builtin.file:
    path: /etc/systemd/system/ollama.service.d
    state: directory
    mode: '0755'

- name: Configure Ollama's network bind
  ansible.builtin.template:
    src: ollama-bind.conf.j2
    dest: /etc/systemd/system/ollama.service.d/bind.conf
    mode: '0644'
  notify:
    - Reload systemd
    - Restart ollama

- name: Enable and start Ollama
  ansible.builtin.systemd:
    name: ollama
    enabled: true
    state: started
    daemon_reload: true

- name: Flush handlers so the bind takes effect before pulling models
  ansible.builtin.meta: flush_handlers

- name: Pull configured models
  ansible.builtin.command: "ollama pull {{ item }}"
  loop: "{{ llm_ollama_models }}"
  register: ollama_pull
  changed_when: "'success' in ollama_pull.stdout | default('') | lower or 'up to date' not in ollama_pull.stdout | default('') | lower"
  async: 3600
  poll: 30
```

- [x] **Step 3: Lint**

Run:
```bash
yamllint -c tests/static/.yamllint.yaml ansible/roles/llm/tasks/ollama.yaml ansible/roles/llm/templates/ollama-bind.conf.j2
```
Expected: no errors.

- [x] **Step 4: Commit**

```bash
git add ansible/roles/llm/tasks/ollama.yaml ansible/roles/llm/templates/ollama-bind.conf.j2
git commit -m "feat(ansible): install and configure Ollama in the llm role

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

## Task 4: Hermes agent CLI install and provider wiring

**Files:**
- Create: `ansible/roles/llm/tasks/hermes.yaml`
- Create: `ansible/roles/llm/templates/hermes-llm.sh.j2`

**Interfaces:**
- Consumes: `llm_user` (Task 2), `llm_default_model` (Task 2), Ollama's OpenAI-compatible endpoint on `localhost:11434` (Task 3 — Hermes always talks to it over localhost regardless of `llm_ollama_bind`).
- Produces: `hermes` CLI on PATH for `llm_user`, environment-configured to use the local Ollama endpoint — consumed by Task 6's verification.

- [x] **Step 1: Write the environment drop-in template**

Hermes documents environment-variable configuration but its exact on-disk
config schema for custom OpenAI-compatible providers isn't published — per
the spec's "Open items", this is the best-effort wiring to verify in Task 6.

Create `ansible/roles/llm/templates/hermes-llm.sh.j2`:
```jinja
# Managed by Ansible (terranse llm role) — DO NOT EDIT.
#
# Points Hermes at the local Ollama OpenAI-compatible endpoint. Ollama needs
# no real API key; "ollama" is a non-empty placeholder since most
# OpenAI-compatible clients reject an empty one.
export OPENAI_BASE_URL="http://localhost:11434/v1"
export OPENAI_API_KEY="ollama"
export HERMES_MODEL="{{ llm_default_model }}"
```

- [x] **Step 2: Write the Hermes install/config tasks**

Create `ansible/roles/llm/tasks/hermes.yaml`:
```yaml
---
# Hermes agent CLI (https://github.com/NousResearch/hermes-agent) install and
# provider wiring. Installed per-user (bundles its own uv/Python 3.11/Node),
# so it runs as llm_user rather than system-wide.

- name: Check whether Hermes is already installed for the llm user
  ansible.builtin.command: bash -lc "command -v hermes"
  become: true
  become_user: "{{ llm_user }}"
  register: hermes_check
  changed_when: false
  failed_when: false

- name: Install Hermes agent CLI
  ansible.builtin.shell: curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash
  args:
    executable: /bin/bash
  become: true
  become_user: "{{ llm_user }}"
  when: hermes_check.rc != 0

- name: Deploy Hermes environment configuration
  ansible.builtin.template:
    src: hermes-llm.sh.j2
    dest: "/etc/profile.d/hermes-llm.sh"
    mode: '0644'

- name: Select the default Hermes model (best-effort; verify manually per plan Task 6)
  ansible.builtin.command: bash -lc "source /etc/profile.d/hermes-llm.sh && hermes model custom:{{ llm_default_model }}"
  become: true
  become_user: "{{ llm_user }}"
  changed_when: false
  failed_when: false
```

- [x] **Step 3: Full lint + syntax-check now that the role is complete**

Run:
```bash
just lint
ansible-playbook --syntax-check ansible/playbooks/edholm.yaml
```
Expected: both succeed with no errors.

- [x] **Step 4: Commit**

```bash
git add ansible/roles/llm/tasks/hermes.yaml ansible/roles/llm/templates/hermes-llm.sh.j2
git commit -m "feat(ansible): install and wire Hermes agent CLI in the llm role

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

## Task 5: Provision `ai-vm` in OpenTofu

**Files:**
- Modify: `tofu/deployments/edholm/configurations.tfvars` (inside the `workstation.vms` map, after the `gaming` entry, `configurations.tfvars:248`)

**Interfaces:**
- Consumes: `RTX-A5000` PCI mapping (existing), `llm` ansible role (Task 2-4), `ubuntu-2604-base` clone template (existing).
- Produces: tofu resource that creates VM `ai-vm` on `workstation` — consumed by Task 6's `tofu apply`.

- [x] **Step 1: Add the `ai-vm` block**

In `tofu/deployments/edholm/configurations.tfvars`, inside `workstation.vms`, change:
```hcl
    vms = {
      gaming = {
        ...
      }
    }
```
to:
```hcl
    vms = {
      gaming = {
        ...
      }

      ai-vm = {
        cores     = 8
        memory    = 32768
        disk_size = "150G"
        clone     = "ubuntu-2604-base"

        # Same full-24Q claim as `gaming`. The A5000 only allows one
        # homogeneous slice across the whole card, so ai-vm and gaming are
        # mutually exclusive — stop one before starting the other.
        pci_devices = [{
          mapping_id    = "RTX-A5000"
          vgpu_slice_gb = 24
          pcie          = true
          # primary_gpu (x-vga) MUST stay false — see the same note on the
          # gaming VM's pci_devices block above; a headless render node keeps
          # the emulated VGA as console.
          primary_gpu = false
          rombar      = false
        }]

        roles = [{
          name = "llm"
        }]
      }
    }
```
(leave the existing `gaming = { ... }` block exactly as-is; only add the new `ai-vm` entry alongside it).

- [x] **Step 2: Validate**

Run:
```bash
just validate-tofu
```
Expected: `Validating tofu/deployments/edholm/...` followed by `Success! The configuration is valid.` with no errors, for every deployment.

- [x] **Step 3: Plan (no apply yet — this is a dry run to confirm the resource graph)**

Run:
```bash
cd tofu/deployments/edholm && tofu plan -var-file=configurations.tfvars -out=/tmp/ai-vm-plan
```
Expected: plan shows exactly one new resource to add (the `ai-vm` VM under `module.proxmox-vm["workstation"]`), plus the two `local_file` resources (`ansible_playbook`, `ansible_inventory`) updating in-place to include it. No changes to the existing `gaming` VM.

- [x] **Step 4: Commit**

```bash
git add tofu/deployments/edholm/configurations.tfvars
git commit -m "feat(tofu): provision ai-vm with the full 24Q vGPU slice

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

## Task 6: Deploy and verify

This task makes real changes to the live `workstation` host: it stops the
running `gaming` VM (111) and creates/configures `ai-vm` in its place on the
GPU. Confirm with the user immediately before Step 1 if there is any chance
`gaming` is in active use.

**Files:** none (deployment + verification only).

**Interfaces:**
- Consumes: everything from Tasks 1-5.

- [x] **Step 1: Stop the gaming VM to free the GPU slice**

```bash
ssh root@workstation.netbird.cloud "qm shutdown 111"
```
Expected: command returns; then confirm it's fully stopped:
```bash
ssh root@workstation.netbird.cloud "qm status 111"
```
Expected: `status: stopped`.

- [x] **Step 2: Apply the tofu plan from Task 5**

```bash
cd tofu/deployments/edholm && tofu apply -auto-approve /tmp/ai-vm-plan
```
(If Task 5's plan file has gone stale — e.g. this runs in a new session — regenerate first with `tofu plan -var-file=configurations.tfvars -out=/tmp/ai-vm-plan` before applying.)
Expected: `Apply complete!` with 1 resource added, 2 changed (the regenerated `local_file`s), 0 destroyed.

- [x] **Step 3: Confirm the VM exists and is running**

```bash
ssh root@workstation.netbird.cloud "qm status \$(qm list | awk '/ai-vm/{print \$1}')"
```
Expected: `status: running`.

- [x] **Step 4: Run the ansible play against `ai-vm`**

```bash
just setup ai-vm
```
Expected: play completes with `failed=0`. (If the VM was just created and cloud-init hasn't finished registering DNS yet, wait ~30s and retry — `gaming.edholm.cc` needed the same settling time historically.)

- [x] **Step 5: Verify the vGPU is licensed inside the guest**

```bash
ssh ubuntu@ai-vm.edholm.cc "nvidia-smi -q | grep -A2 'License Status'"
```
Expected: `Licensed` (not `Unlicensed`).

- [x] **Step 6: Verify Ollama is serving both models**

```bash
ssh ubuntu@ai-vm.edholm.cc "ollama list"
curl -s http://ai-vm.edholm.cc:11434/v1/models | jq .
```
Expected: `ollama list` shows both `qwen3.6:27b-q4_K_M` and `devstral-small2:24b-q4_K_M`; the `curl` against the LAN-bound endpoint returns the same models over HTTP (confirms `OLLAMA_HOST=0.0.0.0:11434` took effect). If either model tag 404s on pull (per the Global Constraints caveat), check the live Ollama library for the current tag name, fix `llm_ollama_models` in `ansible/roles/llm/defaults/main.yaml`, and re-run `just setup ai-vm`.

- [x] **Step 7: Verify Hermes is installed and wired to the local endpoint**

```bash
ssh ubuntu@ai-vm.edholm.cc "sudo -u llm bash -lc 'hermes doctor'"
```
Expected: reports Hermes installed and able to reach a model provider. If it reports no provider configured, SSH in as the `llm` user and run `hermes setup` interactively once to confirm/finish the custom-endpoint wiring against `http://localhost:11434/v1`, then note the actual working config back into `ansible/roles/llm/templates/hermes-llm.sh.j2` / `tasks/hermes.yaml` so a fresh deploy doesn't need the manual step again.

- [x] **Step 8: Confirm `gaming` still comes back cleanly (mutual exclusivity check)**

```bash
ssh root@workstation.netbird.cloud "qm shutdown \$(qm list | awk '/ai-vm/{print \$1}')"
ssh root@workstation.netbird.cloud "qm start 111"
sleep 30
ssh root@workstation.netbird.cloud "qm status 111"
```
Expected: `status: running`, with no manual mdev intervention — confirming the spec's "no reset needed" claim under real conditions. Leave whichever VM (`gaming` or `ai-vm`) the user actually wants running right now as the final state.

- [x] **Step 9: Commit anything Step 7 changed**

```bash
git status
# if hermes.yaml / hermes-llm.sh.j2 changed:
git add ansible/roles/llm/tasks/hermes.yaml ansible/roles/llm/templates/hermes-llm.sh.j2
git commit -m "fix(ansible): correct Hermes provider wiring based on live verification

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

## Deployment notes (2026-08-11)

All six tasks are done and `ai-vm` (VMID 114, 192.168.1.37) is serving both
models on a licensed 24Q slice. Four things did not go as written:

1. **`devstral-small2:24b-q4_K_M` does not exist.** The real tag is
   `devstral:24b-small-2505-q4_K_M` — Devstral is published as `devstral`,
   with the release date in the tag rather than a "small 2" suffix. The
   `qwen3.6:27b-q4_K_M` guess was correct as written.

2. **tofu wanted to start `gaming` as part of this apply.** The provider
   defaults `vm_state` to `running`, so every plan tried to start each
   declared VM — including the one deliberately stopped to free the GPU.
   Applying as-planned would have started `gaming` *and* created `ai-vm`
   on the same 24Q profile. `vm_state` is now in the module's
   `ignore_changes`, so power state is operational, not declarative.

3. **The host play must run before the guest play.** The guest driver is
   read off the `nvidia-guest-drivers` virtiofs share, which the *host*
   play attaches via the `gpu-manager` role. Task 6 Step 4 runs only
   `just setup ai-vm`, so the share was absent, no driver was found, and
   Ollama's installer then apt-installed a stock `nvidia-driver` that
   refuses to probe a vGPU — leaving the guest with no GPU while the play
   still reported `failed=0`. The `llm` role now asserts a built guest
   driver before Ollama runs. Correct order is:
   `just setup workstation` → `just setup ai-vm` → reboot the guest.

4. **A new VM registers in DNS under `ubuntu`, not its own name.** The
   DHCP request races cloud-init's hostname rename, so the first lease is
   registered as `ubuntu.edholm.cc`. `/etc/hostname` persists correctly, so
   one reboot fixes it permanently. A `networkctl renew` does not — the
   binding is kept and the hostname is not re-sent.

5. **Hermes ignores `OPENAI_BASE_URL` / `OPENAI_API_KEY`.** It reads its
   provider from `~/.hermes/config.yaml`, so the templated `/etc/profile.d`
   env file left it on its default provider — `hermes -z` answered
   `HTTP 401: Missing Authentication header`. Exporting `OPENAI_API_KEY`
   globally was a hazard besides: that is the variable the `openrouter`
   provider keys off. The role now runs `hermes config set` for
   `model.provider` (`ollama`, an alias for `custom`), `model.base_url` and
   `model.default`, and the env file is removed. Verified: `hermes -z`
   returns correct code from the local model.

6. **The play was not idempotent.** `ollama pull` prints a success line
   whether or not it downloaded anything, so the plan's `changed_when`
   reported `changed` on every run and re-verified ~30GB of weights each
   time. It now asks `ollama list` what is missing. Two consecutive runs
   of `just setup ai-vm` now report `changed=0`.

Mutual exclusivity was verified live in both directions: stopping either VM
releases the mdev and the other starts cleanly with no manual reset. The
`error writing '0' to ... current_vgpu_type: Operation not permitted` printed
on shutdown is benign — the mdev is torn down by the VM stop regardless.
