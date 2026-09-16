# GPU Session Signal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give gpu-manager a session signal it can actually read, so the idle
grace period fires and the card comes free on its own.

**Architecture:** The gaming guest's Sunshine hooks report session start/end to
the daemon over HTTP, replacing a shared-directory contract that was broken in
three independent ways. `activity` stops reading the filesystem and becomes
API-fed, with a TTL that decays a silent reporter to `unknown` — never to
`idle`. The daemon then publishes the idle clock so a status command can show
when the card will come free.

**Tech Stack:** Go 1.x (stdlib only: `net/http`, `encoding/json`,
`gopkg.in/yaml.v3`); Ansible + Jinja2; pytest for template tests; fish.

**Spec:** `docs/superpowers/specs/2026-09-15-gpu-session-signal-design.md`

## Global Constraints

- **Three repos.** `gpu-manager` is at `/home/daniele/Repos/gpu-manager`,
  `terranse` at `/home/daniele/Repos/terranse`, `computer-configs` at
  `/home/daniele/Repos/computer-configs`. Each task names its repo. Commit in
  the repo the task touches.
- **An expired heartbeat means `unknown`, never `idle`.** Only an explicit
  session-ended report produces `idle`. This is the invariant the whole design
  rests on: silence does not mean nobody is playing, and treating it as idle
  would evict a live game.
- **Sunshine hooks must never fail the stream.** They run as
  `global_prep_cmd`; a non-zero exit aborts the stream/app launch. Every hook
  swallows all errors and ends in `exit 0`.
- **Guest reaches the daemon at `http://192.168.1.200:8080`** (workstation's
  LAN address on `vmbr0`). The guest is on the LAN; the netbird name is not
  reachable from it.
- **Sunshine runs as `gamer`** under that user's `systemd --user`. The role
  variable is `gaming_user` (defaults to `gamer` in
  `ansible/roles/gaming/defaults/main.yaml:5`).
- **The daemon's VM names are its config keys** (`gaming`, `ai-vm`), from
  `config.yaml`'s `vms:` map. A report must use that name, not an incidental
  hostname.
- **Do not run `tofu apply` or `just apply`.** Tasks end at a commit; deploying
  is the operator's call.
- **Go checks** after every Go change: `gofmt -l .` (must print nothing),
  `go vet ./...`, `go test ./...`.
- **Commit trailer:** end every commit message with
  `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`.
  Never add a `Claude-Session:` trailer.

---

## File Structure

**gpu-manager**
- Modify `internal/activity/activity.go` — becomes API-fed; `Scan()` and all
  filesystem reads removed; gains `Report`.
- Modify `internal/activity/activity_test.go` — all four existing tests test
  the removed filesystem mechanism and are replaced.
- Modify `internal/config/config.go` — add `SessionTTLS`/`SessionTTL()`, remove
  `SessionDir` and its required check.
- Modify `internal/config/config_test.go` — drop the `session_dir` tests, add
  `session_ttl_s` ones.
- Modify `internal/server/server.go` — add `PUT`/`DELETE /v1/sessions/{vm}`;
  `New` takes the `*activity.Activity`.
- Modify `internal/state/state.go` — `VMState.IdleForS`, `Doc.GracePeriodS`.
- Modify `internal/reconcile/loop.go` — drop the `Act.Scan()` call; publish the
  new fields.
- Modify `internal/ctl/ctl.go` — render the idle clock.
- Modify `cmd/gpu-manager/main.go` — new `activity.New` and `server.New` calls.
- Modify `config.example.yaml`, `README.md`.

**terranse**
- Modify `ansible/roles/gaming/templates/sunshine-session-start.sh.j2` and
  `sunshine-session-stop.sh.j2` — curl the API.
- Create `ansible/roles/gaming/templates/sunshine-heartbeat.service.j2` and
  `sunshine-heartbeat.timer.j2`.
- Modify `ansible/roles/gaming/tasks/sunshine.yaml` — install the timer units.
- Modify `ansible/roles/gaming/defaults/main.yaml` — `gpu_manager_vm_name`.
- Modify `ansible/roles/gaming/tasks/game-storage.yaml`,
  `templates/cloud-init-gaming.yaml.j2`,
  `ansible/roles/gaming-storage/tasks/main.yaml`,
  `ansible/roles/gaming-storage/templates/exports.j2`,
  `ansible/roles/gpu-manager/files/health-check.sh` — remove the dead
  session-state plumbing.
- Modify `ansible/roles/gpu-manager/defaults/main.yaml` and
  `templates/gpu-manager.config.yaml.j2` — swap `session_dir` for
  `session_ttl_s`.
- Modify `tofu/deployments/edholm/main.tf` — carry `host` in `gaming_vms`.
- Modify `tofu/deployments/edholm/configurations.tfvars` —
  `gpu_manager_api_url`.
- Modify `tests/conftest.py`, `tests/unit/templates/test_templates.py`.

**computer-configs**
- Modify `home/terminal.nix` — the `gpu` function's `status` verb.

---

### Task 1: Activity becomes API-fed

**Repo:** `gpu-manager`

**Files:**
- Modify: `internal/activity/activity.go` (whole file)
- Modify: `internal/activity/activity_test.go` (whole file)
- Modify: `internal/config/config.go:46` (field), `:94-96` (required check)
- Modify: `internal/config/config_test.go:16`, `:126-130`, `:154`
- Modify: `internal/reconcile/loop.go:321` (the `l.Act.Scan()` line)
- Modify: `internal/reconcile/loop_test.go:18-23`, `:147`, `:154`, `:385-386`
- Modify: `cmd/gpu-manager/main.go:69`
- Modify: `config.example.yaml:18`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `activity.New(ttl time.Duration, now func() time.Time, vms []string) *Activity`
  - `(*Activity).Report(vm string, active bool)`
  - `(*Activity).State(vm string) string` / `Active(vm) bool` /
    `Unknown(vm) bool` / `IdleFor(vm) time.Duration` — unchanged signatures
  - `(*config.Config).SessionTTL() time.Duration`, field `SessionTTLS int`
  - `Scan()` no longer exists.

- [ ] **Step 1: Replace the activity tests**

Replace the entire body of `internal/activity/activity_test.go` (all four
existing tests read the filesystem mechanism this task removes):

```go
package activity

import (
	"testing"
	"time"

	"edholm.dev/gpu-manager/internal/state"
)

// A VM nobody has reported on is unknown. It is not idle: the daemon has
// simply never been told, and idle is what starts an eviction clock.
func TestUnreportedVMIsUnknown(t *testing.T) {
	now := time.Unix(1000, 0)
	a := New(3*time.Minute, func() time.Time { return now }, []string{"gaming"})

	if got := a.State("gaming"); got != state.SessionUnknown {
		t.Fatalf("state: %q", got)
	}
	if got := a.IdleFor("gaming"); got != 0 {
		t.Fatalf("an unknown session must report no idle time, got %v", got)
	}
}

func TestReportedSessionIsActive(t *testing.T) {
	now := time.Unix(1000, 0)
	a := New(3*time.Minute, func() time.Time { return now }, []string{"gaming"})

	a.Report("gaming", true)

	if !a.Active("gaming") {
		t.Fatalf("state: %q", a.State("gaming"))
	}
	if got := a.IdleFor("gaming"); got != 0 {
		t.Fatalf("an active session must report no idle time, got %v", got)
	}
}

// A session reported ended is idle, and the idle clock runs from that report
// -- that clock is what the grace period is measured against.
func TestEndedSessionIsIdleAndAccruesTime(t *testing.T) {
	now := time.Unix(1000, 0)
	a := New(3*time.Minute, func() time.Time { return now }, []string{"gaming"})

	a.Report("gaming", true)
	now = now.Add(time.Minute)
	a.Report("gaming", false)
	now = now.Add(2 * time.Minute)

	if got := a.State("gaming"); got != state.SessionIdle {
		t.Fatalf("state: %q", got)
	}
	if got := a.IdleFor("gaming"); got != 2*time.Minute {
		t.Fatalf("idle: %v", got)
	}
}

// The invariant the whole design rests on: a reporter that goes quiet decays
// to unknown, NOT to idle. Silence does not mean nobody is playing, and idle
// would start a 300s clock toward shutting a live game down.
func TestSilentReporterDecaysToUnknownNotIdle(t *testing.T) {
	now := time.Unix(1000, 0)
	a := New(3*time.Minute, func() time.Time { return now }, []string{"gaming"})

	a.Report("gaming", true)
	now = now.Add(3*time.Minute + time.Second)

	if got := a.State("gaming"); got != state.SessionUnknown {
		t.Fatalf("state: %q, want unknown", got)
	}
	if got := a.IdleFor("gaming"); got != 0 {
		t.Fatalf("a decayed session must report no idle time, got %v", got)
	}
}

// A heartbeat inside the TTL keeps it active indefinitely.
func TestHeartbeatKeepsSessionActive(t *testing.T) {
	now := time.Unix(1000, 0)
	a := New(3*time.Minute, func() time.Time { return now }, []string{"gaming"})

	a.Report("gaming", true)
	for i := 0; i < 10; i++ {
		now = now.Add(time.Minute)
		a.Report("gaming", true)
	}

	if !a.Active("gaming") {
		t.Fatalf("state: %q", a.State("gaming"))
	}
}

// A decayed session is not a dead one: the next heartbeat restores it.
func TestHeartbeatAfterDecayRestoresActive(t *testing.T) {
	now := time.Unix(1000, 0)
	a := New(3*time.Minute, func() time.Time { return now }, []string{"gaming"})

	a.Report("gaming", true)
	now = now.Add(10 * time.Minute)
	if got := a.State("gaming"); got != state.SessionUnknown {
		t.Fatalf("expected decay first, got %q", got)
	}

	a.Report("gaming", true)

	if !a.Active("gaming") {
		t.Fatalf("state: %q", a.State("gaming"))
	}
}

// An idle session does not decay. Idle is a fact somebody reported, not a
// guess that goes stale, and the grace clock must keep running.
func TestIdleSessionDoesNotDecay(t *testing.T) {
	now := time.Unix(1000, 0)
	a := New(3*time.Minute, func() time.Time { return now }, []string{"gaming"})

	a.Report("gaming", false)
	now = now.Add(time.Hour)

	if got := a.State("gaming"); got != state.SessionIdle {
		t.Fatalf("state: %q, want idle", got)
	}
	if got := a.IdleFor("gaming"); got != time.Hour {
		t.Fatalf("idle: %v", got)
	}
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd /home/daniele/Repos/gpu-manager && go test ./internal/activity/`
Expected: FAIL to build — `New` takes a `string` dir, not a `time.Duration`,
and `Report` is undefined.

- [ ] **Step 3: Rewrite activity.go**

Replace the entire file `internal/activity/activity.go`:

```go
// Package activity tracks which VMs have a live streaming session, as the
// guests themselves report it over the daemon's HTTP API.
//
// It replaced a scan of a shared directory that no party could actually see:
// the host had no such mount, the guest wrote a filename the daemon did not
// look for, and ending a session left the marker in place. A guest that can
// reach the daemon can simply say so.
package activity

import (
	"sync"
	"time"

	"edholm.dev/gpu-manager/internal/state"
)

// Activity answers "is anyone using this VM" in three values, because the
// honest answer is sometimes that we cannot tell. The daemon releases idle
// game VMs, so a reporter that has gone quiet must not be read as an empty
// one.
type Activity struct {
	ttl time.Duration
	now func() time.Time

	mu       sync.Mutex
	sessions map[string]string // state.SessionActive | Idle | Unknown
	lastSeen map[string]time.Time
}

// New returns an Activity that treats an active session with no report inside
// ttl as unknown. vms seeds the known VMs; before their first report the
// daemon genuinely does not know.
func New(ttl time.Duration, now func() time.Time, vms []string) *Activity {
	a := &Activity{ttl: ttl, now: now,
		sessions: map[string]string{}, lastSeen: map[string]time.Time{}}
	start := now()
	for _, vm := range vms {
		a.sessions[vm] = state.SessionUnknown
		a.lastSeen[vm] = start
	}
	return a
}

// Report records what a guest says about its own session. active=true is both
// "a session is live" and the heartbeat that keeps it live; active=false is a
// session that ended cleanly, and is the only thing that starts an idle clock.
func (a *Activity) Report(vm string, active bool) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if active {
		a.sessions[vm] = state.SessionActive
	} else {
		a.sessions[vm] = state.SessionIdle
	}
	a.lastSeen[vm] = a.now()
}

// State is vm's session: state.SessionActive, SessionIdle or SessionUnknown.
//
// An active session whose reporter has gone quiet for longer than the TTL
// reads as unknown -- never as idle. Silence does not tell us the session
// ended, and calling it idle would start the grace clock on a VM that may
// well have somebody playing on it. Decay is computed, not stored, so the
// next heartbeat restores the session without special handling.
func (a *Activity) State(vm string) string {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.stateLocked(vm)
}

func (a *Activity) stateLocked(vm string) string {
	s := a.sessions[vm]
	if s == state.SessionActive && a.now().Sub(a.lastSeen[vm]) > a.ttl {
		return state.SessionUnknown
	}
	return s
}

func (a *Activity) Active(vm string) bool { return a.State(vm) == state.SessionActive }

// Unknown reports whether vm's session could not be determined. Callers must
// treat this as "possibly in use", never as idle.
func (a *Activity) Unknown(vm string) bool { return a.State(vm) == state.SessionUnknown }

// IdleFor is how long vm has had no session. It is zero unless we actually
// know the VM is idle, so an unknown session can never age into a release.
func (a *Activity) IdleFor(vm string) time.Duration {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.stateLocked(vm) != state.SessionIdle {
		return 0
	}
	return a.now().Sub(a.lastSeen[vm])
}
```

- [ ] **Step 4: Run the activity tests to verify they pass**

Run: `cd /home/daniele/Repos/gpu-manager && go test ./internal/activity/ -v`
Expected: PASS, all seven tests.

- [ ] **Step 5: Write the failing config tests**

In `internal/config/config_test.go`: delete
`TestLoadRejectsMissingSessionDir` (lines 126-130) entirely, and replace the
`session_dir: /mnt/gaming/session-state` line inside the `sample` const
(line 16) with `session_ttl_s: 180`. There is a second `session_dir` line at
`:154` inside another fixture string — replace it the same way. Then append:

```go
func TestSessionTTLDefaultsTo180s(t *testing.T) {
	withoutTTL := strings.Replace(sample, "session_ttl_s: 180", "", 1)
	c, err := Load(write(t, withoutTTL))
	if err != nil {
		t.Fatal(err)
	}
	if c.SessionTTL() != 180*time.Second {
		t.Fatalf("ttl: %v", c.SessionTTL())
	}
}

func TestLoadRejectsNegativeSessionTTL(t *testing.T) {
	bad := strings.Replace(sample, "session_ttl_s: 180", "session_ttl_s: -1", 1)
	if _, err := Load(write(t, bad)); err == nil {
		t.Fatal("expected a negative session_ttl_s to be rejected")
	}
}

// session_dir was the old filesystem mechanism. A config that still carries it
// must load anyway, so the daemon can be upgraded before Ansible stops
// emitting it.
func TestLoadIgnoresLeftoverSessionDir(t *testing.T) {
	old := sample + "session_dir: /mnt/gaming/session-state\n"
	if _, err := Load(write(t, old)); err != nil {
		t.Fatalf("a leftover session_dir must not break loading: %v", err)
	}
}
```

- [ ] **Step 6: Run the config tests to verify they fail**

Run: `cd /home/daniele/Repos/gpu-manager && go test ./internal/config/`
Expected: FAIL to build — `c.SessionTTL` is undefined.

- [ ] **Step 7: Change the config**

In `internal/config/config.go`, replace the `SessionDir` field (line 46):

```go
	// SessionTTLS is how long an active session survives without a report
	// before it reads as unknown. Guests heartbeat while a session is live.
	SessionTTLS int `yaml:"session_ttl_s"`
```

Delete the required check (lines 94-96):

```go
	if c.SessionDir == "" {
		return fmt.Errorf("config: session_dir is required")
	}
```

and in its place put, next to the other duration defaults:

```go
	if c.SessionTTLS < 0 {
		return fmt.Errorf("config: session_ttl_s must not be negative")
	}
	if c.SessionTTLS == 0 {
		c.SessionTTLS = 180
	}
```

Add the accessor next to `GracePeriod()`:

```go
// SessionTTL bounds how long a reported session is believed without a
// further report.
func (c *Config) SessionTTL() time.Duration {
	return time.Duration(c.SessionTTLS) * time.Second
}
```

- [ ] **Step 8: Run the config tests to verify they pass**

Run: `cd /home/daniele/Repos/gpu-manager && go test ./internal/config/ -v`
Expected: PASS.

- [ ] **Step 9: Fix the remaining call sites**

`internal/reconcile/loop.go` — delete line 321, `l.Act.Scan()`, and the blank
line after it. (`observe` no longer needs to pull; reports arrive via the API.)

`cmd/gpu-manager/main.go:69` — change:

```go
		Act:   activity.New(cfg.SessionTTL(), time.Now, vmNames),
```

`internal/reconcile/loop_test.go` — replace the `writeSession` helper
(lines 18-23) with:

```go
// reportSession is what a guest's Sunshine hook does over the API.
func reportSession(l *Loop, vm string) {
	l.Act.Report(vm, true)
}
```

Update the three call sites (`writeSession(t, l, "gaming-1")` at lines 319,
337 and 360) to `reportSession(l, "gaming-1")`. In `newLoop` (line 147) delete
`c.SessionDir = t.TempDir()` and change line 154 to:

```go
		Act:          activity.New(c.SessionTTL(), time.Now, []string{"gaming-1", "gaming-2", "ai-vm"}),
```

`cfg()` in `planner_test.go` does not set `SessionTTLS`, so `SessionTTL()`
returns 0 there and every reported session would decay instantly. Add
`SessionTTLS: 180` to the `cfg()` literal in
`internal/reconcile/planner_test.go:13-26`.

In `TestUnknownSessionProtectsARunningHolder` (lines 380-386) replace the two
lines that rebuild `Act` against a missing directory with a comment and
nothing else — a fresh `Act` already reports `unknown`, which is the condition
this test wants:

```go
	l := newLoop(t, vm, gpu)
	// No session has been reported for gaming-1, so its activity is unknown.
```

Then drop the now-unused `os` and `path/filepath` imports from `loop_test.go`.
The Go compiler refuses to build with an unused import and names each one, so
run the build and remove exactly what it lists — do not guess. (`activity` and
`time` are still used by `newLoop`, so they stay.)

- [ ] **Step 10: Verify the whole suite**

Run:
```bash
cd /home/daniele/Repos/gpu-manager && gofmt -l . && go vet ./... && go test ./...
```
Expected: `gofmt -l .` prints nothing; vet silent; all packages `ok`.

- [ ] **Step 11: Update the example config**

In `config.example.yaml`, replace line 18 and its comment block about
`session_dir` with:

```yaml
# How long an active session is believed without a further report from the
# guest. Sunshine's hooks report a session start and end, and a timer
# heartbeats every 60s while one is live, so three missed heartbeats means the
# reporter is gone. A session that decays this way reads as *unknown*, never
# as idle: silence does not mean nobody is playing.
session_ttl_s: 180
```

- [ ] **Step 12: Commit**

```bash
cd /home/daniele/Repos/gpu-manager
git add internal/activity internal/config internal/reconcile cmd config.example.yaml
git commit -m "$(cat <<'EOF'
refactor(activity): take sessions from the guests, not from a directory

The directory nobody could see: session_dir was absent on the host, an
empty local dir in the guest (the NFS mount went away when storage moved
to virtiofs), the hook wrote <hostname>.session while the daemon stat'd
<vm-name>, and ending a session left the marker in place. Every VM read
`unknown` forever, so the grace period never once fired.

Activity is now fed by Report(), with a TTL that decays a silent reporter
to unknown -- never to idle, because silence does not mean nobody is
playing. Nothing reports yet, so behaviour is unchanged until the
endpoints land.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: The session endpoints

**Repo:** `gpu-manager`

**Files:**
- Modify: `internal/server/server.go`
- Modify: `internal/server/server_test.go:19-30` (the `testServer` helper)
- Modify: `cmd/gpu-manager/main.go` (the `server.New` call)
- Modify: `README.md`

**Interfaces:**
- Consumes: `activity.New`, `(*Activity).Report` from Task 1.
- Produces:
  - `server.New(store *reconcile.Store, cfg *config.Config, trigger chan<- struct{}, act *activity.Activity) http.Handler`
  - `PUT /v1/sessions/{vm}` → `200` + the state doc; `DELETE /v1/sessions/{vm}`
    → `204`; both `400` on an unknown vm.

- [ ] **Step 1: Write the failing tests**

Append to `internal/server/server_test.go`:

```go
func TestPutSessionMarksActiveAndTriggers(t *testing.T) {
	ts, _, trigger := testServer(t)

	req, _ := http.NewRequest(http.MethodPut, ts.URL+"/v1/sessions/ai-vm", nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Fatalf("status: %d", resp.StatusCode)
	}
	select {
	case <-trigger:
	default:
		t.Fatal("a session report should trigger a reconcile")
	}
}

func TestDeleteSessionMarksIdle(t *testing.T) {
	ts, _, _ := testServer(t)

	req, _ := http.NewRequest(http.MethodPut, ts.URL+"/v1/sessions/ai-vm", nil)
	if _, err := http.DefaultClient.Do(req); err != nil {
		t.Fatal(err)
	}
	req, _ = http.NewRequest(http.MethodDelete, ts.URL+"/v1/sessions/ai-vm", nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 204 {
		t.Fatalf("status: %d", resp.StatusCode)
	}
}

// A report for a VM this daemon does not know is a configuration mistake on
// the reporter's side, and saying so is more use than silently recording it.
func TestSessionRejectsUnknownVM(t *testing.T) {
	ts, _, _ := testServer(t)

	for _, method := range []string{http.MethodPut, http.MethodDelete} {
		req, _ := http.NewRequest(method, ts.URL+"/v1/sessions/nope", nil)
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.StatusCode != 400 {
			t.Fatalf("%s: status %d, want 400", method, resp.StatusCode)
		}
	}
}
```

The `testServer` helper must hand back the Activity so the tests above can be
extended later; change its signature and body (lines 19-30) to:

```go
func testServer(t *testing.T) (*httptest.Server, *reconcile.Store, chan struct{}) {
	t.Helper()
	cfg := &config.Config{
		Profiles:    map[string]config.Profile{"Q-24C": {VRAMMB: 24576, MaxInstances: 1, MdevType: "nvidia-261"}},
		VMs:         map[string]config.VM{"ai-vm": {VMID: 300, Tier: "ai"}},
		SessionTTLS: 180,
	}
	store := reconcile.NewStore(cfg)
	trigger := make(chan struct{}, 8)
	act := activity.New(cfg.SessionTTL(), time.Now, []string{"ai-vm"})
	ts := httptest.NewServer(New(store, cfg, trigger, act))
	t.Cleanup(ts.Close)
	return ts, store, trigger
}
```

Add `"edholm.dev/gpu-manager/internal/activity"` to that file's imports.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd /home/daniele/Repos/gpu-manager && go test ./internal/server/`
Expected: FAIL to build — `New` takes three arguments, not four.

- [ ] **Step 3: Add the endpoints**

In `internal/server/server.go`, change the signature and add the handlers
after the `DELETE /v1/claims/{vm}` block:

```go
func New(store *reconcile.Store, cfg *config.Config, trigger chan<- struct{},
	act *activity.Activity) http.Handler {
```

```go
	// Session reports. The guest's Sunshine hooks are the only thing that
	// knows whether somebody is streaming, so they say so here. A PUT is both
	// "a session is live" and the heartbeat that keeps it live; a DELETE is a
	// session that ended, and is the only thing that starts an idle clock.
	//
	// There is deliberately no GET: the session is already published in
	// /v1/state as vms[].session, and a second read path for one fact is one
	// more thing to keep consistent.
	session := func(active bool, code int) http.HandlerFunc {
		return func(w http.ResponseWriter, r *http.Request) {
			vm := r.PathValue("vm")
			if _, ok := cfg.VMs[vm]; !ok {
				http.Error(w, fmt.Sprintf("unknown vm %q", vm), http.StatusBadRequest)
				return
			}
			act.Report(vm, active)
			// A session ending is what starts the grace clock, and a session
			// starting can unblock a claim that was pending on activity, so
			// both are worth a pass rather than waiting out the ticker.
			kick()
			if code == http.StatusNoContent {
				w.WriteHeader(code)
				return
			}
			writeJSON(w, store.Snapshot())
		}
	}
	mux.HandleFunc("PUT /v1/sessions/{vm}", session(true, http.StatusOK))
	mux.HandleFunc("DELETE /v1/sessions/{vm}", session(false, http.StatusNoContent))
```

Add `"edholm.dev/gpu-manager/internal/activity"` to the imports.

- [ ] **Step 4: Update main.go**

In `cmd/gpu-manager/main.go`, the `Act` value is currently built inline inside
the `Loop` literal. Hoist it so the server can share it. Replace:

```go
		Act:   activity.New(cfg.SessionTTL(), time.Now, vmNames),
```

by declaring it above the `loop := &reconcile.Loop{...}` literal:

```go
	act := activity.New(cfg.SessionTTL(), time.Now, vmNames)
```

use `Act: act,` in the literal, and change the `http.Server` construction:

```go
	srv := &http.Server{Addr: cfg.Listen, Handler: server.New(store, cfg, trigger, act),
		ReadHeaderTimeout: 5 * time.Second}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd /home/daniele/Repos/gpu-manager && gofmt -l . && go vet ./... && go test ./...`
Expected: `gofmt -l .` prints nothing; all packages `ok`.

- [ ] **Step 6: Document the endpoints in the README**

In `README.md`, after the `DELETE /v1/claims/{vm}` section, add:

````markdown
**`PUT /v1/sessions/{vm}`** — report that a streaming session is live on `vm`.
Idempotent, and doubles as the heartbeat: an active session with no report for
`session_ttl_s` decays to `unknown`. Responds with the state document; `400`
on an unknown vm.

```bash
curl -X PUT http://127.0.0.1:8080/v1/sessions/gaming
```

**`DELETE /v1/sessions/{vm}`** — report that the session ended. This is the
only thing that makes a VM `idle`, and therefore the only thing that starts
the `grace_period_s` clock. Responds `204 No Content`.

```bash
curl -X DELETE http://127.0.0.1:8080/v1/sessions/gaming
```

There is no `GET /v1/sessions/{vm}`: sessions are published in `/v1/state` as
`vms[].session`.
````

- [ ] **Step 7: Commit**

```bash
cd /home/daniele/Repos/gpu-manager
git add internal/server cmd README.md
git commit -m "$(cat <<'EOF'
feat(server): let the guests report their own sessions

PUT /v1/sessions/{vm} says a session is live and heartbeats it; DELETE
says it ended, which is the only thing that starts the grace clock. Both
kick a reconcile rather than waiting out the ticker. No GET: the session
is already in /v1/state as vms[].session.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Publish the idle clock

**Repo:** `gpu-manager`

**Files:**
- Modify: `internal/state/state.go` (`VMState`, `Doc`)
- Modify: `internal/reconcile/loop.go` (the `vms = append(...)` block in
  `observe`, and the `l.Store.update` call that sets `d.GPU`/`d.VMs`)
- Modify: `internal/reconcile/loop_test.go` (new test)
- Modify: `internal/ctl/ctl.go` (`printDoc`)

**Interfaces:**
- Consumes: `(*Activity).IdleFor` from Task 1.
- Produces: `state.VMState.IdleForS int` (JSON `idle_for_s`, omitempty),
  `state.Doc.GracePeriodS int` (JSON `grace_period_s`).

- [ ] **Step 1: Write the failing test**

Append to `internal/reconcile/loop_test.go`:

```go
// Status needs the clock, not just the verdict: "session=idle" with no
// elapsed time cannot tell you when the card is about to come free.
func TestObservePublishesTheIdleClock(t *testing.T) {
	gpu := newFakeGPU(held("0000:0e:00.4", 26, "nvidia-664", 201), free("0000:0e:00.5", 27))
	vm := &fakeVM{power: map[int]drivers.Power{201: drivers.PowerRunning, 202: drivers.PowerStopped,
		300: drivers.PowerStopped}, mdev: map[int]string{201: "nvidia-664"}}
	l := newLoop(t, vm, gpu)

	now := time.Unix(1000, 0)
	l.Act = activity.New(l.Cfg.SessionTTL(), func() time.Time { return now },
		[]string{"gaming-1", "gaming-2", "ai-vm"})
	l.Act.Report("gaming-1", false) // the session ended
	now = now.Add(90 * time.Second)

	if _, err := l.observe(context.Background()); err != nil {
		t.Fatal(err)
	}

	doc := l.Store.Snapshot()
	if doc.GracePeriodS != 300 {
		t.Fatalf("the doc should echo the grace period, got %d", doc.GracePeriodS)
	}
	for _, v := range doc.VMs {
		switch v.Name {
		case "gaming-1":
			if v.IdleForS != 90 {
				t.Fatalf("gaming-1 idle_for_s: %d, want 90", v.IdleForS)
			}
		default:
			// Never reported, so unknown -- and an unknown session must not
			// publish a duration, which would imply knowledge we lack.
			if v.IdleForS != 0 {
				t.Fatalf("%s idle_for_s: %d, want 0", v.Name, v.IdleForS)
			}
		}
	}
}
```

`"edholm.dev/gpu-manager/internal/activity"` and `"time"` are already imported
in `loop_test.go` (Task 1 kept both for `newLoop`), so no import change is
needed here.

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd /home/daniele/Repos/gpu-manager && go test ./internal/reconcile/ -run TestObservePublishesTheIdleClock`
Expected: FAIL to build — `doc.GracePeriodS` and `v.IdleForS` are undefined.

- [ ] **Step 3: Add the fields**

In `internal/state/state.go`, add to `VMState` after `Session`:

```go
	// IdleForS is seconds since the session on this VM was reported ended.
	// Omitted unless the VM is actually idle: for an active VM it is
	// meaningless, and for an unknown one a duration would imply knowledge
	// the daemon does not have.
	IdleForS int `json:"idle_for_s,omitempty"`
```

and to `Doc`, after `Seq`:

```go
	// GracePeriodS is echoed from config so a client can render "idle
	// 90s/300s" without having to read the daemon's configuration.
	GracePeriodS int `json:"grace_period_s"`
```

- [ ] **Step 4: Populate them**

In `internal/reconcile/loop.go`, inside `observe`, the per-VM loop builds
`state.VMState`. Add the idle seconds to that literal:

```go
		vms = append(vms, state.VMState{Name: name, VMID: vm.VMID, Power: string(p),
			Session: l.Act.State(name), Slice: currentSlice(obs.Slices, name),
			IdleForS: int(obs.IdleFor[name].Seconds()),
			SunshineReachable: p == drivers.PowerRunning && vm.Host != "" &&
				l.DialSunshine(vm.Host, l.Cfg.SunshinePort)})
```

(`obs.IdleFor[name]` is already set two lines above from `l.Act.IdleFor(name)`,
and is zero for anything not known-idle, so the omitempty behaviour is
automatic.)

In the same function's `l.Store.update` call, set the grace period:

```go
	l.Store.update(func(d *state.Doc) {
		d.GracePeriodS = l.Cfg.GracePeriodS
		d.GPU = state.GPU{PF: l.Cfg.PFAddress, Mapping: l.Cfg.PCIMapping,
			LayoutProfile: obs.Layout, Capacity: capacity, FreeSlots: free, Slices: obs.Slices}
		d.VMs = vms
	})
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd /home/daniele/Repos/gpu-manager && go test ./internal/reconcile/ -run TestObservePublishesTheIdleClock -v`
Expected: PASS.

- [ ] **Step 6: Render it in ctl**

In `internal/ctl/ctl.go`, `printDoc` currently prints each VM with:

```go
		fmt.Fprintf(out, "vm %-12s %-8s session=%-6s sunshine=%v\n", v.Name, v.Power, v.Session, v.SunshineReachable)
```

Replace with:

```go
	for _, v := range doc.VMs {
		session := v.Session
		if v.IdleForS > 0 {
			// The number an operator actually wants: how far through the
			// grace period this VM is, i.e. when the card comes free.
			session = fmt.Sprintf("%s %ds/%ds", v.Session, v.IdleForS, doc.GracePeriodS)
		}
		fmt.Fprintf(out, "vm %-12s %-8s session=%-14s sunshine=%v\n",
			v.Name, v.Power, session, v.SunshineReachable)
	}
```

(delete the old single-line loop body it replaces).

- [ ] **Step 7: Verify the whole suite**

Run: `cd /home/daniele/Repos/gpu-manager && gofmt -l . && go vet ./... && go test ./...`
Expected: `gofmt -l .` prints nothing; all packages `ok`.

- [ ] **Step 8: Commit**

```bash
cd /home/daniele/Repos/gpu-manager
git add internal/state internal/reconcile internal/ctl
git commit -m "$(cat <<'EOF'
feat(state): publish how long a session has been idle

IdleFor was computed every pass and thrown away, so status could say
`session=idle` but not how far through the 300s grace period that VM was
-- which is the question you ask it once idle release works. Publish the
seconds, echo the grace period so a client need not read the config, and
render both in ctl.

Omitted unless the VM is actually idle: for an unknown session a duration
would imply knowledge the daemon does not have.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Close and prove the chain end to end

**Repo:** `gpu-manager`

This is the whole point of the feature, and the one thing no earlier task
demonstrates: a reported session ending eventually hands the card to the
default tenant. It also carries the one code change that makes that possible.

**Why there is code here.** Releasing an idle game shuts the VM down
(`planner.go` step 6) but leaves its claim in the store, and `loop.go`'s
success loop re-affirms that claim `satisfied` because the VM is still in
`sol.Assigned`. On the next pass the stale game claim scores idle-game (1)
against the default tenant's background (0), so it wins the layout and the
tenant pends — while the game itself cannot be started, its `activating`
having been cleared. Result: the card sits free forever and the handback never
happens. A claim whose VM has been released has been honoured and is done, so
the release drops it.

**Files:**
- Modify: `internal/reconcile/loop.go` (the success loop in `ReconcileOnce`)
- Modify: `internal/reconcile/planner.go` (a new `Step.IdleRelease` field, set
  by the idle-release step — see Step 3)
- Modify: `internal/reconcile/loop_test.go`

**Interfaces:**
- Consumes: `(*Activity).Report` (Task 1), `withDefaultTenant` and the
  `fakeGPU`/`fakeVM` helpers (already in the file), `Store.DeleteClaim`.
- Produces: nothing later tasks depend on.

- [ ] **Step 1: Write the tests**

Append to `internal/reconcile/loop_test.go`:

```go
// The chain this feature exists for: a session ends, the grace period runs
// out, the game is shut down, and the default tenant picks the card up.
func TestReportedIdleGamePastGraceHandsTheCardToTheDefaultTenant(t *testing.T) {
	gpu := newFakeGPU(held("0000:0e:00.4", 26, "nvidia-666", 201), free("0000:0e:00.5", 27))
	vm := &fakeVM{power: map[int]drivers.Power{201: drivers.PowerRunning, 202: drivers.PowerStopped,
		300: drivers.PowerStopped}, mdev: map[int]string{201: "nvidia-666"}}
	l := withDefaultTenant(newLoop(t, vm, gpu), "ai-vm", "Q-24C")

	now := time.Unix(1000, 0)
	l.Act = activity.New(l.Cfg.SessionTTL(), func() time.Time { return now },
		[]string{"gaming-1", "gaming-2", "ai-vm"})
	l.Store.UpsertClaim("gaming-1", state.Claim{VM: "gaming-1", Profile: "Q-24C",
		Tier: state.TierGame})
	l.Act.Report("gaming-1", true)
	if err := l.ReconcileOnce(context.Background()); err != nil {
		t.Fatal(err)
	}
	vm.calls = nil

	// The stream ends, and the grace period elapses.
	l.Act.Report("gaming-1", false)
	now = now.Add(l.Cfg.GracePeriod() + time.Second)

	if err := l.ReconcileOnce(context.Background()); err != nil {
		t.Fatal(err)
	}
	if vm.power[201] != drivers.PowerStopped {
		t.Fatalf("the idle game should have been shut down, power=%v", vm.power[201])
	}

	// Next pass: the card is free and gaming-1 was the last holder, so the
	// default tenant is armed.
	if err := l.ReconcileOnce(context.Background()); err != nil {
		t.Fatal(err)
	}
	if vm.power[300] != drivers.PowerRunning {
		t.Fatalf("the default tenant should hold the card now, power=%v", vm.power[300])
	}
}

// Inside the grace period nothing happens: a player who walks away for two
// minutes does not lose their session.
func TestReportedIdleGameWithinGraceIsLeftAlone(t *testing.T) {
	gpu := newFakeGPU(held("0000:0e:00.4", 26, "nvidia-666", 201), free("0000:0e:00.5", 27))
	vm := &fakeVM{power: map[int]drivers.Power{201: drivers.PowerRunning, 202: drivers.PowerStopped,
		300: drivers.PowerStopped}, mdev: map[int]string{201: "nvidia-666"}}
	l := newLoop(t, vm, gpu)

	now := time.Unix(1000, 0)
	l.Act = activity.New(l.Cfg.SessionTTL(), func() time.Time { return now },
		[]string{"gaming-1", "gaming-2", "ai-vm"})
	l.Store.UpsertClaim("gaming-1", state.Claim{VM: "gaming-1", Profile: "Q-24C",
		Tier: state.TierGame})
	l.Act.Report("gaming-1", false)
	now = now.Add(l.Cfg.GracePeriod() - time.Second)
	vm.calls = nil

	if err := l.ReconcileOnce(context.Background()); err != nil {
		t.Fatal(err)
	}
	if vm.power[201] != drivers.PowerRunning {
		t.Fatalf("a game inside its grace period must be left running: %v", vm.calls)
	}
}

// A reporter that went quiet is not an ended session. However long the silence,
// an unknown holder is never released -- this is the invariant that keeps a
// crashed heartbeat from killing a live game.
func TestSilentReporterNeverCausesARelease(t *testing.T) {
	gpu := newFakeGPU(held("0000:0e:00.4", 26, "nvidia-666", 201), free("0000:0e:00.5", 27))
	vm := &fakeVM{power: map[int]drivers.Power{201: drivers.PowerRunning, 202: drivers.PowerStopped,
		300: drivers.PowerStopped}, mdev: map[int]string{201: "nvidia-666"}}
	l := newLoop(t, vm, gpu)

	now := time.Unix(1000, 0)
	l.Act = activity.New(l.Cfg.SessionTTL(), func() time.Time { return now },
		[]string{"gaming-1", "gaming-2", "ai-vm"})
	l.Store.UpsertClaim("gaming-1", state.Claim{VM: "gaming-1", Profile: "Q-24C",
		Tier: state.TierGame})
	l.Act.Report("gaming-1", true)
	now = now.Add(24 * time.Hour) // the heartbeat died a day ago
	vm.calls = nil

	if err := l.ReconcileOnce(context.Background()); err != nil {
		t.Fatal(err)
	}
	if vm.power[201] != drivers.PowerRunning {
		t.Fatalf("an unknown session must never be released: %v", vm.calls)
	}
}
```

- [ ] **Step 2: Run them to verify the chain test fails**

Run: `cd /home/daniele/Repos/gpu-manager && go test ./internal/reconcile/ -run 'ReportedIdle|SilentReporter' -v`

Expected:
- `TestReportedIdleGameWithinGraceIsLeftAlone` PASSES
- `TestSilentReporterNeverCausesARelease` PASSES
- `TestReportedIdleGamePastGraceHandsTheCardToTheDefaultTenant` **FAILS** at
  the last assertion: `the default tenant should hold the card now,
  power=stopped`. The game is shut down (that part works), but its stale
  claim outranks the default tenant on the next pass.

If the chain test passes at this point, stop and re-read it — it is not
exercising what it claims.

- [ ] **Step 3: Mark the idle-release step, and drop the released claim**

`PlanSteps`'s idle-release step is the only thing that shuts down a VM that is
still assigned its slice, so the claim that assignment came from has to go
with it. The loop therefore needs to tell an idle release apart from a
displacement — and it must not re-derive the predicate, or there would be two
copies of "is this an idle release" free to drift apart. Mark it on the step
instead.

In `internal/reconcile/planner.go`, add a field to `Step`:

```go
type Step struct {
	Kind StepKind
	VM   string
	// MdevType is the vGPU type the step concerns: the type to wait for on
	// StepWaitGPUFree, the type to configure on StepSetProfile.
	MdevType string
	// IdleRelease marks a shutdown planned by step 6 below: a game released
	// for sitting idle past its grace period, rather than one displaced to
	// make room for a claimant. ReconcileOnce drops the released VM's claim,
	// so the two kinds of shutdown have to be distinguishable.
	IdleRelease bool
}
```

and set it where step 6 plans that shutdown — the `for vm, p := range obs.Power`
loop at the end of `PlanSteps`:

```go
			steps = append(steps, Step{Kind: StepShutdown, VM: vm, IdleRelease: true})
```

While there, extend that step's comment so the two halves are findable from
each other:

```go
	// 6. Release idle game VMs past grace by shutting them down (see step 1:
	//    they cannot be suspended) -- but never one whose session we cannot
	//    see. Unknown is not idle.
	//
	//    Marked IdleRelease, because ReconcileOnce deletes the claim of
	//    anything released here: a claim left behind outranks the default
	//    tenant but cannot start its own VM, so the freed card would strand.
```

Then in `internal/reconcile/loop.go`, `ReconcileOnce`, replace the success
loop:

```go
	// Success: claims assigned and fully executed are satisfied.
	l.Store.mu.Lock()
	for _, vm := range sol.Assigned {
		if c, ok := l.Store.claims[vm]; ok {
			c.Status = state.ClaimSatisfied
			c.Reason, c.BlockedByActive = "", nil
			l.Store.claims[vm] = c
		}
		delete(l.Store.activating, vm)
	}
```

with:

```go
	// A claim whose VM this pass released for sitting idle is done: it was
	// honoured, and the session it was made for has ended. It must not be
	// left behind -- a stale game claim outranks the default tenant (idle
	// game beats background) while being unable to start anything itself,
	// which would strand the card the release just freed.
	released := map[string]bool{}
	for _, st := range steps {
		if st.IdleRelease {
			released[st.VM] = true
		}
	}

	// Success: claims assigned and fully executed are satisfied.
	l.Store.mu.Lock()
	for _, vm := range sol.Assigned {
		if released[vm] {
			delete(l.Store.claims, vm)
			delete(l.Store.activating, vm)
			continue
		}
		if c, ok := l.Store.claims[vm]; ok {
			c.Status = state.ClaimSatisfied
			c.Reason, c.BlockedByActive = "", nil
			l.Store.claims[vm] = c
		}
		delete(l.Store.activating, vm)
	}
```

Note `PlanSteps` has an existing test that compares whole `[]Step` values with
`reflect.DeepEqual`; adding a field changes nothing for steps that leave it
false, but if any such test fails, fix the test's expectation rather than
dropping the field.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd /home/daniele/Repos/gpu-manager && go test ./internal/reconcile/ -run 'ReportedIdle|SilentReporter' -v`
Expected: all three PASS.

- [ ] **Step 5: Verify the whole suite and commit**

Run the full suite — the claim-lifecycle change touches arbitration, so a
regression would show up in the existing claim tests, not the new ones:

```bash
cd /home/daniele/Repos/gpu-manager
gofmt -l . && go vet ./... && go test -race ./...
git add internal/reconcile
git commit -m "$(cat <<'EOF'
fix(reconcile): drop a claim when its VM is released for being idle

Releasing an idle game shut the VM down and left its claim behind, which
the success loop then re-affirmed `satisfied` because the VM was still
assigned. Next pass that stale claim outranked the default tenant (idle
game beats background) and won the layout -- while being unable to start
anything, its activating flag long cleared. The freed card stranded and
the handback never happened.

A claim whose VM has been released for going idle has been honoured and
its session has ended, so the release drops it.

Also pins the whole chain: session ends -> grace elapses -> the game is
shut down -> the default tenant takes the card. Plus the two cases that
must NOT release: inside the grace period, and a reporter gone quiet
(unknown is never idle, however long the silence).

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: The guest reports over HTTP

**Repo:** `terranse`

**Files:**
- Modify: `ansible/roles/gaming/templates/sunshine-session-start.sh.j2`
- Modify: `ansible/roles/gaming/templates/sunshine-session-stop.sh.j2`
- Create: `ansible/roles/gaming/templates/sunshine-heartbeat.service.j2`
- Create: `ansible/roles/gaming/templates/sunshine-heartbeat.timer.j2`
- Modify: `ansible/roles/gaming/tasks/sunshine.yaml` (after the stop-hook task,
  around line 86)
- Modify: `ansible/roles/gaming/defaults/main.yaml`
- Modify: `tofu/deployments/edholm/configurations.tfvars` (the gaming VM's
  `roles[].vars`, around line 275)
- Modify: `tests/conftest.py`
- Modify: `tests/unit/templates/test_templates.py`

**Interfaces:**
- Consumes: `PUT`/`DELETE /v1/sessions/{vm}` from Task 2.
- Produces: role variables `gpu_manager_api_url` (required, no default) and
  `gpu_manager_vm_name` (defaults to `{{ ansible_hostname }}`).

- [ ] **Step 1: Write the failing template tests**

Append to `tests/conftest.py`:

```python
@pytest.fixture
def gaming_templates_dir(ansible_dir):
    """Return the gaming role's templates directory."""
    return ansible_dir / "roles" / "gaming" / "templates"


@pytest.fixture
def gaming_jinja_env(gaming_templates_dir):
    """Return a Jinja2 environment for the gaming role's templates."""
    env = Environment(
        loader=FileSystemLoader(str(gaming_templates_dir)),
        keep_trailing_newline=True,
    )
    env.filters["mandatory"] = _mandatory
    return env


@pytest.fixture
def sunshine_hook_vars():
    """Return the variables the Sunshine session hooks consume."""
    return {
        "gpu_manager_api_url": "http://192.168.1.200:8080",
        "gpu_manager_vm_name": "gaming",
        "gaming_user": "gamer",
    }
```

Append to `tests/unit/templates/test_templates.py`:

```python
class TestSunshineSessionHooks:
    """Tests for the hooks that tell gpu-manager about streaming sessions.

    These run as Sunshine `global_prep_cmd`, where a non-zero exit aborts the
    stream, so they must swallow every failure. They are also the only thing
    that makes the daemon's grace period able to fire at all.
    """

    def _render(self, env, name, variables):
        return env.get_template(name).render(**variables)

    def test_start_hook_reports_the_session_to_the_daemon(
        self, gaming_jinja_env, sunshine_hook_vars
    ):
        body = self._render(
            gaming_jinja_env, "sunshine-session-start.sh.j2", sunshine_hook_vars
        )

        assert "-X PUT" in body
        assert "http://192.168.1.200:8080/v1/sessions/gaming" in body

    def test_stop_hook_reports_the_session_ended(
        self, gaming_jinja_env, sunshine_hook_vars
    ):
        body = self._render(
            gaming_jinja_env, "sunshine-session-stop.sh.j2", sunshine_hook_vars
        )

        assert "-X DELETE" in body
        assert "http://192.168.1.200:8080/v1/sessions/gaming" in body

    @pytest.mark.parametrize(
        "name", ["sunshine-session-start.sh.j2", "sunshine-session-stop.sh.j2"]
    )
    def test_hooks_never_fail_the_stream(
        self, gaming_jinja_env, sunshine_hook_vars, name
    ):
        """A non-zero exit from a global_prep_cmd aborts the stream."""
        body = self._render(gaming_jinja_env, name, sunshine_hook_vars)

        assert "set -e" not in body
        assert body.rstrip().endswith("exit 0")

    @pytest.mark.parametrize(
        "name", ["sunshine-session-start.sh.j2", "sunshine-session-stop.sh.j2"]
    )
    def test_hooks_require_the_api_url(self, gaming_jinja_env, sunshine_hook_vars, name):
        """Reporting nowhere is the failure this whole change is fixing, so a
        missing URL must fail loudly at template time."""
        del sunshine_hook_vars["gpu_manager_api_url"]

        with pytest.raises(UndefinedError):
            self._render(gaming_jinja_env, name, sunshine_hook_vars)

    def test_start_hook_starts_the_heartbeat(
        self, gaming_jinja_env, sunshine_hook_vars
    ):
        """Without a heartbeat a crashed session would read active forever."""
        body = self._render(
            gaming_jinja_env, "sunshine-session-start.sh.j2", sunshine_hook_vars
        )

        assert "sunshine-heartbeat.timer" in body
        assert "--user start" in body

    def test_stop_hook_stops_the_heartbeat(self, gaming_jinja_env, sunshine_hook_vars):
        body = self._render(
            gaming_jinja_env, "sunshine-session-stop.sh.j2", sunshine_hook_vars
        )

        assert "sunshine-heartbeat.timer" in body
        assert "--user stop" in body

    def test_heartbeat_unit_reports_active(self, gaming_jinja_env, sunshine_hook_vars):
        body = self._render(
            gaming_jinja_env, "sunshine-heartbeat.service.j2", sunshine_hook_vars
        )

        assert "-X PUT" in body
        assert "http://192.168.1.200:8080/v1/sessions/gaming" in body

    def test_heartbeat_timer_fires_within_the_ttl(
        self, gaming_jinja_env, sunshine_hook_vars
    ):
        """The daemon's session_ttl_s is 180, so 60s gives three chances."""
        body = self._render(
            gaming_jinja_env, "sunshine-heartbeat.timer.j2", sunshine_hook_vars
        )

        assert "OnUnitActiveSec=60" in body
```

`UndefinedError` needs importing at the top of
`tests/unit/templates/test_templates.py`:

```python
from jinja2.exceptions import UndefinedError
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```bash
cd /home/daniele/Repos/terranse && uv run --with pytest --with jinja2 --with pyyaml \
  pytest tests/unit/templates/test_templates.py -k Sunshine -q
```
Expected: FAIL — the hooks still write session files, and the two heartbeat
templates do not exist (`TemplateNotFound`).

- [ ] **Step 3: Rewrite the start hook**

Replace the whole of
`ansible/roles/gaming/templates/sunshine-session-start.sh.j2`:

```bash
#!/bin/bash
# Sunshine Session Start Hook
# Tells gpu-manager on the Proxmox host that a session is live here.
#
# Managed by Ansible - do not edit manually
#
# Deliberately NOT `set -e`: this runs as a Sunshine global_prep_cmd, so a
# non-zero exit aborts the stream/app launch. Session bookkeeping is
# best-effort -- never let it block streaming. The script always exits 0.
#
# This used to write a marker file into a shared directory. Nothing could read
# it: the host had no such mount, and the filename did not match what the
# daemon looked for. The daemon has an HTTP API and this guest can reach it.

API="{{ gpu_manager_api_url | mandatory('gpu_manager_api_url must name the gpu-manager API, e.g. http://192.168.1.200:8080') }}"
# The VM's name as gpu-manager's config keys it (its `vms:` map), which is not
# necessarily this machine's hostname.
VM="{{ gpu_manager_vm_name | default(ansible_hostname) }}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [sunshine-hook] $1" >> /var/log/sunshine-hooks.log 2>&1 || true
}

log "session starting for ${VM}"

if curl -fsS -m 5 -X PUT "${API}/v1/sessions/${VM}" -o /dev/null 2>/dev/null; then
    log "reported session active to ${API}"
else
    log "could not report to ${API} (non-fatal)"
fi

# Heartbeat while the session lives, so a crashed session decays to `unknown`
# instead of reading active forever and pinning the card.
systemctl --user start sunshine-heartbeat.timer 2>/dev/null || true

{% if sunshine_session_start_extra is defined %}
# Custom session start commands
{{ sunshine_session_start_extra }}
{% endif %}

exit 0
```

- [ ] **Step 4: Rewrite the stop hook**

Replace the whole of
`ansible/roles/gaming/templates/sunshine-session-stop.sh.j2`:

```bash
#!/bin/bash
# Sunshine Session Stop Hook
# Tells gpu-manager the session ended, which starts its grace-period clock.
#
# Managed by Ansible - do not edit manually
#
# Best-effort cleanup (the `undo` of a global_prep_cmd) -- never abort.
#
# This is the ONLY thing that makes a VM read `idle`, and therefore the only
# thing that lets the daemon ever free the card on its own. The old version
# rewrote a marker file with status:"inactive" while the daemon only tested
# whether the file existed, so an ended session read as live forever.

API="{{ gpu_manager_api_url | mandatory('gpu_manager_api_url must name the gpu-manager API, e.g. http://192.168.1.200:8080') }}"
VM="{{ gpu_manager_vm_name | default(ansible_hostname) }}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [sunshine-hook] $1" >> /var/log/sunshine-hooks.log 2>&1 || true
}

log "session ending for ${VM}"

# Stop heartbeating first, or the timer could re-report the session active
# after this hook has said it ended.
systemctl --user stop sunshine-heartbeat.timer 2>/dev/null || true

if curl -fsS -m 5 -X DELETE "${API}/v1/sessions/${VM}" -o /dev/null 2>/dev/null; then
    log "reported session ended to ${API}"
else
    log "could not report to ${API} (non-fatal)"
fi

{% if sunshine_session_stop_extra is defined %}
# Custom session stop commands
{{ sunshine_session_stop_extra }}
{% endif %}

exit 0
```

- [ ] **Step 5: Create the heartbeat units**

Create `ansible/roles/gaming/templates/sunshine-heartbeat.service.j2`:

```ini
# Managed by Ansible - do not edit manually
#
# One heartbeat to gpu-manager. Started by the timer, which the session hooks
# turn on and off, so this never runs outside a session.
[Unit]
Description=Report the live Sunshine session to gpu-manager

[Service]
Type=oneshot
ExecStart=/usr/bin/curl -fsS -m 5 -X PUT {{ gpu_manager_api_url | mandatory('gpu_manager_api_url must name the gpu-manager API, e.g. http://192.168.1.200:8080') }}/v1/sessions/{{ gpu_manager_vm_name | default(ansible_hostname) }} -o /dev/null
```

Create `ansible/roles/gaming/templates/sunshine-heartbeat.timer.j2`:

```ini
# Managed by Ansible - do not edit manually
#
# 60s against the daemon's session_ttl_s of 180: three chances to be heard
# before an active session decays to `unknown`. Not enabled -- the session
# start hook starts it and the stop hook stops it, so nothing heartbeats
# while nobody is streaming.
[Unit]
Description=Heartbeat the live Sunshine session to gpu-manager

[Timer]
OnActiveSec=0
OnUnitActiveSec=60
AccuracySec=5s

[Install]
WantedBy=timers.target
```

- [ ] **Step 6: Install the units**

In `ansible/roles/gaming/tasks/sunshine.yaml`, after the "Deploy session stop
hook" task (ends line 86), insert:

```yaml
# The heartbeat units live in the Sunshine user's own systemd, because that is
# what the session hooks can start and stop without privileges -- the hooks run
# as that user.
- name: Create the user systemd directory
  ansible.builtin.file:
    path: "/home/{{ gaming_user }}/.config/systemd/user"
    state: directory
    owner: "{{ gaming_user }}"
    group: "{{ gaming_user }}"
    mode: '0755'

- name: Deploy the session heartbeat units
  ansible.builtin.template:
    src: "{{ item }}.j2"
    dest: "/home/{{ gaming_user }}/.config/systemd/user/{{ item }}"
    owner: "{{ gaming_user }}"
    group: "{{ gaming_user }}"
    mode: '0644'
  loop:
    - sunshine-heartbeat.service
    - sunshine-heartbeat.timer

# Deliberately NOT enabled: the session hooks start and stop the timer, so it
# only runs while somebody is actually streaming.
- name: Reload the user systemd so the heartbeat units are known
  ansible.builtin.systemd:
    daemon_reload: true
    scope: user
  become: true
  become_user: "{{ gaming_user }}"
  failed_when: false
```

- [ ] **Step 7: Declare the new variables**

In `ansible/roles/gaming/defaults/main.yaml`, next to `gaming_user`, add:

```yaml
# The VM's name as gpu-manager's config keys it (its `vms:` map). It happens to
# equal this guest's hostname today, but it is a contract with the daemon's
# config, not an incidental hostname, so it gets a name of its own.
gpu_manager_vm_name: "{{ ansible_hostname }}"

# gpu_manager_api_url is deliberately NOT defaulted. The session hooks pass it
# through `mandatory`, so a deployment that forgets it fails at template time
# rather than silently installing hooks that report nowhere -- which is exactly
# the failure this replaced.
```

In `tofu/deployments/edholm/configurations.tfvars`, add to the gaming VM's
`roles[0].vars` map (the block starting `name = "gaming"`):

```hcl
            # gpu-manager's API, as the *guest* can reach it: workstation's LAN
            # address on vmbr0. The netbird name does not resolve in here.
            gpu_manager_api_url = "http://192.168.1.200:8080"
            # gpu-manager's config keys this VM `gaming`.
            gpu_manager_vm_name = "gaming"
```

- [ ] **Step 8: Run the tests to verify they pass**

Run:
```bash
cd /home/daniele/Repos/terranse && uv run --with pytest --with jinja2 --with pyyaml \
  pytest tests/ -q
```
Expected: PASS, with the new Sunshine tests included.

- [ ] **Step 9: Check the Ansible and tofu still parse**

Run:
```bash
cd /home/daniele/Repos/terranse && ansible-lint ansible/roles/gaming/ 2>&1 | tail -20
cd /home/daniele/Repos/terranse/tofu/deployments/edholm && tofu validate
```
Expected: `tofu validate` reports success. `ansible-lint` has pre-existing
findings in this repo — confirm none of them name a file this task changed.

- [ ] **Step 10: Commit**

```bash
cd /home/daniele/Repos/terranse
git add ansible/roles/gaming tofu/deployments/edholm/configurations.tfvars tests
git commit -m "$(cat <<'EOF'
feat(gaming): report Sunshine sessions to the daemon over HTTP

The hooks were writing marker files into a directory nothing could read,
so gpu-manager saw every session as `unknown` and its grace period never
fired. Same hooks, new destination: PUT on start, DELETE on stop, plus a
60s heartbeat timer the hooks turn on and off so a crashed session decays
to `unknown` instead of pinning the card forever.

gpu_manager_api_url has no default on purpose -- `mandatory` makes a
deployment that forgets it fail at template time, rather than installing
hooks that report nowhere.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Remove the dead session-state plumbing

**Repo:** `terranse`

**Files:**
- Modify: `ansible/roles/gaming/tasks/game-storage.yaml:25` and `:129-136`
- Modify: `ansible/roles/gaming/templates/cloud-init-gaming.yaml.j2:19`
- Modify: `ansible/roles/gaming-storage/tasks/main.yaml:70-76` and `:122`
- Modify: `ansible/roles/gaming-storage/templates/exports.j2:26-27`
- Modify: `ansible/roles/gpu-manager/files/health-check.sh:21` and `:167-176`
- Modify: `ansible/roles/gpu-manager/defaults/main.yaml` and
  `templates/gpu-manager.config.yaml.j2`
- Modify: `tests/conftest.py` (the `gpu_manager_vars` fixture),
  `tests/unit/templates/test_templates.py`

**Interfaces:**
- Consumes: `session_ttl_s` from Task 1's config change.
- Produces: `gpu_manager_session_ttl_s` role variable (default `180`).

- [ ] **Step 1: Write the failing tests**

In `tests/conftest.py`, in the `gpu_manager_vars` fixture, replace
`"gpu_manager_session_dir": "/mnt/gaming/session-state",` with
`"gpu_manager_session_ttl_s": 180,`.

Append to the `TestGPUManagerConfigTemplate` class in
`tests/unit/templates/test_templates.py`:

```python
    def test_emits_the_session_ttl(self, gpu_manager_jinja_env, gpu_manager_vars):
        parsed = self._render(gpu_manager_jinja_env, gpu_manager_vars)

        assert parsed["session_ttl_s"] == 180

    def test_no_longer_emits_session_dir(self, gpu_manager_jinja_env, gpu_manager_vars):
        """Sessions arrive over the API now; the directory nothing could read
        is gone, and a config still naming it would be a lie about where the
        daemon looks."""
        parsed = self._render(gpu_manager_jinja_env, gpu_manager_vars)

        assert "session_dir" not in parsed
```

- [ ] **Step 2: Run them to verify they fail**

Run:
```bash
cd /home/daniele/Repos/terranse && uv run --with pytest --with jinja2 --with pyyaml \
  pytest tests/unit/templates/test_templates.py -k GPUManager -q
```
Expected: FAIL — `session_ttl_s` is not emitted, `session_dir` still is (and
the other tests in the class now fail on the renamed fixture key, because the
template still references `gpu_manager_session_dir`).

- [ ] **Step 3: Swap the role variable**

In `ansible/roles/gpu-manager/defaults/main.yaml`, replace the
`gpu_manager_session_dir` block:

```yaml
# Per-VM Sunshine session markers. While this is absent the daemon reports
# every session as unknown: nothing is auto-suspended, and displacing a
# running holder needs an explicit preempting claim.
gpu_manager_session_dir: /mnt/gaming/session-state
```

with:

```yaml
# How long the daemon believes a reported session without hearing again. The
# gaming guests' Sunshine hooks report start and end over the daemon's API and
# heartbeat every 60s while a session is live, so this is three missed
# heartbeats. A session that decays this way reads as `unknown`, never `idle`:
# silence does not mean nobody is playing.
gpu_manager_session_ttl_s: 180
```

In `ansible/roles/gpu-manager/templates/gpu-manager.config.yaml.j2`, replace
the `session_dir` line with:

```jinja
session_ttl_s: {{ gpu_manager_session_ttl_s }}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:
```bash
cd /home/daniele/Repos/terranse && uv run --with pytest --with jinja2 --with pyyaml \
  pytest tests/ -q
```
Expected: PASS.

- [ ] **Step 5: Delete the guest-side mount**

In `ansible/roles/gaming/tasks/game-storage.yaml`, remove
`    - /mnt/gaming/session-state` from the directory loop (line 25), and delete
the whole "Mount session state directory" task (lines 129-136, the task with
`src: "{{ nfs_server }}:/tank/gaming/session-state"`).

In `ansible/roles/gaming/templates/cloud-init-gaming.yaml.j2`, delete line 19,
the `session-state` fstab entry.

- [ ] **Step 6: Delete the host-side export**

In `ansible/roles/gaming-storage/tasks/main.yaml`, delete the "Create session
state dataset for Sunshine hooks" task (lines 70-76) and remove
`    - { path: "session-state", mode: "0777" }  # VMs write session state here`
from the directory loop (line 122).

In `ansible/roles/gaming-storage/templates/exports.j2`, delete the two lines
at 26-27 (the `# Session state` comment and the `session-state` export).

Note the ZFS dataset itself is NOT destroyed — removing the `state: present`
task stops managing it, and deleting data is a separate, deliberate act for
the operator.

- [ ] **Step 7: Fix the health check**

In `ansible/roles/gpu-manager/files/health-check.sh`, delete the
`SESSION_STATE_DIR="${NFS_MOUNT}/session-state"` line (21) and the whole
"Check session state directory" block (lines 167-176, from the comment through
the closing `fi`). It currently warns on every run about a directory that is
supposed to be absent.

- [ ] **Step 8: Verify nothing still references it**

Run:
```bash
cd /home/daniele/Repos/terranse && grep -rn "session-state\|session_dir" \
  --include='*.yaml' --include='*.j2' --include='*.sh' --include='*.tf' \
  --include='*.tfvars' --include='*.py' . | grep -v '.claude/' | grep -v '.venv'
```
Expected: no output. (Matches in `docs/` are historical write-ups and are
fine, but this glob excludes `.md` anyway.)

- [ ] **Step 9: Lint and commit**

```bash
cd /home/daniele/Repos/terranse
uv run --with pytest --with jinja2 --with pyyaml pytest tests/ -q
ansible-lint ansible/roles/gaming/ ansible/roles/gaming-storage/ ansible/roles/gpu-manager/ 2>&1 | tail -20
git add ansible tests
git commit -m "$(cat <<'EOF'
refactor(gaming): delete the session-state share nothing could read

An NFS export, a mount, a dataset, a directory and a health check, all
for a marker file the host daemon never saw -- the mount stopped
happening when game storage moved to virtiofs, and nobody noticed
because the failure mode was a silent `unknown`. Sessions come over the
API now, so all of it goes, and the role's session_dir becomes
session_ttl_s.

The ZFS dataset is left in place, unmanaged: deleting data is the
operator's call, not a side effect of dropping a task.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Let `host` reach the daemon

**Repo:** `terranse`

Independent of Tasks 1-6; can be done at any point.

**Files:**
- Modify: `tofu/deployments/edholm/main.tf:40-50` (the `gaming_vms_by_host`
  local)
- Modify: `tests/conftest.py` (the `gpu_manager_vars` fixture)
- Modify: `tests/unit/templates/test_templates.py`

**Interfaces:**
- Consumes: nothing.
- Produces: `gaming_vms[*].host`, consumed by the existing
  `{% if vm.host is defined %}` in the config template.

- [ ] **Step 1: Write the failing tests**

Append to the `TestGPUManagerConfigTemplate` class:

```python
    def test_emits_host_when_the_vm_has_one(self, gpu_manager_jinja_env, gpu_manager_vars):
        """Without `host` the daemon cannot probe Sunshine, so it reports a
        claim satisfied the moment the VM starts -- before the stream is up."""
        gpu_manager_vars["gaming_vms"]["gaming"]["host"] = "gaming.edholm.cc"

        parsed = self._render(gpu_manager_jinja_env, gpu_manager_vars)

        assert parsed["vms"]["gaming"]["host"] == "gaming.edholm.cc"

    def test_omits_host_when_the_vm_has_none(self, gpu_manager_jinja_env, gpu_manager_vars):
        parsed = self._render(gpu_manager_jinja_env, gpu_manager_vars)

        assert "host" not in parsed["vms"]["ai-vm"]
```

- [ ] **Step 2: Run them**

Run:
```bash
cd /home/daniele/Repos/terranse && uv run --with pytest --with jinja2 --with pyyaml \
  pytest tests/unit/templates/test_templates.py -k "host" -q
```
Expected: the `omits` test PASSES (that path already works); the `emits` test
PASSES too, because the template's conditional is already correct. **If both
pass, that is the point:** the template was never the bug — the tofu local
never supplied `host`. These tests pin the template contract; Step 3 fixes the
supply side, which has no unit test harness. Record that in the commit.

- [ ] **Step 3: Carry `host` in the local**

In `tofu/deployments/edholm/main.tf`, wrap the `gaming_vms_by_host` local's
inner object in a `merge` that adds `host` only for game-tier VMs:

```hcl
  gaming_vms_by_host = {
    for host_key, mod in module.proxmox-vm : host_key => {
      for name, id in mod.vm_ids : name => merge({
        vmid   = id
        mounts = try(var.hosts[host_key].vms[name].mounts, [])
        # gpu-manager arbitrates the card by tier, so it has to travel with
        # the VMID: without it every VM would look like a gaming VM and the
        # AI VM could never be told apart from the one it displaces.
        tier = try(var.hosts[host_key].vms[name].gpu_tier, "game")
        },
        # The daemon probes Sunshine on this address to decide when a claim is
        # really satisfied. Without it `sunshine_reachable` is permanently
        # false and the wait-for-stream step never runs, so a handover reports
        # done the moment the VM powers on, well before the stream is up.
        #
        # Game tier only. observe() dials this address on EVERY pass for any
        # VM that has one, and an AI VM runs no Sunshine -- with *.edholm.cc
        # resolving to the WAN IP and no hairpin NAT, that is a dial timeout
        # every five seconds for nothing. StepWaitSunshine is game-only
        # anyway.
        #
        # A `for … if` comprehension rather than a conditional: HCL requires a
        # conditional's arms to have identical types, and `{host = string}` and
        # `{}` do not. Same reason as hosts_wired below.
        { for k, v in { host = "${name}.${var.domain}" } : k => v
          if try(var.hosts[host_key].vms[name].gpu_tier, "game") == "game" }
      )
    }
  }
```

- [ ] **Step 4: Verify the plan produces it**

Run:
```bash
cd /home/daniele/Repos/terranse/tofu/deployments/edholm && tofu validate && \
  tofu plan -var-file=configurations.tfvars -refresh=false \
  -target='module.ansible-wiring.local_file.ansible_playbook' -no-color 2>&1 | grep -E '"host"|Plan:'
```
Expected: the diff shows `+ "host": "gaming.edholm.cc"` inside `gaming_vms`,
and **no** `host` key under `ai-vm` (it is tier `ai`). Do **not** apply.

- [ ] **Step 5: Commit**

```bash
cd /home/daniele/Repos/terranse
uv run --with pytest --with jinja2 --with pyyaml pytest tests/ -q
git add tofu/deployments/edholm/main.tf tests
git commit -m "$(cat <<'EOF'
fix(tofu): give gpu-manager the host it probes Sunshine on

The config template has always emitted `host:` when the VM has one, but
gaming_vms_by_host only ever built {vmid, mounts, tier} -- so
cfg.VMs[vm].Host was empty, sunshine_reachable was permanently false, and
the wait-for-stream step never ran. A handover reported itself satisfied
the moment the VM powered on, well before the stream was up.

The added tests pin the template's side of the contract, which was never
the broken half; the supply side has no unit harness, so `tofu plan`
verifies it.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: Show the clock in the `gpu` function

**Repo:** `computer-configs`

**Files:**
- Modify: `home/terminal.nix` (the `gpu` function's `status` verb)

**Interfaces:**
- Consumes: `vms[].idle_for_s` and `grace_period_s` from Task 3.
- Produces: nothing.

- [ ] **Step 1: Change the status renderer**

In `home/terminal.nix`, inside the `gpu` function's `case status` branch,
replace the whole `jq` invocation. The grace period is bound from the document
itself (`as $grace`) because it is a field of the response, not something the
shell knows to pass in:

```
              command curl -sS --max-time 5 $server/v1/state | jq -r '
                (.grace_period_s // 0) as $grace |
                "gpu \(.gpu.pf) layout=\(.gpu.layout_profile // "(free)") \(.gpu.free_slots)/\(.gpu.capacity) free",
                (.gpu.slices[]? | "  vf \(.vf) \(.vgpu_type) -> \(.vm // "-")"),
                (.vms[]? | "vm \(.name) \(.power) session=\(.session)"
                  + (if (.idle_for_s // 0) > 0 then " \(.idle_for_s)s/\($grace)s" else "" end)),
                (.claims[]? | "claim \(.vm) \(.profile) tier=\(.tier) \(.status) \(.reason // "")")'
```

Note the `> 0` rather than a bare `if .idle_for_s`: in jq only `false` and
`null` are falsy, so a literal `0` would otherwise render `0s/300s`. (It
cannot be 0 today because the Go field is `omitempty`, but the renderer should
not depend on that.)

- [ ] **Step 2: Verify the flake still evaluates and the fish parses**

Run:
```bash
cd /home/daniele/Repos/computer-configs
SCRATCH=/tmp/claude-1000/-home-daniele-Repos-terranse/3dd58d74-3f26-4dc1-b749-da9e65530fa1/scratchpad
{ echo "function gpu -d 'test'"; \
  nix eval --raw ".#homeConfigurations.$(hostname).config.programs.fish.functions.gpu.body"; \
  echo; echo "end"; } > "$SCRATCH/gpu.fish"
fish -n "$SCRATCH/gpu.fish" && echo "FISH SYNTAX OK"
```
Expected: the flake evaluates and `FISH SYNTAX OK` prints.

- [ ] **Step 3: Run it against the live daemon**

Run: `fish -c "source $SCRATCH/gpu.fish; gpu status"`
Expected: the same output as before, and once Tasks 1-6 are deployed, an idle
gaming VM reads `session=idle 90s/300s`. Before deployment `idle_for_s` is
absent, so the suffix is omitted — check that the line still renders cleanly.

- [ ] **Step 4: Commit**

```bash
cd /home/daniele/Repos/computer-configs
git add home/terminal.nix
git commit -m "$(cat <<'EOF'
feat(fish): show how long until the GPU comes free

`session=idle` alone cannot tell you when the card is released. The
daemon now publishes idle_for_s and grace_period_s, so render both:
`session=idle 90s/300s`.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Deployment (operator, after all tasks)

Not part of any task — `tofu apply` and `just apply` are the operator's call.

1. `cd tofu/deployments/edholm && tofu apply -var-file=configurations.tfvars`
   — regenerates `ansible/playbooks/edholm.yaml` with `gpu_manager_api_url`,
   `gpu_manager_vm_name` and `host`.
2. Run the `workstation` host play — rebuilds and restarts the daemon with
   `session_ttl_s`, and drops the retired session-state plumbing.
3. Run the `gaming` guest play — installs the new hooks and heartbeat units.
4. `cd computer-configs && just apply` — installs the updated `gpu` function.
5. Verify: start a stream, `gpu status` shows `session=active`; end it, the
   line becomes `session=idle Ns/300s`; after 300 s the gaming VM shuts down
   and ai-vm takes the card.

## Self-Review Notes

Checked against the spec:

- Session endpoints, TTL semantics, unknown-never-idle → Tasks 1, 2, 4.
- No GET, plus `idle_for_s` / `grace_period_s` → Task 3 (and Task 8 renders
  them).
- Guest hooks over HTTP, heartbeat timer, `gpu_manager_api_url` /
  `gpu_manager_vm_name` → Task 5.
- Removing the dead mount, export, dataset dir, health check and
  `session_dir` → Task 6.
- The `host:` fix → Task 7.
- Known gaps (unauthenticated endpoints, in-memory claims, preempted games
  losing sessions) are deliberately not implemented, per the spec.

One spec deviation worth flagging to the reviewer: the spec's test list says
`/v1/state` "omits `idle_for_s` for an active and an unknown one", which Task 3
gets for free from `omitempty` plus `IdleFor`'s existing zero-unless-idle rule
rather than from an explicit branch. The behaviour matches; there is no
separate code path to review.
