# PSL Agent Protocol — v0 (Draft)

> Status: draft. Subject to change during `PSLAgent` implementation.
> Scope: the wire protocol between `PSLSysControlPanel` (operator-facing UI) and
> `PSLAgent` (per-host supervisor), plus the enrollment handshake between
> `PSLAgent` and the components it supervises.

---

## 1. Architecture

Each host that runs PSL components (e.g. a local workstation, a remote VPS, ...) runs exactly
one `PSLAgent` process. The agent is the sole authority on its host for
lifecycle management (start / stop / restart), configuration reads and writes,
and log access.

```
          Operator workstation
          ┌────────────────────────┐
          │  PSLSysControlPanel    │
          │  (Qt / C++20)          │
          │                        │
          │  holds:                │
          │   MANAGER_PSK          │
          │   operator_key (RAM)   │
          └───────────┬────────────┘
                      │ TCP over Tailscale
        ┌─────────────┴─────────────┐
        │                           │
   port AGENT_PORT (mgmt)      port 19732 (telemetry, existing)
        │                           │
┌───────▼───────────┐        ┌──────▼───────────────┐
│   PSLAgent        │        │  Component state     │
│   per-host        │◀──────▶│  publisher           │
│                   │ spawns │  (component process) │
│   holds:          │        │                      │
│    HMAC_KEY       │        │  holds: HMAC_KEY     │
│    MANAGER_PSK    │        │                      │
│    op_verifier +  │        │  accepts PSK         │
│    op_salt        │        │  matching either     │
│                   │        │  HMAC_KEY or         │
│                   │        │  MANAGER_PSK         │
└───────────────────┘        └──────────────────────┘
```

Panel connects to the agent for management; it connects directly to each
component's state publisher for live telemetry. The panel never holds
`HMAC_KEY`; the component's state publisher is modified to accept either
`HMAC_KEY` (today's fleet-internal use) or `MANAGER_PSK` (panel subscribers).

---

## 2. Keys and key management

Three keys total:

| Key | Type | Who holds it | Purpose |
|---|---|---|---|
| `HMAC_KEY` | 32-byte PSK | every component + agent | component-to-component and agent-to-component authenticity |
| `MANAGER_PSK` | 32-byte PSK | agent + panel + component state publishers | panel-to-agent authenticity, panel-to-publisher authenticity |
| `operator_key` | 32 bytes derived | panel (RAM only) + agent (verifier only) | proves a human operator is driving a panel request |

`operator_key = Argon2id(password, agent_salt, mem=256MiB, iters=3, threads=1)`.

Each agent has its own 32-byte `agent_salt`, generated at first-run and stored
next to the verifier. Same password + different agents → different operator
keys. Password rotation re-runs Argon2id with a fresh salt and pushes the new
verifier to each agent via an operator-authed `rotate_verifier` request.

All keys live in the OS credential store (Windows Credential Manager on
Windows, age-encrypted file on Linux/macOS) alongside the existing
`PolySignalLab/HMAC_KEY` entry:

| Credential name | On panel host | On PSL host |
|---|---|---|
| `PolySignalLab/HMAC_KEY` | — | yes |
| `PolySignalLab/MANAGER_PSK` | yes | yes |
| `PolySignalLab/OPERATOR_SALT` | — | yes |
| `PolySignalLab/OPERATOR_VERIFIER` | — | yes |

The operator never enters a password on a component host. Only the panel's
operator enters a password at panel launch, and that password is Argon2id'd in
the panel's address space then wiped.

---

## 3. Transport

- TCP over Tailscale mesh.
- Default agent port: **19733** (adjacent to existing 19731 signal / 19732
  state).
- Frame format is inherited from the existing IPC: `[4-byte big-endian
  length][payload bytes]`. Max frame size 256 KiB (raised from 64 KiB on the
  signal path, since config and log-range responses can be larger).
- One TCP connection = one session. Streaming operations (`log_tail`) open
  their own dedicated connection. No request-id multiplexing in v0.

---

## 4. Message envelope

Every payload — request and response — is wrapped in a signed JSON envelope:

```json
{
  "payload": "<canonical JSON of the inner message>",
  "nonce":   "<32 hex chars = 128 bits>",
  "ts":      "<unix seconds, integer>",
  "sig":     "<64 hex chars = HMAC-SHA256(MANAGER_PSK, ts ‖ nonce ‖ payload_bytes)>",
  "op_sig":  "<optional, same but keyed by operator_key>"
}
```

- `payload` is a canonicalized JSON string: UTF-8, `sort_keys=true`,
  `separators=(',', ':')`, no trailing whitespace. This matches the existing
  canonicalization on the signal path.
- `nonce` is 16 random bytes, hex-encoded. Freshness window: ts must be within
  ±60 s of server clock. Agent maintains a sliding window of the last 2048
  nonces and rejects replays.
- `sig` is **always present**. Verifies panel holds `MANAGER_PSK`.
- `op_sig` is present on **management requests** (lifecycle, config_set,
  config_get, log_*) and the responses to them. Verifies operator authorization.
  Read-only queries that don't carry sensitive data (`agent_hello`,
  `agent_ping`, `component_list`) require only `sig`.

Inner payload shape:

```json
{
  "type":    "<message-type, e.g. component_start>",
  "req_id":  "<opaque string, echoed in response>",
  "args":    { ... }
}
```

For responses, the inner payload is:

```json
{
  "type":   "<original-type>.ok"  |  "<original-type>.err",
  "req_id": "<echoed>",
  "data":   { ... }    // on .ok
  "error":  { "code": "<symbol>", "message": "<human>", "detail": {...} }  // on .err
}
```

---

## 5. Session model

On connect, the panel **must** send `agent_hello` as the first message. Agent
replies with its capabilities, the operator salt, and supported protocol
versions. Panel derives `operator_key` locally (or reuses the cached one if
salts match across agents), then issues subsequent management requests.

If a management request arrives before a successful `agent_hello` has been
processed on this connection, agent responds with `error.session_not_ready`.

Connections are long-lived but the agent may close idle connections after 15
minutes. Panel reconnects on demand.

---

## 6. Message catalog

### 6.1 Agent-level (sig only)

#### `agent_hello`
```
req:  { "panel_version": "0.1.0" }
resp: {
  "agent_version": "0.1.0",
  "host_id": "vps-01",
  "operator_salt_b64": "<base64, 32 bytes>",
  "argon2id": { "mem_kib": 262144, "iters": 3, "threads": 1 },
  "caps": ["lifecycle", "config", "logs", "rotate_verifier"],
  "proto_versions": [0]
}
```

#### `agent_ping`
```
req:  {}
resp: { "uptime_sec": 12345, "agent_time": 1745000000 }
```

#### `component_list`
Returns known components on this host and their current lifecycle state.
Telemetry endpoint is advertised so the panel can connect directly.
```
req:  {}
resp: {
  "components": [
    {
      "id": "polydatacollector",
      "display_name": "PolyDataCollector",
      "state": "running" | "starting" | "stopping" | "stopped" | "crashed",
      "pid": 4821,
      "started_at": 1745000000,
      "telemetry_endpoint": "vps-01.internal:19732",
      "last_exit_code": null
    },
    ...
  ]
}
```

### 6.2 Component lifecycle (sig + op_sig)

#### `component_start`
```
req:  { "id": "polydatacollector" }
resp: { "state": "starting", "pid": 4821 }
```
State transitions to `running` or `crashed` asynchronously; panel can poll
with `component_status` or rely on the next `component_list`.

#### `component_stop`
```
req:  { "id": "polydatacollector", "grace_sec": 10 }
resp: { "state": "stopping" }
```
Agent sends the component's configured `stop_signal` (e.g. SIGTERM /
CTRL_BREAK_EVENT), waits up to `grace_sec`, then escalates to SIGKILL /
TerminateProcess.

#### `component_restart`
```
req:  { "id": "polydatacollector", "grace_sec": 10 }
resp: { "state": "stopping" }
```
Equivalent to `stop` then `start` once the process has actually exited. Still
a single protocol message so operator auth is checked once. Note: there is
**no** auto-restart on config change. Operator must explicitly restart.

#### `component_status`
```
req:  { "id": "polydatacollector" }
resp: {
  "state": "running",
  "pid": 4821,
  "started_at": 1745000000,
  "last_exit_code": null,
  "cpu_pct": 4.7,
  "rss_mb": 182
}
```

### 6.3 Configuration (sig + op_sig)

#### `config_files`
```
req:  { "id": "polydatacollector" }
resp: { "files": [{ "path": "config.yml", "size": 2183, "mtime": 1744998000, "sha256": "..." }] }
```

#### `config_get`
```
req:  { "id": "polydatacollector", "path": "config.yml" }
resp: { "path": "config.yml", "content_utf8": "...", "sha256": "...", "mtime": 1744998000 }
```
Agent rejects paths outside the component's manifest-declared `config_files`
list (prevents path traversal from a compromised panel).

#### `config_set`
```
req:  {
  "id": "polydatacollector",
  "path": "config.yml",
  "new_content_utf8": "...",
  "expected_sha256": "<sha of previous version>"
}
resp: { "sha256": "<new sha>", "mtime": 1745000100 }
err:  {
  "code": "config_conflict",
  "detail": { "current_sha256": "..." }
}
```
Compare-and-swap. If `expected_sha256` doesn't match the file's current hash,
request fails — two concurrent editors can't silently overwrite each other.
Agent writes to `path.tmp` and atomically renames. Config change is
**not** auto-applied; component keeps running with old config until explicitly
restarted.

### 6.4 Logs (sig + op_sig)

#### `log_files`
```
req:  { "id": "polydatacollector" }
resp: { "files": [{ "path": "logs/collector.log", "size": 8472032, "mtime": 1744998000 }] }
```

#### `log_grep`
Server-side regex search. The request cap fields are clamped by the agent.
```
req:  {
  "id": "polydatacollector",
  "path": "logs/collector.log",
  "pattern": "ERROR|WARN",
  "since_ts": 1744990000,
  "until_ts": 1745000000,
  "max_matches": 5000,
  "max_bytes":   10485760,
  "context_lines": 2
}
resp: {
  "matches": [
    { "byte_offset": 182344, "line_no": 4211, "text": "...", "ctx_before": ["..."], "ctx_after": ["..."] },
    ...
  ],
  "truncated": false,
  "scanned_bytes": 8400000
}
```
Regex engine is **RE2** (linear time, no catastrophic backtracking). Agent
compiles the pattern per request, rejects malformed patterns with
`error.bad_pattern`. Hard upper caps at the agent, regardless of request
values:
- `max_matches` ≤ 50 000
- `max_bytes` ≤ 100 MiB
- `context_lines` ≤ 20
- `pattern` ≤ 1 KiB

#### `log_range`
Raw byte range. For scrollback pagination, export-to-disk, etc.
```
req:  { "id": "polydatacollector", "path": "logs/collector.log", "offset": 0, "length": 65536 }
resp: { "bytes_b64": "...", "next_offset": 65536, "eof": false }
```

#### `log_tail` (streaming)
Opens a separate TCP connection. After the signed `log_tail` request, agent
pushes unsolicited signed frames:
```
frame: {
  "offset": 9123456,
  "bytes_b64": "..."                              // if no filter_pattern
  "match":   { "line_no": N, "text": "..." }      // if filter_pattern is set
}
```
Connection stays open until panel closes it, or agent closes on error /
rotation.

### 6.5 Meta (sig + op_sig)

#### `rotate_verifier`
Pushes a new `{salt, verifier}` pair. Signed under both current operator_key
and MANAGER_PSK (the current verifier) to prevent a network attacker who
somehow has `MANAGER_PSK` from re-enrolling. After success, agent's stored
verifier is updated. Any open panel sessions on the old key continue until
next reconnect.

---

## 7. Enrollment handshake (agent ⇄ component)

Operators don't hand-write `pslagent.toml`. Instead, component enrollment is
a one-time handshake where the component describes itself to the agent.

Invoked by:
```
pslagent enroll \
    --launch-cmd "python -m src.main" \
    --cwd /home/psl/PolyDataCollector \
    [--env KEY=VAL ...]
```

The agent:

1. Allocates an ephemeral localhost TCP port `E`.
2. Spawns the target process with the provided `--launch-cmd`, `--cwd`,
   `--env`, plus the additional env var:
   ```
   PSLAGENT_ENROLL_ENDPOINT=127.0.0.1:<E>
   PSLAGENT_ENROLL_NONCE=<16 hex bytes>
   ```
3. Waits up to 15 seconds for the component to connect to `127.0.0.1:E` and
   send an **enrollment frame** (length-prefixed JSON, no HMAC — the channel
   is localhost with restrictive socket permissions):
   ```json
   {
     "nonce": "<the nonce passed in the env var>",
     "id":    "polydatacollector",
     "display_name":        "PolyDataCollector",
     "config_files":        ["config.yml"],
     "log_files":           ["logs/collector.log"],
     "telemetry_endpoint":  { "host": "auto", "port": 19732 },
     "stop_signal":         "SIGTERM",
     "stop_signal_windows": "CTRL_BREAK_EVENT",
     "start_timeout_sec":   20,
     "healthcheck_timeout_sec": 5
   }
   ```
4. Validates the nonce echo, writes a new entry into `pslagent.toml`,
   acknowledges with `{"ok": true}`. The component then exits (it was only
   started to introduce itself).
5. If the component fails to connect within the timeout, or echoes the wrong
   nonce, enrollment fails with a clear error.

The nonce prevents an unrelated local process from pretending to be the
component being enrolled.

**What components must implement** to be enrollable: detect
`PSLAGENT_ENROLL_ENDPOINT` in the environment; if set, connect, send the
manifest, exit 0 without doing their normal work. This is one ~30-line helper
per language (Python and C++).

Once enrolled, the component no longer participates in enrollment on
subsequent starts — it ignores `PSLAGENT_ENROLL_ENDPOINT` when not set. The
agent uses the recorded entry in `pslagent.toml` for all future supervision.

Re-enrollment: `pslagent enroll --update <id>` re-runs the handshake and
overwrites the existing entry (for when a component adds a new log file, say).

---

## 8. Component manifest: `pslagent.toml`

Written by the agent, never hand-edited in the normal flow.

```toml
host_id = "vps-01"
agent_version = "0.1.0"
enrolled_components_schema = 1

[[component]]
id = "polydatacollector"
display_name = "PolyDataCollector"
launch_cmd = ["python", "-m", "src.main"]
cwd = "/home/psl/PolyDataCollector"
env = ["PYTHONUNBUFFERED=1"]
config_files = ["config.yml"]
log_files = ["logs/collector.log"]
telemetry_endpoint = { host = "vps-01", port = 19732 }
stop_signal = "SIGTERM"
stop_signal_windows = "CTRL_BREAK_EVENT"
start_timeout_sec = 20
healthcheck_timeout_sec = 5
enrolled_at = 1745000000
```

Location:
- Windows: `%ProgramData%\PSLAgent\pslagent.toml`
- Linux/macOS: `/etc/pslagent/pslagent.toml`

Permissions: owner-only read/write (the account the agent runs under).

---

## 9. Error codes

All errors surface as `<type>.err` responses with a `code` symbol drawn from:

| Code | Meaning |
|---|---|
| `session_not_ready` | request sent before `agent_hello` completed on this connection |
| `bad_signature` | PSK HMAC did not verify |
| `bad_op_signature` | operator HMAC did not verify, or missing when required |
| `stale_timestamp` | ts outside ±60 s window |
| `replayed_nonce` | nonce was already seen in the sliding window |
| `bad_payload` | payload failed canonical JSON parse or schema |
| `unknown_component` | `id` not in this host's manifest |
| `invalid_state` | operation illegal for current component state (e.g. stop on already stopped) |
| `config_conflict` | `config_set` compare-and-swap failed |
| `path_not_allowed` | file path outside declared manifest set |
| `bad_pattern` | regex compile failed (RE2 error) |
| `result_truncated` | informational; carried on partial results |
| `internal` | bug; `detail.trace_id` correlates to agent log |

---

## 10. Security considerations

- **Two-PSK separation.** Panel hosts never hold `HMAC_KEY`. Operator-machine
  compromise does not yield component-to-component impersonation across the
  fleet. State publishers accept either PSK for **receive-only** subscription;
  this is intentional, the publisher emits data but performs no actions.
- **Operator key is derived, not stored.** Agents hold the verifier, not the
  password. Per-host salt prevents one compromised agent from helping attack
  another.
- **Replay / forgery.** Existing nonce + timestamp + sliding window are reused;
  the mac_operator MAC also includes nonce + ts so an attacker with
  `MANAGER_PSK` but no operator key cannot forge management requests.
- **Path traversal.** Config and log accesses are restricted to the manifest's
  declared file sets. No free-form paths.
- **Regex DoS.** RE2 only; hard-capped match and byte budgets; hard-capped
  pattern length.
- **Keylogger / compromised panel.** Not mitigated. If the panel process is
  compromised while running, the operator key is in its RAM. This is an
  accepted risk; panel hosts are expected to be operator-trusted.
- **Agent compromise.** Full compromise of an agent yields: ability to
  impersonate operator to that agent; ability to read/modify that host's
  configs and logs; ability to start/stop that host's components. It does
  **not** yield the operator's password (only a verifier), nor the ability to
  masquerade as the operator to other agents (different salts).
- **Enrollment security.** The enrollment socket is localhost only with
  owner-only permissions; the nonce prevents race-in local processes. Avoid
  enrolling on a multi-tenant host.

---

## 11. Open questions / future work

- **Session tokens.** In v0, every management request carries the operator
  MAC. A future v1 could issue a short-lived session token after first
  `agent_hello` so subsequent requests don't recompute the operator MAC. Not
  needed at current scale.
- **Streaming log tail filter language.** `log_tail` accepts a regex like
  `log_grep`. Could extend to multi-term expressions, severity filters, or
  structured-log (JSON) field matching.
- **Fleet-wide messaging.** Panel currently issues requests per agent. For
  "restart everything" a simple fan-out in the panel is enough; no broker
  needed.
- **Component health probes.** Agent could periodically ping `agent_ping`-
  equivalent on each supervised component (e.g. over the telemetry channel)
  to detect hung-but-alive states. Deferred until needed.
- **Protocol versioning.** `agent_hello.proto_versions` list accommodates
  future breaking changes; v0 is the baseline. Panel and agent both check
  overlap and downgrade if possible.
- **macOS support.** Everything here is portable (TCP + TOML + POSIX
  signals), but the credential store backend differs; `keystore.py`'s
  Windows/Linux split already handles that and can be mirrored for the C++
  agent.
