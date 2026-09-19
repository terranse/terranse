# NInfer Inference Backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `ai-vm` able to serve local inference through either Ollama (today) or NInfer (a native SM86 CUDA engine claiming ~2x decode throughput), selectable with one tfvars variable, and measure the difference on real hardware before committing to either.

**Architecture:** Extend the existing `llm` ansible role rather than adding a new one — both backends serve the same OpenAI-compatible API to the same clients, so they are two implementations of one role responsibility, not two roles. A new `llm_backend` variable (`ollama` | `ninfer`) decides which systemd unit is enabled at boot and where Hermes points; the other backend stays installed but stopped, so A/B testing is a variable flip plus a re-run, not a rebuild. NInfer runs as a container built on-box from a pinned upstream ref, which also brings Docker + the NVIDIA Container Toolkit to `ai-vm` — prerequisites the planned Open WebUI / ComfyUI work needs regardless of which backend wins.

**Tech Stack:** OpenTofu (Proxmox provider), Ansible, Ollama, NInfer (C++20/CUDA, Apache-2.0), Docker + NVIDIA Container Toolkit, Hermes agent CLI, systemd.

**Spec:** This plan is self-specifying — the design rationale and the upstream research it rests on are in "Design basis" below. There is no separate spec doc; the ai-vm design doc it builds on is `docs/superpowers/specs/2026-08-11-ai-vm-local-llm-design.md`.

---

## Design basis

Verified against upstream on 2026-08-19, before writing this plan:

| Question | Finding | Source |
|---|---|---|
| Will NInfer run on an A5000 at all? | Yes. A5000 is GA102 / compute capability **8.6**, identical to the 3090. `CMakeLists.txt:6-13` defaults `CMAKE_CUDA_ARCHITECTURES` to `86` and accepts only `86` or `89`. | repo |
| Is there device gating that would reject a non-3090? | **No.** `src/core/device.cu` reads `cudaGetDeviceProperties` and derives `sm()` from `major*10+minor`; there is no check on device name or PCI ID anywhere in the file. The README's "requires an RTX 3090" is a support statement, not an enforced one. | repo |
| Does it fit the 24Q slice? | C1 (single user) peaks at **19,641 MiB**. C8 peaks at 22,138–23,207 MiB. C1 fits with room; C8 does not, if ECC reduces the guest framebuffer. **Use C1.** | README perf tables |
| What speed should we actually expect? | Their 70.19 tok/s is on a 3090. Decode is bandwidth-bound: A5000 768 GB/s vs 3090 936 GB/s = 0.82 → **~57 tok/s**. Prefill is compute-bound: 27.8 vs 35.6 TFLOPS = 0.78 → **~670 tok/s**. Arithmetic, not measurement. | derived |
| Pinned upstream ref | Default branch `release/v0.6.0-rtx3090`, commit **`403fc56d71576aa1feddb771cfed3264e7378b20`** (2026-08-18). | GitHub API |
| Model artifact | `qwen3_8_27b.ninfer`, **18,210,531,328 bytes** (16.96 GiB), SHA256 **`eec39564993d6e9c7d5e383382a760f093465c9d163ec9a1bd6b80199514bf3e`**. | HuggingFace `x-linked-size` / `x-linked-etag` |
| Does Ollama carry Qwen3.8-27B, so both backends can serve the *same* model? | **Yes.** `qwen3.8:27b-q4_K_M` and `qwen3.8:27b-mtp-q4_K_M` both exist at 18GB. This makes Task 7 an engine-only comparison rather than a confounded engine+model one. The other mtp variants (`q8_0` 30GB, `bf16` 56GB) are too large for the slice. | ollama.com/library/qwen3.8/tags |

**Known risks, stated up front:**

- Nobody has run NInfer on a vGPU-sliced GPU. Q-profiles support CUDA and CUDA Graphs and the full card's bandwidth is available (nothing else shares it), but this is unproven until Task 3.
- Upstream's v0.6.0 validation gate was **Windows**. The Linux doc says plainly: "A successful compile does not qualify Linux performance."
- NInfer's vision is image *understanding*, not generation. ComfyUI + Flux remains separately needed.

---

## Global Constraints

- Role variables passed from tfvars are **strings only** — `tofu/modules/proxmox-vm/variables.tf:79` declares `vars = optional(map(string), {})`. Booleans must be written `"true"` / `"false"`, matching the existing `sunshine_enabled = "true"` pattern in `configurations.tfvars`.
- `ai-vm` and `gaming` are mutually exclusive on the GPU — only one may run at a time. Do not start `gaming` while testing.
- **Never bypass the guest-driver assert** in `ansible/roles/llm/tasks/main.yaml:63-73`. It exists because Ollama's installer apt-installs a stock driver that cannot drive a vGPU, while the play still reports success.
- Ollama and NInfer must **never both hold VRAM**. Enforced by `Conflicts=` in the systemd unit plus `llm_backend` gating which unit is enabled.
- Everything binds `0.0.0.0`, not localhost, so exposing over ipid later needs no change.
- Hermes is configured with `hermes config set`, **never** via `OPENAI_BASE_URL` / `OPENAI_API_KEY` env vars — it reads `~/.hermes/config.yaml`, and a stray `OPENAI_API_KEY` is what the `openrouter` provider keys off. See the comment at `ansible/roles/llm/tasks/hermes.yaml:22-27`.
- Any `hermes` invocation in a task must `export PATH="$HOME/.local/bin:$PATH"` first — the installer puts it there and ansible tasks do not get a login shell.
- yamllint in this repo rejects inline dicts with padded braces. Write loop entries in block style (`- key: x` / `  value: y`), not `- { key: x, value: y }`.
- Verify every model tag against the live library before adding it — `ollama pull` 404s on a nonexistent tag, and this bit us once already with `devstral-small2`.

---

## Task 1: Tune the existing Ollama backend

Cheap wins that stand on their own, independent of whether NInfer ever ships. Flash attention plus a quantised KV cache cuts KV memory roughly in half; `OLLAMA_KEEP_ALIVE` removes the model-reload stall that likely accounts for much of the "Hermes feels slow" complaint (default is 5 minutes, after which the next prompt waits for ~18 GB to page off disk).

**Files:**

- Modify: `ansible/roles/llm/defaults/main.yaml`
- Create: `ansible/roles/llm/templates/ollama-env.conf.j2`
- Delete: `ansible/roles/llm/templates/ollama-bind.conf.j2`
- Modify: `ansible/roles/llm/tasks/ollama.yaml:20-33`

**Interfaces:**

- Produces: `llm_ollama_keep_alive`, `llm_ollama_flash_attention`, `llm_ollama_kv_cache_type` defaults, and a drop-in at `/etc/systemd/system/ollama.service.d/env.conf` (replacing `bind.conf`). Nothing downstream reads these — `-1` is safe even when NInfer is the active backend, because Task 5 *stops* Ollama rather than relying on it to release VRAM.

- [x] **Step 1: Add the new defaults**

In `ansible/roles/llm/defaults/main.yaml`, after the `llm_ollama_bind` block, add:

```yaml
# Keep the model resident instead of unloading after Ollama's default 5 minutes.
# Reloading a ~18GB model off disk is a multi-second stall on the first prompt
# after any idle period, which reads as "the agent is slow" far more than decode
# speed does. "-1" = never unload; "0" = unload immediately (see llm_backend).
llm_ollama_keep_alive: "-1"

# Flash attention is a prerequisite for a quantised KV cache — setting
# llm_ollama_kv_cache_type without it silently leaves the cache at f16.
llm_ollama_flash_attention: "1"
llm_ollama_kv_cache_type: "q8_0"
```

Then move `llm_ollama_models` from Qwen3.6 to **Qwen3.8** and add the MTP variant as the default. Two reasons: 3.8 is simply the newer model, and it is the same generation NInfer serves — so the Task 7 A/B compares engines rather than confounding engine with model.

Multi-token prediction is a decode speedup at identical weights and quantisation; keeping the plain tag alongside it makes the A/B a one-line model swap rather than a re-download.

```yaml
# Tags verified against https://ollama.com/library/qwen3.8/tags on 2026-08-19.
# `ollama pull` 404s on a tag that doesn't exist — re-check before editing.
# The -mtp- variant uses multi-token prediction: same weights and quantisation,
# faster decode. Kept alongside the plain tag so they can be compared directly.
# Qwen3.8 (not 3.6) so this matches the generation NInfer serves.
llm_ollama_models:
  - "qwen3.8:27b-mtp-q4_K_M"
  - "qwen3.8:27b-q4_K_M"
  - "devstral:24b-small-2505-q4_K_M"
```

Disk check: 18 + 18 + 14 GB of Ollama blobs plus NInfer's 17 GiB artifact is ~67 GB against ai-vm's 150 GB disk. Comfortable.

The old `qwen3.6:*` blobs are **not** removed automatically — `ollama list` will still show them after this change. Clean them up by hand once Task 7 is settled:

```bash
ollama rm qwen3.6:27b-q4_K_M
```

`llm_default_model` already reads `{{ llm_ollama_models[0] }}`, so it follows automatically. Leave that line alone.

- [x] **Step 2: Create the replacement drop-in template**

Create `ansible/roles/llm/templates/ollama-env.conf.j2`:

```jinja
# Managed by Ansible (terranse llm role) — DO NOT EDIT.
[Service]
Environment="OLLAMA_HOST={{ llm_ollama_bind }}"
Environment="OLLAMA_KEEP_ALIVE={{ llm_ollama_keep_alive }}"
Environment="OLLAMA_FLASH_ATTENTION={{ llm_ollama_flash_attention }}"
Environment="OLLAMA_KV_CACHE_TYPE={{ llm_ollama_kv_cache_type }}"
```

- [x] **Step 3: Delete the old template**

```bash
git rm ansible/roles/llm/templates/ollama-bind.conf.j2
```

- [x] **Step 4: Point the task at the new template and clean up the stale drop-in**

In `ansible/roles/llm/tasks/ollama.yaml`, replace the "Configure Ollama's network bind" task (lines 26-33) with:

```yaml
# Renamed from bind.conf: this drop-in now carries tuning as well as the bind
# address, and systemd merges every *.conf in the directory — a leftover
# bind.conf would keep setting a stale OLLAMA_HOST alongside the new file.
- name: Remove the superseded bind-only drop-in
  ansible.builtin.file:
    path: /etc/systemd/system/ollama.service.d/bind.conf
    state: absent
  notify:
    - Reload systemd
    - Restart ollama

- name: Configure Ollama's bind address and tuning
  ansible.builtin.template:
    src: ollama-env.conf.j2
    dest: /etc/systemd/system/ollama.service.d/env.conf
    mode: '0644'
  notify:
    - Reload systemd
    - Restart ollama
```

- [x] **Step 5: Lint**

Every `just` recipe depends on `_python-venv`, which fails with `VIRTUAL_ENV: unbound variable` when you are not inside the venv (`set -u` firing before its friendly error message can print). Activate it first:

```bash
source .venv/bin/activate
just install-test   # once; yamllint/ansible-lint are not installed by default
```

**Do not run bare `just lint`** and expect it to pass. The wider `ansible/` tree has extensive pre-existing failures — long lines, missing `---`, padded braces — across `docker`, `drivers`, `network`, `proxmox`, `borgmatic` and others. Cleaning those up is not this plan's job. Lint the role you are changing, with the repo's config:

```bash
.venv/bin/yamllint -c tests/static/.yamllint.yaml ansible/roles/llm/
.venv/bin/ansible-lint -c tests/static/.ansible-lint ansible/roles/llm/
```

Expected: `yamllint` silent, `ansible-lint` reporting 0 failures. Note the `-c` flags — without them yamllint applies its 80-column default instead of the repo's 120 and reports false positives.

- [x] **Step 6: Commit**

```bash
git add ansible/roles/llm/
git commit -m "perf(ansible): keep Ollama models resident and quantise its KV cache"
```

---

## Task 2: Docker + NVIDIA Container Toolkit on ai-vm

Needed by NInfer, and by Open WebUI and ComfyUI later. Gated behind its own variable so it can be turned on independently of any NInfer work.

**Files:**

- Create: `ansible/roles/llm/tasks/docker.yaml`
- Modify: `ansible/roles/llm/defaults/main.yaml`
- Modify: `ansible/roles/llm/handlers/main.yaml`
- Modify: `ansible/roles/llm/tasks/main.yaml` (after the guest-driver assert, before Ollama)

**Interfaces:**

- Consumes: the `gpu_type == "nvidia_vgpu"` guard and the `llm_dkms_status` assert already in `main.yaml`.
- Produces: a working `docker` with the `nvidia` runtime registered, and `llm_user` in the `docker` group. Tasks 3-5 rely on `docker run --gpus all` working for `llm_user` without sudo.

- [x] **Step 1: Add the default**

In `ansible/roles/llm/defaults/main.yaml`, append:

```yaml
# Docker + NVIDIA Container Toolkit. Required by the ninfer backend, and by the
# planned Open WebUI / ComfyUI containers regardless of which backend wins.
llm_docker_enabled: true
```

- [x] **Step 2: Write the tasks file**

Create `ansible/roles/llm/tasks/docker.yaml`:

```yaml
---
# Docker engine + NVIDIA Container Toolkit, so containers can use the vGPU.
#
# The toolkit's apt repo is distribution-agnostic (stable/deb/$arch) — it does
# NOT carry an Ubuntu codename, so this keeps working across base-image bumps.
# The toolkit does not ship a driver; it wires the *guest* driver's libraries
# into containers, which is why this must run after the guest-driver assert.

- name: Install Docker engine
  ansible.builtin.include_role:
    name: geerlingguy.docker
  vars:
    docker_users:
      - "{{ llm_user }}"

- name: Ensure the apt keyring directory exists
  ansible.builtin.file:
    path: /etc/apt/keyrings
    state: directory
    mode: '0755'

- name: Add the NVIDIA Container Toolkit apt key
  ansible.builtin.get_url:
    url: https://nvidia.github.io/libnvidia-container/gpgkey
    dest: /etc/apt/keyrings/nvidia-container-toolkit.asc
    mode: '0644'

- name: Add the NVIDIA Container Toolkit apt repository
  ansible.builtin.apt_repository:
    repo: >-
      deb [signed-by=/etc/apt/keyrings/nvidia-container-toolkit.asc]
      https://nvidia.github.io/libnvidia-container/stable/deb/$(ARCH) /
    filename: nvidia-container-toolkit
    state: present

- name: Install the NVIDIA Container Toolkit
  ansible.builtin.apt:
    name: nvidia-container-toolkit
    state: present
    update_cache: true
  notify: Restart docker

- name: Check whether the nvidia runtime is already registered
  ansible.builtin.command: docker info --format '{% raw %}{{json .Runtimes}}{% endraw %}'
  register: llm_docker_runtimes
  changed_when: false

- name: Register the nvidia runtime with Docker
  ansible.builtin.command: nvidia-ctk runtime configure --runtime=docker
  when: "'nvidia' not in llm_docker_runtimes.stdout"
  changed_when: true
  notify: Restart docker

- name: Flush handlers so Docker restarts before the GPU smoke test
  ansible.builtin.meta: flush_handlers

- name: Verify a container can see the vGPU
  ansible.builtin.command: >-
    docker run --rm --gpus all
    nvidia/cuda:13.1.2-runtime-ubuntu24.04 nvidia-smi
  register: llm_docker_gpu
  changed_when: false
  failed_when: "'A5000' not in llm_docker_gpu.stdout"
```

- [x] **Step 3: Add the `Restart docker` handler**

Append to `ansible/roles/llm/handlers/main.yaml`:

```yaml
- name: Restart docker
  ansible.builtin.systemd:
    name: docker
    state: restarted
```

- [x] **Step 4: Wire it into the role**

In `ansible/roles/llm/tasks/main.yaml`, insert between the guest-driver assert and `- name: Set up Ollama`:

```yaml
- name: Set up Docker and the NVIDIA Container Toolkit
  ansible.builtin.include_tasks: docker.yaml
  when: llm_docker_enabled | bool
```

- [x] **Step 5: Install the galaxy dependency, then deploy**

`docker.yaml` includes `geerlingguy.docker`, which is a Galaxy role — it lives at `ansible/roles/geerlingguy.docker` and is **gitignored** (`.gitignore:15`). A fresh worktree therefore does not have it, and the play will fail on the `include_role` with "the role was not found". Install it first:

```bash
source .venv/bin/activate
just install-ansible
ls ansible/roles/geerlingguy.docker   # must exist before deploying
```

Then:

```bash
.venv/bin/ansible-lint -c tests/static/.ansible-lint ansible/roles/llm/
just setup ai-vm
```

Expected: the "Verify a container can see the vGPU" task passes, printing an A5000 from inside the container. If it fails with `could not select device driver`, the runtime registration did not take — check that `docker info | grep -i runtime` lists `nvidia`.

- [x] **Step 6: Confirm idempotency**

```bash
just setup ai-vm
```

Expected: `changed=0`. A non-zero `changed` here almost always means the `nvidia-ctk` guard is wrong — fix it rather than accepting the noise.

- [x] **Step 7: Commit**

```bash
git add ansible/roles/llm/
git commit -m "feat(ansible): add Docker and the NVIDIA Container Toolkit to the llm role"
```

---

## Task 3: Manual spike — prove Hermes can drive NInfer on the vGPU

**Do this before writing any more automation.** If a vGPU-sliced A5000 cannot run
these kernels, or if Hermes cannot drive the server, Tasks 4-7 are wasted work
and the honest answer is "it doesn't work here". This task is deliberately
manual and throwaway; nothing it produces is committed except the findings.

**Ordered so the cheapest disqualifier runs first.** Speed is the *second*
question. The first is whether Hermes — an agent that lives or dies on tool
calls — can talk to this server at all. A backend that is 2x faster and cannot
call tools is worth nothing here, and finding that out after a 90-minute build
and a 17 GiB download is the expensive way to learn it.

**Files:**

- Modify: this plan document (record the measured result in "Spike results" below)

**Interfaces:**

- Consumes: Docker with the nvidia runtime from Task 2.
- Produces: a go/no-go decision, a captured real Hermes request corpus, a
  measured single-user tok/s figure, and the exact model ID string the server
  advertises — Task 6 needs that string verbatim for `llm_ninfer_model_id`.

### What is already known about NInfer's API surface

Read off `src/serve/` at the pinned ref on 2026-08-21, so the spike does not
have to rediscover it:

| Question | Answer |
|---|---|
| Endpoints | `/v1/chat/completions`, `/v1/models`, `/v1/responses`, `/v1/messages` (Anthropic) |
| Modern tool calling | **Supported** — `tools`, `tool_choice` (`none`/`auto`/`required`/named), `tool_calls`, `role: tool`, `tool_call_id`; `src/serve/tool_call_parser.cpp` parses them out of the generated text |
| Legacy `functions` / `function_call` | **Rejected**, 400 `tools_not_supported` |
| Streaming | Supported, incl. `stream_options.include_usage` |
| `response_format` | **Only `{type: text}`** — `json_object` and `json_schema` are 400 `response_format_not_supported` |
| `n > 1` | Rejected, 400 `n_not_supported` |
| Reasoning | Accepts `reasoning_effort`, returns `reasoning_content`, honours `chat_template_kwargs.enable_thinking` |

Hermes' chat path does not send `response_format` (checked: only the vendored
OpenAI SDK types and the image-gen plugin mention it), so the structured-output
gap looks survivable. **That is a code reading, not a test** — Step 2 is what
actually proves it.

- [x] **Step 0: Confirm the guest reports enough VRAM** — done 2026-08-20.
      24,576 MiB total, no ECC reduction, CUDA 13.2 / driver 595.58.03.
      C1 needs 19,641 MiB, so it fits with headroom.

- [x] **Step 1: Give the GPU back to one tenant**

The spike needs the whole slice, and the box currently thrashes (see
"Deployment notes"). Before measuring anything:

```bash
ssh ubuntu@ai-vm.edholm.cc 'ollama ps; sudo journalctl -u ollama --since "10 min ago" | grep -c evicting'
```

If anything other than the spike is holding VRAM or a second model is being
requested, resolve that first — otherwise every number this task produces is
noise. This is also why Step 5's baseline must be re-measured rather than
taken from the "Benchmark results" table.

- [x] **Step 2: Capture what Hermes actually sends — before building anything**

Sit a logging proxy between Hermes and Ollama, run one real agent turn that
uses tools, and keep the request bodies. This costs minutes and can kill the
whole idea on its own.

```bash
# on ai-vm, as any user
mkdir -p /var/lib/hermes-capture && cd /var/lib/hermes-capture
python3 - <<'PY' &
import http.server, json, urllib.request, itertools, pathlib
n = itertools.count()
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        pathlib.Path(f"req-{next(n):03d}.json").write_bytes(body)
        r = urllib.request.urlopen(urllib.request.Request(
            "http://127.0.0.1:11434" + self.path, body,
            {"Content-Type": "application/json"}))
        data = r.read()
        self.send_response(200)
        self.send_header("Content-Type", r.headers.get("Content-Type", "application/json"))
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    do_GET = None
http.server.ThreadingHTTPServer(("127.0.0.1", 11999), H).serve_forever()
PY
sudo -u llm bash -lc 'hermes config set model.base_url http://localhost:11999/v1'
# run one real task that forces tool use, e.g.
sudo -u llm bash -lc 'hermes --yolo -z "List the files in /etc that were modified today, then tell me how many there are."'
sudo -u llm bash -lc 'hermes config set model.base_url http://localhost:11434/v1'
```

Then check the captures against the table above:

```bash
jq -r 'keys[]' /var/lib/hermes-capture/req-*.json | sort -u
jq -e 'has("functions") or has("function_call")' /var/lib/hermes-capture/req-*.json   # must be false everywhere
jq -e '.response_format.type // "text" | . != "text"' /var/lib/hermes-capture/req-*.json  # must be false everywhere
jq -e '(.n // 1) > 1' /var/lib/hermes-capture/req-*.json                              # must be false everywhere
```

**Gate A — if Hermes sends `functions`, `function_call`, a non-text
`response_format`, or `n > 1` on its main chat path, stop here.** NInfer 400s
on all four and no amount of build time changes that. Note it in "Spike
results" and close the idea out; Tasks 1 and 2 still stand on their own.

Keep `/var/lib/hermes-capture/` — Step 5 replays it.

- [x] **Step 3: Build the image and fetch the artifact concurrently**

They are independent; running them in series wastes an hour. Start the
download first so it runs while the compiler works.

```bash
ssh ubuntu@ai-vm.edholm.cc
mkdir -p /var/lib/ninfer-spike/models
nohup curl -L -C - --fail -o /var/lib/ninfer-spike/models/qwen3_8_27b.ninfer \
  https://huggingface.co/neroued/Qwen3.8-27B-NInfer/resolve/main/qwen3_8_27b.ninfer \
  > /var/lib/ninfer-spike/download.log 2>&1 &

git clone https://github.com/Don-Chad/ninfer-3090 /var/lib/ninfer-spike/src
cd /var/lib/ninfer-spike/src
git checkout 403fc56d71576aa1feddb771cfed3264e7378b20
time docker build --tag ninfer-3090:spike .
```

Expected: 45-90 minutes on 8 cores for the build; 16.96 GiB for the artifact.
The Dockerfile deliberately does not pass `-DCMAKE_CUDA_ARCHITECTURES` —
`CMakeLists.txt` defaults to `86`, which is the value we want.

Verify the download before serving:

```bash
sha256sum /var/lib/ninfer-spike/models/qwen3_8_27b.ninfer
```

Expected: `eec39564993d6e9c7d5e383382a760f093465c9d163ec9a1bd6b80199514bf3e`

- [x] **Step 4: Stop Ollama so the VRAM is free, then serve**

```bash
sudo systemctl stop ollama
docker run --rm --gpus all -p 8080:8080 \
  -v /var/lib/ninfer-spike/models:/workspace/models:ro \
  ninfer-3090:spike \
  ninfer-serve models/qwen3_8_27b.ninfer \
  --host 0.0.0.0 --port 8080 \
  --max-context 65536 --kv-capacity 65536 \
  --max-concurrency 1 --max-pending-requests 16 \
  --prefill-chunk 1024 --kv-dtype int8 \
  --spec mtp --draft-tokens 3 --lm-head-draft
```

Record the `id` from `curl -s http://ai-vm.edholm.cc:8080/v1/models` verbatim —
Task 6 needs it. Run `nvidia-smi` while it serves and record peak VRAM.

- [x] **Step 5: Replay the captured Hermes requests — the real compat gate**

Static checks proved nothing about the tool-call *parser*. Replay every
captured body against NInfer with only the model id swapped:

```bash
ID=$(curl -s http://localhost:8080/v1/models | jq -r '.data[0].id')
for f in /var/lib/hermes-capture/req-*.json; do
  echo "--- $f"
  jq --arg id "$ID" '.model = $id' "$f" \
    | curl -s http://localhost:8080/v1/chat/completions \
        -H 'Content-Type: application/json' -d @- \
    | jq '{status: (.error.code // "ok"),
           msg: .error.message,
           finish: .choices[0].finish_reason,
           tool_calls: (.choices[0].message.tool_calls | length? // 0)}'
done
```

**Gate B — every request must return `ok`.** A request that Ollama answered and
NInfer 400s is a blocker; record the `code` and `message` verbatim, because
that string is the whole finding.

Then check that tool calls actually *parse*: for the captured requests that
carried a `tools` array and got a tool call back from Ollama, NInfer must also
return a well-formed `tool_calls` entry with a non-empty `id`, a `function.name`
matching a supplied tool, and `function.arguments` that is parseable JSON. A
model that emits its tool call as prose and gets `tool_calls: 0` is a fail —
that is precisely what `tool_call_parser.cpp` exists to prevent, and precisely
what a prompt-rendered (rather than grammar-constrained) implementation gets
wrong.

- [x] **Step 6: Drive it with the real Hermes, end to end**

Static replay can still miss streaming behaviour and multi-turn tool loops.

```bash
sudo -u llm bash -lc 'hermes config set model.base_url http://localhost:8080/v1'
sudo -u llm bash -lc 'hermes config set model.default <id from Step 4>'
sudo -u llm bash -lc 'hermes --yolo -z "Create /tmp/spike-proof.txt containing the current kernel version, then read it back to me."'
```

**Gate C — Hermes must complete a multi-step tool-using task.** If it hangs on
the stream, loops on a malformed tool call, or trips its own
`tool_loop_guardrails`, that is the answer.

Revert with `hermes config set model.base_url http://localhost:11434/v1` and
the Ollama model id when done.

- [x] **Step 7: Only now, measure speed**

Discard the first request after any model load — it runs 20-40% slow and
already produced one wrong conclusion in this project. Take at least three
timed runs and report the range, not a single number.

```bash
curl -s http://localhost:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d "{\"model\":\"$ID\",\"messages\":[{\"role\":\"user\",\"content\":\"Write a 400-word explanation of how a B-tree index works.\"}],\"max_tokens\":512}" \
  -w '\ntotal: %{time_total}s\n' -o /tmp/ninfer-result.json
```

Divide `usage.completion_tokens` by `time_total`. Compare against a
**freshly re-measured** Ollama baseline taken on an otherwise idle GPU, not
against the table below.

- [x] **Step 8: Record the findings and decide**

Fill in "Spike results": CUDA version, total VRAM, build time, Gate A/B/C
outcomes, measured tok/s, peak VRAM, the model ID string, and anything that
broke.

```bash
git add docs/superpowers/plans/2026-08-19-ninfer-inference-backend.md
git commit -m "docs: record NInfer vGPU spike results"
```

Decision gate:

- Gates A, B and C all pass **and** tok/s is comfortably above a clean Ollama
  baseline **and** peak VRAM fits the slice → continue to Task 4.
- Any gate fails, or it runs but is no faster → **stop**. Clean up
  (`docker rmi ninfer-3090:spike`, `rm -rf /var/lib/ninfer-spike /var/lib/hermes-capture`),
  restart Ollama, and report. Tasks 1 and 2 still stand on their own.

---

## Task 4 (DONE 2026-09-20): Codify the NInfer build and artifact download

> ~~**Shelved 2026-08-22.**~~ **Unshelved and implemented 2026-09-20.** The
> steps below are as-built with three corrections, all recorded in "Promotion":
> the artifact URL is pinned to a HuggingFace *revision* (upstream replaced the
> one on `main` with an incompatible file), the unit carries
> `--max-context 131072` rather than 65536, and the image tag is the only thing
> that still names the engine — the branch the pinned commit sat on has been
> force-moved.


Only start this once Task 3's gate says go.

**Files:**

- Create: `ansible/roles/llm/tasks/ninfer.yaml`
- Modify: `ansible/roles/llm/defaults/main.yaml`
- Modify: `ansible/roles/llm/tasks/main.yaml`
- Modify: `tofu/deployments/edholm/configurations.tfvars:270-272`

**Interfaces:**

- Consumes: Docker with the nvidia runtime from Task 2.
- Produces: image `ninfer-3090:{{ llm_ninfer_ref }}` and artifact at `{{ llm_ninfer_model_dir }}/qwen3_8_27b.ninfer` — Task 5's systemd unit references both by exactly these names.

- [ ] **Step 1: Add the defaults**

Append to `ansible/roles/llm/defaults/main.yaml`:

```yaml
# NInfer — a native SM86 CUDA inference engine (Apache-2.0). Faster than Ollama
# on this hardware but single-model and single-purpose, so it does not replace
# Ollama; llm_backend picks which one is live. The A5000 is GA102/sm_86, the
# same as the RTX 3090 this fork targets, and upstream has no device gating.
llm_ninfer_enabled: false
llm_ninfer_repo: "https://github.com/Don-Chad/ninfer-3090"

# Pinned commit, not a branch: the default branch is a release branch that
# upstream force-updates, and a silently different build is the last thing we
# want between two benchmark runs.
llm_ninfer_ref: "403fc56d71576aa1feddb771cfed3264e7378b20"

llm_ninfer_src_dir: /opt/ninfer/src
llm_ninfer_model_dir: /opt/ninfer/models
llm_ninfer_model_url: "https://huggingface.co/neroued/Qwen3.8-27B-NInfer/resolve/main/qwen3_8_27b.ninfer"
llm_ninfer_model_sha256: "eec39564993d6e9c7d5e383382a760f093465c9d163ec9a1bd6b80199514bf3e"
llm_ninfer_port: 8080

# Empty means the server runs without auth, which is fine on the LAN. Set this
# from the vault before exposing the port over ipid.
llm_ninfer_api_key: ""
```

- [ ] **Step 2: Write the tasks file**

Create `ansible/roles/llm/tasks/ninfer.yaml`:

```yaml
---
# Build the NInfer engine and fetch its model artifact.
#
# Upstream publishes no Linux binary, so the image is built on-box from a
# pinned commit. That build is 45-90 minutes on 8 cores, hence the async block
# and the "is this image already here" guard in front of it.

- name: Ensure the NInfer directories exist
  ansible.builtin.file:
    path: "{{ item }}"
    state: directory
    owner: "{{ llm_user }}"
    group: "{{ llm_user }}"
    mode: '0755'
  loop:
    - /opt/ninfer
    - "{{ llm_ninfer_src_dir }}"
    - "{{ llm_ninfer_model_dir }}"

- name: Check out the pinned NInfer source
  ansible.builtin.git:
    repo: "{{ llm_ninfer_repo }}"
    dest: "{{ llm_ninfer_src_dir }}"
    version: "{{ llm_ninfer_ref }}"
  become: true
  become_user: "{{ llm_user }}"

- name: Read the images already built
  ansible.builtin.command: docker images --format '{% raw %}{{.Repository}}:{{.Tag}}{% endraw %}'
  register: llm_ninfer_images
  changed_when: false

- name: Build the NInfer image
  ansible.builtin.command: "docker build --tag ninfer-3090:{{ llm_ninfer_ref }} ."
  args:
    chdir: "{{ llm_ninfer_src_dir }}"
  become: true
  become_user: "{{ llm_user }}"
  when: "'ninfer-3090:' ~ llm_ninfer_ref not in llm_ninfer_images.stdout"
  changed_when: true
  async: 7200
  poll: 60

- name: Download the Qwen3.8-27B artifact
  ansible.builtin.get_url:
    url: "{{ llm_ninfer_model_url }}"
    dest: "{{ llm_ninfer_model_dir }}/qwen3_8_27b.ninfer"
    checksum: "sha256:{{ llm_ninfer_model_sha256 }}"
    owner: "{{ llm_user }}"
    group: "{{ llm_user }}"
    mode: '0644'
  async: 3600
  poll: 30
```

`get_url` with a `checksum` is idempotent by itself: it skips the download when the existing file already matches, and re-fetches a truncated one. No separate guard is needed.

- [ ] **Step 3: Wire it into the role**

In `ansible/roles/llm/tasks/main.yaml`, after the "Set up Ollama" include, add:

```yaml
- name: Set up the NInfer inference engine
  ansible.builtin.include_tasks: ninfer.yaml
  when: llm_ninfer_enabled | bool
```

- [ ] **Step 4: Enable it in tfvars**

In `tofu/deployments/edholm/configurations.tfvars`, change the `ai-vm` roles block (currently `roles = [{ name = "llm" }]`) to:

```hcl
        roles = [{
          name = "llm"
          vars = {
            # Strings, not booleans — the module declares vars as map(string).
            llm_ninfer_enabled = "true"
            llm_backend        = "ollama"
          }
        }]
```

`llm_backend` stays `ollama` here deliberately: this task installs NInfer but does not make it live. Task 5 introduces the switch and Task 7 flips it.

- [ ] **Step 5: Apply and deploy**

```bash
just apply-tofu edholm
just setup ai-vm
```

Expected: `tofu plan` shows only `local_file` changes (the regenerated playbook), **no VM changes**. If it wants to touch the VM, stop and investigate — `vm_state` is in `ignore_changes` precisely to prevent this.

- [ ] **Step 6: Confirm idempotency**

```bash
just setup ai-vm
```

Expected: `changed=0`. The build task must not re-run.

- [ ] **Step 7: Commit**

```bash
git add ansible/roles/llm/ tofu/deployments/edholm/configurations.tfvars
git commit -m "feat(ansible): build the NInfer engine and fetch its model artifact"
```

---

## Task 5 (DONE 2026-09-20): The backend switch

**Files:**

- Create: `ansible/roles/llm/templates/ninfer.service.j2`
- Create: `ansible/roles/llm/tasks/backend.yaml`
- Modify: `ansible/roles/llm/defaults/main.yaml`
- Modify: `ansible/roles/llm/handlers/main.yaml`
- Modify: `ansible/roles/llm/tasks/main.yaml`

**Interfaces:**

- Consumes: the image and artifact from Task 4.
- Produces: `llm_backend` (`ollama` | `ninfer`), a `ninfer.service` unit, and the guarantee that exactly one backend is enabled at boot — Task 6 reads `llm_backend` to decide Hermes's `base_url` and model.

- [ ] **Step 1: Add the default**

Append to `ansible/roles/llm/defaults/main.yaml`:

```yaml
# Which inference backend owns the GPU. Both stay installed; only the selected
# one is enabled and started. They cannot coexist — Ollama holds ~18GB and
# NInfer ~19.6GB of a 24GB slice — so the unit file also declares Conflicts=.
llm_backend: ollama
```

- [ ] **Step 2: Write the unit template**

Create `ansible/roles/llm/templates/ninfer.service.j2`:

```jinja
# Managed by Ansible (terranse llm role) — DO NOT EDIT.
[Unit]
Description=NInfer inference server (Qwen3.8-27B, sm_86)
After=docker.service
Requires=docker.service
# Ollama and NInfer cannot share the 24GB slice. Starting this stops Ollama.
Conflicts=ollama.service

[Service]
User={{ llm_user }}
# --rm plus an explicit ExecStartPre: if the unit is killed uncleanly the
# container name would otherwise linger and block the next start.
ExecStartPre=-/usr/bin/docker rm -f ninfer
ExecStart=/usr/bin/docker run --rm --name ninfer \
  --gpus all \
  --publish {{ llm_ninfer_port }}:8080 \
  --volume {{ llm_ninfer_model_dir }}:/workspace/models:ro \
  ninfer-3090:{{ llm_ninfer_ref }} \
  ninfer-serve models/qwen3_8_27b.ninfer \
  --host 0.0.0.0 --port 8080 \
{% if llm_ninfer_api_key | length > 0 %}
  --api-key {{ llm_ninfer_api_key }} \
{% endif %}
  --max-context 65536 --kv-capacity 65536 \
  --max-concurrency 1 --max-pending-requests 16 \
  --prefill-chunk 1024 --kv-dtype int8 \
  --spec mtp --draft-tokens 3 --lm-head-draft
ExecStop=/usr/bin/docker stop ninfer
ExecStopPost=-/usr/bin/docker rm -f ninfer
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
```

C1 (`--max-concurrency 1`) is deliberate: upstream's C8 profile peaks at 22-23 GiB, which does not fit a 24Q slice once ECC overhead is counted.

- [ ] **Step 3: Write the switch tasks**

Create `ansible/roles/llm/tasks/backend.yaml`:

```yaml
---
# Enable exactly one inference backend. The loser is stopped and disabled but
# left installed, so switching back is a variable flip and a re-run.

- name: Validate llm_backend
  ansible.builtin.assert:
    that:
      - llm_backend in ['ollama', 'ninfer']
    fail_msg: "llm_backend must be 'ollama' or 'ninfer', got '{{ llm_backend }}'"

- name: Require NInfer to be installed before selecting it
  ansible.builtin.assert:
    that:
      - llm_ninfer_enabled | bool
    fail_msg: >-
      llm_backend is 'ninfer' but llm_ninfer_enabled is false, so no image or
      artifact was built. Set llm_ninfer_enabled = "true" in the ai-vm role
      vars as well.
  when: llm_backend == 'ninfer'

- name: Install the NInfer systemd unit
  ansible.builtin.template:
    src: ninfer.service.j2
    dest: /etc/systemd/system/ninfer.service
    mode: '0644'
  when: llm_ninfer_enabled | bool
  notify:
    - Reload systemd
    - Restart ninfer

- name: Flush handlers so the unit is registered before it is enabled
  ansible.builtin.meta: flush_handlers

# Stop the loser first: starting the winner while the loser still holds VRAM
# fails with an allocation error rather than a useful message.
- name: Stop and disable the unselected backend
  ansible.builtin.systemd:
    name: "{{ 'ollama' if llm_backend == 'ninfer' else 'ninfer' }}"
    enabled: false
    state: stopped
  failed_when: false

- name: Enable and start the selected backend
  ansible.builtin.systemd:
    name: "{{ 'ninfer' if llm_backend == 'ninfer' else 'ollama' }}"
    enabled: true
    state: started
    daemon_reload: true
```

`failed_when: false` on the stop task is deliberate — on a first run `ninfer.service` may not exist yet, and "cannot stop a unit that was never installed" is not worth failing a play over.

- [ ] **Step 4: Add the `Restart ninfer` handler**

Append to `ansible/roles/llm/handlers/main.yaml`:

```yaml
- name: Restart ninfer
  ansible.builtin.systemd:
    name: ninfer
    state: restarted
  when: llm_backend == 'ninfer'
```

- [ ] **Step 5: Wire it in**

In `ansible/roles/llm/tasks/main.yaml`, add after the NInfer include and **before** the Hermes include — Hermes must be configured against a backend that is already up:

```yaml
- name: Select the active inference backend
  ansible.builtin.include_tasks: backend.yaml
```

- [ ] **Step 6: Deploy and verify Ollama is still the live backend**

```bash
just setup ai-vm
ssh ubuntu@ai-vm.edholm.cc systemctl is-enabled ollama ninfer
```

Expected: `enabled` then `disabled`. Nothing has switched yet.

- [ ] **Step 7: Commit**

```bash
git add ansible/roles/llm/
git commit -m "feat(ansible): select the active inference backend with llm_backend"
```

---

## Task 6 (DONE 2026-09-20): Point Hermes at whichever backend is live

**Files:**

- Modify: `ansible/roles/llm/tasks/hermes.yaml:33-58`
- Modify: `ansible/roles/llm/defaults/main.yaml`

**Interfaces:**

- Consumes: `llm_backend` from Task 5, and the model ID string recorded in Task 3 Step 5.
- Produces: a Hermes config on `ai-vm` that follows the backend automatically.

- [ ] **Step 1: Add the model ID default**

Append to `ansible/roles/llm/defaults/main.yaml`, substituting the string recorded in Task 3:

```yaml
# NInfer advertises the artifact's own identity.model_id and rejects any other
# value in a request's "model" field. Confirm with:
#   curl -s http://ai-vm.edholm.cc:8080/v1/models
llm_ninfer_model_id: "<record from Task 3 Step 5>"
```

- [ ] **Step 2: Make the Hermes wiring backend-aware**

In `ansible/roles/llm/tasks/hermes.yaml`, rename the task "Point Hermes at the local Ollama endpoint" to "Point Hermes at the active inference backend", and replace its `loop:` block with:

```yaml
  loop:
    - key: model.provider
      value: ollama
    - key: model.base_url
      value: "{{ 'http://localhost:' ~ llm_ninfer_port ~ '/v1' if llm_backend == 'ninfer' else 'http://localhost:11434/v1' }}"
    - key: model.default
      value: "{{ llm_ninfer_model_id if llm_backend == 'ninfer' else llm_default_model }}"
```

`model.provider` stays `ollama` for both: it is Hermes's alias for the generic OpenAI-compatible provider, and NInfer serves that same API.

- [ ] **Step 3: Leave the API-key open item in the code**

Add this comment directly above the loop, so it is not forgotten when the port is exposed:

```yaml
# TODO: when llm_ninfer_api_key is set (i.e. once this is exposed over ipid),
# Hermes needs the matching bearer token. The config key for that is NOT yet
# verified — run `hermes config list` on-box to find its name, then add it
# to the loop below guarded on llm_backend == 'ninfer'.
```

- [ ] **Step 4: Deploy and verify**

```bash
just setup ai-vm
ssh ubuntu@ai-vm.edholm.cc "sudo cat /home/llm/.hermes/config.yaml"
```

Expected: `base_url` still points at `11434` (backend is still `ollama`), proving the conditional defaults correctly.

- [ ] **Step 5: Commit**

```bash
git add ansible/roles/llm/
git commit -m "feat(ansible): follow llm_backend when wiring Hermes"
```

---

## Task 7 (SHELVED): A/B the two backends and decide

**Files:**

- Modify: `tofu/deployments/edholm/configurations.tfvars`
- Modify: this plan document ("Benchmark results")

- [x] **Step 1: Benchmark Ollama with the MTP model**

```bash
ssh ubuntu@ai-vm.edholm.cc
curl -s http://localhost:11434/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen3.8:27b-mtp-q4_K_M","messages":[{"role":"user","content":"Write a 400-word explanation of how a B-tree index works."}],"max_tokens":512}' \
  -w '\ntotal: %{time_total}s\n' -o /tmp/ab-ollama-mtp.json
```

Record `usage.completion_tokens` divided by `time_total`. Run it twice and keep the second number — the first includes model load.

- [x] **Step 2: Benchmark the plain (non-MTP) model for reference**

Same command with `"model":"qwen3.8:27b-q4_K_M"`. This isolates how much of any gain is MTP versus the engine itself.

- [ ] **Step 3: Switch to NInfer**

In `tofu/deployments/edholm/configurations.tfvars`, change the ai-vm role vars:

```hcl
            llm_backend = "ninfer"
```

```bash
just apply-tofu edholm
just setup ai-vm
```

- [ ] **Step 4: Benchmark NInfer with the identical prompt**

```bash
curl -s http://localhost:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"<llm_ninfer_model_id>","messages":[{"role":"user","content":"Write a 400-word explanation of how a B-tree index works."}],"max_tokens":512}' \
  -w '\ntotal: %{time_total}s\n' -o /tmp/ab-ninfer.json
```

- [ ] **Step 5: Use it for real for a day**

Numbers are not the whole story. Point local Hermes at whichever won and do actual work through it. Both backends now serve Qwen3.8-27B, so any quality difference is down to quantisation and sampling rather than the model — watch instead for whether tool calls parse correctly, how it handles long agent sessions, and whether the single-model limitation bites (NInfer serves one model per process, so Devstral is unavailable while it runs).

- [ ] **Step 6: Record results and set the winner**

Fill in "Benchmark results" below, set `llm_backend` to the winner in tfvars, apply, and commit.

```bash
git add tofu/deployments/edholm/configurations.tfvars docs/superpowers/plans/2026-08-19-ninfer-inference-backend.md
git commit -m "docs: record the Ollama/NInfer A/B result and set the winning backend"
```

---

## Task 8: Open WebUI as the chat front end for the agent

The point is to chat with **Hermes**, not with the raw model. Hermes ships an
OpenAI-compatible API server inside its gateway for exactly this, and Open WebUI
is a documented client of it
(`website/docs/user-guide/messaging/open-webui.md`).

```
browser ──▶ Open WebUI :3000 ──▶ Hermes gateway API server :8642 ──▶ backend :11434 / :8080
```

This also solves the "Client compatibility" open item below: Open WebUI talks to
Hermes, Hermes talks to the engine, so switching Ollama ↔ NInfer never touches
the phone or the browser.

**Tools run on the API-server host.** Per the upstream docs: "if a laptop points
Open WebUI or another OpenAI-compatible client at a Hermes API server on a
remote machine, `pwd`, file tools, browser tools, local MCP tools, and other
workspace tools run on the remote API-server host". That is what we want here —
`ai-vm` is the workspace — but it means the chat box is a shell on `ai-vm` for
anyone who reaches it. Bind and authenticate accordingly.

**Files:**

- Create: `ansible/roles/llm/tasks/webui.yaml`
- Create: `ansible/roles/llm/templates/hermes-gateway.service.j2`
- Create: `ansible/roles/llm/templates/open-webui.compose.yaml.j2`
- Modify: `ansible/roles/llm/defaults/main.yaml`, `tasks/main.yaml`, `handlers/main.yaml`
- Modify: `ansible/secrets.yaml` (vaulted `llm_hermes_api_key`)

**Interfaces:**

- Consumes: Docker + NVIDIA runtime from Task 2; the live backend from Task 5.
- Produces: `http://ai-vm.edholm.cc:3000` chatting with the agent.

- [x] **Step 1: Turn on the Hermes API server**

```yaml
llm_hermes_api_server_enabled: true
llm_hermes_api_server_port: 8642
# llm_hermes_api_key comes from ansible-vault, never a default.
```

`hermes config set API_SERVER_ENABLED true` writes the flag to `config.yaml`;
`hermes config set API_SERVER_KEY <secret>` writes the secret to `~/.hermes/.env`
instead. Reuse the idempotent `hermes config set` loop already in `hermes.yaml`
rather than templating either file — Hermes owns their layout.

Generate the key once and store it vaulted:

```bash
just vault-edit   # add llm_hermes_api_key
```

- [x] **Step 2: Run the gateway as a service**

The API server only listens while `hermes gateway` runs, so it needs a unit
rather than a login shell. Template `hermes-gateway.service.j2`:
`User={{ llm_user }}`, `ExecStart=%h/.local/bin/hermes gateway`,
`Restart=on-failure`, `After=ollama.service`.

Verify before moving on:

```bash
curl -s http://127.0.0.1:8642/health
curl -s -H "Authorization: Bearer <key>" http://127.0.0.1:8642/v1/models
```

`/v1/models` returning 401 means the key does not match; `/health` failing means
the gateway did not pick up `API_SERVER_ENABLED`.

- [x] **Step 3: Run Open WebUI**

Template a compose file rather than a bare `docker run` — the container needs a
named volume to survive, and compose keeps that declarative:

```yaml
services:
  open-webui:
    image: ghcr.io/open-webui/open-webui:main
    ports: ["3000:8080"]
    volumes: ["open-webui:/app/backend/data"]
    environment:
      - OPENAI_API_BASE_URL=http://host.docker.internal:{{ llm_hermes_api_server_port }}/v1
      - OPENAI_API_KEY={{ llm_hermes_api_key }}
      - ENABLE_OLLAMA_API=false
    extra_hosts: ["host.docker.internal:host-gateway"]
    restart: always
volumes:
  open-webui:
```

`ENABLE_OLLAMA_API=false` hides the empty Ollama backend from the model picker.

**The trap:** those environment variables are read **only on Open WebUI's first
launch**. After that the connection lives in its internal SQLite database, and
Ansible re-templating the compose file will silently not change anything. So
when the API key or port changes, the play must either reconfigure through the
admin API or recreate the volume. Write that down in the task, and do not let
the role report `changed` on a setting that did not actually take.

First start takes 15-30 s while it downloads ~150 MB of embedding models.

- [x] **Step 4: Decide how it is exposed**

Port 3000 is a shell on `ai-vm` behind a login form. First user to register
becomes admin, so an unattended open port is a real exposure, not a theoretical
one. Either bind it to the Netbird interface only, or put it behind the existing
reverse proxy with auth — and register the account immediately after first
start, before anything else can. Record which was chosen.

Note `hermes dashboard` (port 9119) exists too and is a different thing: config,
API keys and session management, not a chat client. Since the June 2026
hardening a non-loopback bind always requires a password or OAuth provider —
`--insecure` is documented as a no-op. Out of scope here; use the CLI or a
tunnel.

---

## Task 9: ComfyUI + Flux

**The GPU cannot hold both.** Qwen3.8 occupies ~17 GiB of the 24 GiB slice and is
pinned resident by `OLLAMA_KEEP_ALIVE=-1`; Flux dev at fp8 wants roughly
12-17 GiB. Running them together reproduces exactly the eviction thrash that
Follow-up finding 2 diagnosed — except a diffusion model reloading is worse,
because it has no keep-alive to protect it.

Pick one before writing any tasks:

| Option | Cost |
|---|---|
| **On-demand ComfyUI** — a `comfyui.service` whose `ExecStartPre` sets `OLLAMA_KEEP_ALIVE=0` and unloads the LLM, and whose `ExecStopPost` restores it | Image generation and chat are mutually exclusive; the LLM reloads (~15-20 s) after each session. Simple and predictable. |
| **Coexist on a small quant** — Flux GGUF Q4 (~6.5 GiB) plus a reduced LLM context | Both stay resident; image quality drops and the LLM loses context headroom. Needs measurement to confirm it actually fits. |
| **Neither on this box** — ComfyUI moves to the gaming VM's vGPU slice | No contention, but that slice is doing something else and its own profile would need checking. |

Recommendation: **on-demand**, because it degrades in a way that is obvious
(you wait) rather than one that is invisible (everything is mysteriously slow),
and because it does not compromise the LLM setup we just finished tuning.

Do not start this task until the Task 7 decision is made — the winning backend
determines how the LLM gets unloaded (Ollama has an API for it; NInfer would
need the container stopped).

**Files (once the option is chosen):**

- Create: `ansible/roles/llm/tasks/comfyui.yaml`, `templates/comfyui.service.j2`
- Modify: `ansible/roles/llm/defaults/main.yaml`, `tasks/main.yaml`

Sketch: `llm_comfyui_enabled` (default `false` until Task 7 lands), a pinned
ComfyUI image with `--gpus all`, models on a host bind-mount under
`/var/lib/comfyui/models` (**not** `/tmp` — see Follow-up finding 5), and the
Flux weights fetched by a `get_url` with a checksum, like the NInfer artifact in
Task 4.

---

## Spike results

Task 3, run 2026-08-22. Ref `403fc56d`, artifact sha256
`eec39564993d6e9c7d5e383382a760f093465c9d163ec9a1bd6b80199514bf3e` (verified).

| Measurement | Value |
|---|---|
| Guest CUDA version | 13.2, driver 595.58.03 |
| Guest total VRAM | 24,576 MiB (no ECC reduction) |
| Image build time | **8.5 min** compile (510 s, 245 objects), zero errors — the 45-90 min estimate was badly wrong |
| Model ID advertised | `qwen3.8-27b` |
| Decode speed (C1) | **37.4 tok/s** mean (35.6 / 36.4 / 40.1) |
| Peak VRAM while serving | 20,046 MiB of 24,576 — 4.5 GiB headroom |
| Model load time | 23.3 s (16.67 GiB weights + 2.75 GiB KV) |
| Gate A (schema) | **conditional pass** — agent loop clean, 2 auxiliary paths blocked |
| Gate B (replay) | **pass** — 3/3 agent-loop requests HTTP 200, `finish=tool_calls`, all tool calls well formed |
| Gate C (live Hermes) | **pass** — completed a multi-step write-then-read terminal task |
| Problems hit | see below |

**Gate B detail.** The captured requests were replayed with only `model` swapped
and `stream` left exactly as Hermes sent it:

```
req-001  HTTP 200  finish='tool_calls'  tool_calls=1 OK
req-007  HTTP 200  finish='tool_calls'  tool_calls=1 OK
req-008  HTTP 200  finish='tool_calls'  tool_calls=1 OK      <- continuation carrying role:tool
req-000  HTTP 400  response_format_not_supported
req-006  HTTP 400  response_format_not_supported
```

"OK" means non-empty `id`, a `function.name` that was actually offered, and
`arguments` that parse as JSON. **The main risk did not materialise**: NInfer's
prompt-rendered tool calls came back well formed over SSE, including on the
continuation turn. That was the single thing most likely to sink this, and it
held.

**Problems hit:**

1. `/tmp` is a 15.7 GiB tmpfs and the artifact is 16.96 GiB — following this
   plan's own instructions wedged the VM. See Follow-up finding 5.
2. `response_format: json_schema` from `title_generation` → 400. Fixed with
   `auxiliary.title_generation.enabled: false`.
3. Ollama-native `/api/show` probes → 404. Fixed with provider `custom`.
4. `ubuntu` is not in the `docker` group (the role only adds `llm`), so the
   build needs `sudo`.

## Benchmark results

All serve Qwen3.8-27B, so this isolates the engine.

Method: 512-token generation (`finish_reason: length`, so token count is fixed
and comparable), identical prompt, model already resident, **first request after
any load discarded**. The final numbers below come from one script
(`bench.py`) run against both engines back to back, which is the only
comparison worth quoting.

| Backend / model | tok/s (mean, range) | Peak VRAM | Notes |
|---|---|---|---|
| Ollama, `qwen3.8:27b-q4_K_M` | 28.0 (27.9-28.0) | 19,121 MiB | 2026-08-20, contended GPU |
| Ollama, `qwen3.8:27b-mtp-q4_K_M` | 31.8 (30.1-33.6) | 19,121 MiB | 2026-08-20, contended GPU |
| Ollama, `qwen3.8:27b-mtp-q4_K_M` | **28.9** (27.8-29.6) | 19,111 MiB | 2026-08-22, clean, two runs agreeing (28.8 / 28.9) |
| NInfer C1, Qwen3.8-27B | **37.4** (35.6-40.1) | 20,046 MiB | 2026-08-22, clean |

**NInfer is ~1.3x Ollama** (37.4 vs 28.9), not the ~1.8x the README's 57 tok/s
figure implied. Two honest caveats on that comparison:

- The 2026-08-20 Ollama figures (31.8) were taken on the contended GPU and are
  ~10% optimistic; the 28.9 pair is the trustworthy one. Quote 1.3x, not 1.2x
  and not 1.8x.
- Upstream reports `decode_tok_s = (completion_tokens - 1) / decode_seconds`,
  which excludes prefill. Here TTFT is only ~55 ms, so NInfer's own counters
  (40.2 / 36.5 / 35.7) agree with the wall-clock numbers above — the metric
  choice is not what accounts for the gap to 57 tok/s.

The gap to upstream's 3090 figure is mostly memory bandwidth: A5000 768 GB/s vs
3090 936 GB/s is 0.82x before any vGPU overhead, and decode is bandwidth-bound.
NInfer's own log shows MTP acceptance at **43.7-46.9%, 2.31-2.40 tokens per
round**, so speculation is working as designed rather than failing.

Cold-load cost: Ollama ~15-20 s for a 17 GB model (removed by
`OLLAMA_KEEP_ALIVE=-1`); NInfer 23.3 s, with no equivalent keep-alive concept
because the process holds the weights for its lifetime.

## Decision

Gates A, B and C pass. The engine is real, it fits with 4.5 GiB to spare, and it
is meaningfully faster. The question for Task 4 is whether **1.3x decode** is
worth what it costs:

- a from-source C++/CUDA build pinned to one commit, with no upstream packaging
- one model per process — Devstral becomes unreachable on this box
- no Ollama-native API, so anything using `/api/*` breaks
- Hermes needs two configuration workarounds that upstream may change under us
- a 17 GiB artifact to fetch, checksum and store outside any package manager

Against that, `OLLAMA_KEEP_ALIVE=-1` and fixing the two-model contention already
removed the multi-second stalls that prompted this whole investigation, and
those were worth far more to perceived speed than 8 tok/s.

Recommendation: **do not promote NInfer to the default yet.** Keep the spike
reproducible (this document plus the pinned ref and checksum), run Hermes on the
tuned Ollama for a week, and revisit if decode speed is still the binding
constraint. Task 8 (Open WebUI in front of the Hermes gateway) is worth more
per hour of work than Task 4-7, and it is backend-agnostic by construction.

> **Superseded 2026-09-20.** Tasks 4-6 are now implemented and NInfer is the
> live backend. What changed the answer was not the decode margin — it is
> 1.45x at the production window, still modest — but that the week on tuned
> Ollama surfaced a harder ceiling: Ollama cannot exceed 131072 tokens on this
> slice at all, and reaching even that took `OLLAMA_CONTEXT_LENGTH` plus q4_0
> KV. NInfer reaches the same window with 1.33 GiB of slack and is faster while
> doing it. The five costs listed above are all still real and all still paid —
> in particular Devstral is now unreachable, and `llm_backend: ollama` is the
> one-line way back. See "Promotion" below.

## Promotion (2026-09-20)

NInfer is the live backend on `ai-vm`. Tasks 4-6 are implemented; Task 7's A/B
is re-run below at the production window.

### What actually unblocked it: ECC

The 2026-08-20 deployment note claimed the card had "no ECC reduction". It was
reading the *guest* vGPU profile size, which is the constant 24,576 MiB and
cannot show ECC at all. On the Proxmox **host**:

```
nvidia-smi --query-gpu=memory.total    23028 MiB     # ECC on
nvidia-smi -e 0 ; reboot
nvidia-smi --query-gpu=memory.total    24564 MiB     # ECC off, +1,536 MiB
```

ECC is a property of the **physical** card, so only a host reboot applies it —
`nvidia-smi -e 0` inside the guest is a no-op, and the setting survives
independently of any VM. That 1,536 MiB is what moved NInfer from a 96K ceiling
to the full 131072: at 131072 the KV arena needs 5,306,938,624 B plus
1,073,741,824 B of headroom, and with ECC on only 5,121,457,152 B remained after
weights — **185 MB short**. With ECC off:

```
KV capacity auto resolved=131072 tokens pages=2048/2048 runtime=4.94 GiB
  free-after-weights=6.27 GiB free-after-startup=1.39 GiB
  headroom=1.00 GiB slack=1.33 GiB
```

Reverting is `nvidia-smi -e 1` on the host plus a reboot — at which point
`llm_ninfer_max_context` must drop to 98304 or NInfer will refuse to start.
This is the one piece of the setup that is **not** in Ansible: it lives on the
Proxmox host, needs a reboot to take effect, and a reboot there stops every
guest. Worth codifying in the host GPU role with an explicit, opt-in reboot.

### Benchmark at the production window (131072, ECC off)

| | Ollama 128K/q4_0 | NInfer 131072/int8 |
|---|---|---|
| Decode | 27.31 tok/s | **39.53 tok/s** (1.45x) |
| VRAM while serving | 19,111 MiB | 22,293 MiB of 24,576 |
| Weights load | — | 16.67 GiB in 22.5 s |
| Max window on this slice | 131072 (hard ceiling) | 131072 with 1.33 GiB slack |

1.45x, not the 1.3x recorded in August (64K, ECC on) nor the 1.75x measured at
64K with ECC off — a bigger KV arena costs decode speed, so quote the number at
the window actually deployed. The decode margin is *not* the reason to promote
it: Ollama's 131072 is a hard ceiling reached only with `OLLAMA_CONTEXT_LENGTH`
and q4_0 KV, while NInfer reaches the same window with room left over.

**Tool-calling gate (never run in August at this config): pass.**

```
tool_calls: [{"function":{"arguments":"{\"city\":\"Oslo\"}","name":"get_weather"},
              "id":"call_3f8529074c02e7b2","type":"function"}]
```

### Three ways the August spike had rotted

1. **The artifact on `main` changed.** `resolve/main/qwen3_8_27b.ninfer` now
   serves 20,437,336,576 B / sha `0634abb0...`, not the 18,210,531,328 B /
   `eec39564...` this plan pins. HF history: `dc370fb6295a 2026-09-06 "Update
   artifact with DFlash2 companion weights"`. Every engine ref tried (403fc56d,
   v0.6.2, master) hard-errors on it: `artifact object was not consumed by the
   selected target: dflash2/feature_projection`, and `--spec dflash2` is
   `invalid speculative backend`. Fixed by pinning the URL to revision
   `18dfc887423f`, which checksums exactly. **The engine ref and the artifact
   revision are a matched pair.**
2. **The branch was force-updated**, exactly as this plan predicted.
   `release/v0.6.0-rtx3090` now points at `49590eba`, not `403fc56d`. The
   pinned SHA still resolves, so the `git` task heals a drifted tree — but the
   branch name is now worthless as a reference.
3. **Tasks 4-7 were never implemented.** There was no `ninfer.yaml`, no unit
   template, no `llm_backend`. The only committed artifact was this document.

### Deviations from the plan as written

- `--max-context 131072`, not 65536, and `--kv-capacity auto` rather than a
  fixed number — `auto` is what the spike verified and it reports its own
  arithmetic on startup, which is how the 185 MB shortfall was diagnosed.
- `--prefill-chunk 1024` dropped: not in the verified spike invocation.
- The unit runs as root like its sibling `comfyui.service`, rather than the
  plan's `User={{ llm_user }}` — both only shell out to `/usr/bin/docker`, and
  this avoids a docker-group dependency for `llm`.
- `Conflicts=` also names `comfyui.service`, and **`comfyui.service.j2` now
  evicts and restores `{{ llm_backend }}` instead of a hard-coded `ollama`**.
  As written it would have started Ollama on top of a running NInfer whenever
  ComfyUI stopped.
- Hermes's `model.provider` is `custom` for NInfer, not the plan's `ollama`.
  The two names select the same OpenAI-compatible profile, but the `ollama`
  alias also switches on native `/api/show` discovery, which NInfer 404s.
- Hermes needs `title_generation.enabled: false` for NInfer: title generation
  sends `response_format: json_schema`, which NInfer answers with 400.

### Boot ordering: gaming vs ai-vm is a race

`ai-vm` has **no `onboot`**; it comes up only because gpu-manager claims it as
`default_tenant`. `gaming` has `onboot = true`. Both want the single 24Q slice.
On this reboot:

```
01:12:28  gpu-manager started
01:12:35  gpu-manager: qmstart 114 (ai-vm)          <- won
01:12:39  pve-guests: start VM 111 (gaming)
01:12:39  pve-guests: could not find a free device for 'hostpci0'   <- lost
```

It resolved the way we want, but by 4 seconds, and nothing enforces it. A boot
where `pve-guests` wins leaves `gaming` holding the card with no Sunshine
session and `ai-vm` down until gpu-manager preempts it a grace period later.
`gaming`'s `onboot = true` predates gpu-manager's `default_tenant` and the two
now express contradictory intent — one of them should go. Not changed here:
it is a design decision, not a bug fix.

### Still open

- **The Ansible run has not been executed end to end.** The unit and Hermes
  config on `ai-vm` were installed from the rendered template and match it
  byte for byte, but `just setup ai-vm` needs a 1Password unlock for the vault
  password, so the idempotency check (`changed=0`) is still owed.
- **`tofu/` changes are inert until applied from the main checkout.** The
  tfvars now declares `llm_ninfer_enabled` / `llm_backend`, but the generated
  playbook still carries `vars: {}` — a deploy from `main` today would reset
  the backend to Ollama.
- **This branch is behind `main`** (it predates the gpu-manager default-tenant
  work) and needs a rebase before merge.
- **Port 8080 is bound to 0.0.0.0 with `auth: disabled`**, same as Ollama's
  11434. Set `llm_ninfer_api_key` from the vault before exposing it over ipid.
- **Devstral is now unreachable.** NInfer serves exactly one artifact.

## Deployment notes (2026-08-20)

Tasks 1 and 2 are deployed to `ai-vm` and verified. Four things came up that the plan as written did not anticipate:

1. **The role never upgraded Ollama.** `Install Ollama` only ran `when: ollama_check.rc != 0`, i.e. when the binary was absent — so `ai-vm` sat on 0.32.9 from its original build. Ollama model manifests carry an engine floor, and both Qwen3.8 pulls failed with `412: The model you are attempting to pull requires a newer version of Ollama`. Verifying that a tag *exists* is not enough; the engine has to be new enough to fetch it. Fixed with `llm_ollama_min_version` (0.32.15) and a version comparison, which upgrades in place.

2. **Two fixes from the previous session were never actually committed.** Commit `e62b0e5` ("wire Hermes through its own config, not OPENAI_* env vars") has a message describing changes to `hermes.yaml` and `ollama.yaml`, but its diff contains **only** the deletion of `templates/hermes-llm.sh.j2`. `main` therefore still had the old env-var Hermes wiring and the non-idempotent model pull, and the deploy failed on a template the same commit had deleted. Both fixes are restored here. Worth remembering: a commit message is not evidence the change landed — `git show --stat` is.

3. ~~**The guest reports the full 24,576 MiB**, with no ECC reduction.~~ **Wrong — corrected 2026-09-20.** The guest reports its *profile* size (24,576 MiB = the 24Q slice), which is a constant and says nothing about ECC. The field that answers the question is `nvidia-smi --query-gpu=memory.total` on the **host**, which read **23,028 MiB** — i.e. ECC was on the whole time and was costing 1,536 MiB. The plan's original worry was right and this note talked everyone out of it; it is exactly the 185 MB that later blocked a 131072-token KV arena. NInfer's C1 profile did still fit at 64K, which is why the error went unnoticed. See "Promotion" below.

4. **Deploying from a worktree needs manual wiring.** `ansible/playbooks/edholm.yaml` and `ansible/inventory/edholm.yaml` are tofu-generated and gitignored, and `terraform.tfstate` lives only in the main checkout — so `tofu apply` from a worktree would see empty state and try to recreate every VM. Do not run it. Instead copy the generated playbook in, and write an inventory whose `project_path` is the **absolute** path to the main checkout's deployment dir (the generated one uses a relative path that would resolve to the worktree's stateless copy). This is only safe while the branch leaves `tofu/` untouched — Task 4 changes tfvars, so it must be applied from the main checkout after merging.

## Follow-up findings (2026-08-21)

1. **`tofu plan` on the main checkout reports "No changes. Your infrastructure
   matches the configuration."** Nothing this branch has done so far touches
   `tofu/`, and no VM is at risk of replacement. The recreate-everything hazard
   is specific to running tofu *from a worktree*, where state is absent — see
   Deployment note 4.

2. **`OLLAMA_KEEP_ALIVE=-1` is set and honoured, but the model still does not
   stay resident** — because two clients are asking `ai-vm` for two different
   17 GB models on a 24 GB slice. `daniel-x1` (192.168.1.151) requests
   `qwen3.6:27b-q4_K_M` while Hermes on-box requests `qwen3.8:27b-mtp-q4_K_M`,
   and Ollama logs `llama-server model predicted to exceed available memory,
   evicting` on nearly every alternation. Observed request latencies of 20 s to
   1 m 35 s, plus 500s at the 30 s mark, all reload stalls rather than slow
   decode.

   This reframes the whole premise. "Hermes is slow" was measured against a GPU
   that was reloading a 17 GB model on most requests. The **first** thing to fix
   is one model per GPU; only then is a decode-speed comparison meaningful.
   Concretely: repoint whatever on `daniel-x1` still targets Qwen3.6 at
   `qwen3.8:27b-mtp-q4_K_M`, then `ollama rm qwen3.6:27b-q4_K_M` so it cannot be
   loaded by accident. The role does not remove models it no longer lists, which
   is why the stale tag is still pullable.

   The same constraint applies to the NInfer plan: NInfer and Ollama cannot both
   hold a model on this slice, which is why Task 3 stops Ollama and why Task 5's
   backend switch has to be exclusive rather than side-by-side.

3. **Hermes' reasoning effort is already `medium`.** `hermes config get
   agent.reasoning_effort` returns `medium`, which is also Hermes' documented
   fallback when unset (`hermes_constants.py`: "Unknown reasoning_effort '%s',
   using default (medium)"). Valid levels are `none`, `minimal`, `low`, `medium`,
   `high`, `xhigh`, `max`, `ultra`. Per-model overrides live under
   `agent.reasoning_overrides` and must be edited in `config.yaml` directly —
   `hermes config set` cannot address those keys because model names contain
   dots.

4. **Ollama does map `reasoning_effort` onto Qwen3.8's thinking budget.**
   `qwen3.8:27b-mtp-q4_K_M` advertises a `thinking` capability; `/api/chat`
   accepts `think: low|medium|high` and `/v1/chat/completions` accepts
   `reasoning_effort`, with the thinking text returned separately from
   `content`. So effort is controllable per-request at the API, not only
   globally in Hermes' config.

5. **`/tmp` on `ai-vm` is tmpfs, sized 15.7 GiB — and I filled it, wedging the
   VM.** The spike text in this very document said to download the 16.96 GiB
   artifact to `/tmp/ninfer-spike/models/`. It reached 13.4 GiB, consumed that
   much RAM as shared memory, and the box stopped accepting TCP while still
   answering ping. It did not self-heal for hours: the OOM killer cannot reclaim
   tmpfs pages while the file exists. `rm` freed it instantly (shared 12 GiB ->
   138 MiB) and no reboot was needed.

   The artifact could never have fit — 16.96 GiB into a 15.7 GiB tmpfs. Every
   spike path in this plan now points at `/var/lib/`, and Task 9's ComfyUI
   weights carry the same warning. Check `findmnt /tmp` before writing anything
   large to it on any host.

6. **Gate A ran against a real Hermes agent turn, and found two incompatibilities
   the code reading missed.** 11 requests captured through a transparent relay
   while Hermes completed a multi-step tool task (it correctly answered "16 files
   in /etc modified in the last 7 days"):

   | Request | Shape | NInfer |
   |---|---|---|
   | main agent loop (x3) | `stream=true`, 25 tools, incl. one continuation carrying `role: tool` + assistant `tool_calls` | **accepted** |
   | session title (x2) | `response_format: {type: json_schema, strict: true}` | **400 `response_format_not_supported`** |
   | `/api/show` (x6) | Ollama-native capability probe | **404 — endpoint does not exist** |

   So the earlier claim that "Hermes' chat path does not send `response_format`"
   was wrong. Grepping `*.py` found only vendored SDK types; the
   `title_generation` auxiliary task sends json_schema at runtime. This is
   exactly the failure mode Gate A exists to catch, and it is why a static read
   is not a test.

   Neither blocker is fatal, and both have a fix that belongs in Task 6:

   - `auxiliary.title_generation.enabled: false` stops the json_schema request.
     Manual titles still work.
   - `/api/show` is probed because the provider is `ollama`, which Hermes treats
     as Ollama-native for its context-length and `thinking` capability probe
     (`agent/model_metadata.py`, `run_agent.py`). Under NInfer the provider must
     be `custom` instead, with the context length supplied explicitly rather than
     discovered.

   The important half is the positive result: **the agent loop itself — streaming,
   25 tools, and a tool-result continuation turn — is entirely within NInfer's
   accepted schema.** Gate A passes conditionally; Gate B still has to prove the
   tool-call *parser* produces well-formed calls.

7. **Open WebUI reached the host on the wrong interface, and the play passed
   anyway.** `host.docker.internal` resolves to the docker bridge gateway
   (172.17.0.1), not loopback, while Hermes' API server defaults to binding
   127.0.0.1. So Open WebUI got connection-refused (`health=000`) while every
   host-side verification task returned 200 — they were testing a different
   interface. Fixed by discovering the bridge gateway and setting
   `API_SERVER_HOST` to it, which also keeps the agent API off the LAN while
   port 3000 stays the front door. The real fix is the extra task that checks
   the path Open WebUI actually uses, `docker exec open-webui curl ...`: a
   verification that does not traverse the same route as the traffic proves
   nothing.

8. **`hermes config get` exits 1 on an unset key**, which under `set -euo
   pipefail` aborted the whole config task before it could set anything. The
   pre-existing `hermes.yaml` loop had the same latent bug and only worked
   because its keys were already set — a fresh VM would have failed there too.
   Both now tolerate it with `|| true`.

   Related: that task carried `no_log: true` over the whole loop, so the failure
   surfaced as three censored blocks with no message. The secret is now set in
   its own task and only that one is silenced.

9. **`API_SERVER_KEY` lands in `config.yaml`, not `~/.hermes/.env`** as the
   upstream docs state. Worth knowing before grepping the wrong file.

10. **Every Open WebUI turn carries ~15.6k prompt tokens** of agent system
    prompt and skills before the user's own message. That is the cost of talking
    to the agent rather than the raw model, and it is why chat latency there
    will not match a bare Ollama call.

## Open items

- **Hermes API-key config key** is unverified (Task 6 Step 3). Needed only when the port is exposed over ipid.
- **Open WebUI and ComfyUI** are out of scope here but depend on Task 2. Whichever backend wins, both speak the OpenAI API, so Open WebUI needs only a base-URL change to follow.
- **Devstral availability**: NInfer serves one model per process. If `llm_backend = ninfer` wins, Devstral is no longer reachable on `ai-vm`. Decide then whether that matters.
- **Client compatibility**: anything speaking Ollama's *native* API (`/api/tags`, `/api/chat`) breaks under NInfer, which serves only the OpenAI and Anthropic shapes. Phone and desktop clients should point at Open WebUI rather than at the engine directly, so the backend can change underneath them.
