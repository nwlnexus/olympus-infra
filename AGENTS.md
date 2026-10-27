# olympus-infra — Agent Context

Public repo containing Ansible roles and pull-mode playbooks for the Olympus homelab.
This repo is public so `ansible-pull` can run on hosts without credentials.

Push playbooks (with secrets) live in the private `olympus-sdk` sibling repo.

## Repository Structure

```text
olympus-infra/
├── roles/                    # All shared Ansible roles
│   ├── atlas                 # Atlas daemon/package management
│   ├── baseline              # Baseline host health and identity checks
│   ├── bootstrap-user        # Create ansible user, SSH keys, sudo
│   ├── tailscale             # Install + configure Tailscale
│   ├── k3s                   # Install k3s (single-node or HA)
│   ├── 1password-connect     # Deploy 1Password Connect server
│   ├── traefik               # Traefik ingress (Helm, for standalone hosts)
│   ├── cloudflared           # Cloudflare Tunnel daemon
│   ├── cloudflared-k8s       # cloudflared as k8s Deployment (via Helm)
│   ├── flux                  # Flux CD bootstrap
│   ├── external-secrets      # ESO bootstrap (CRDs + ClusterSecretStore)
│   ├── eso-bootstrap         # ExternalSecret for cluster secrets
│   ├── external-dns          # external-dns Helm deployment
│   ├── cert-manager          # cert-manager Helm deployment
│   ├── ansible-pull          # ansible-pull wrapper + systemd timer / LaunchDaemon
│   ├── data-services         # data-hub service users, /opt/olympus dirs, temporary Postgres
│   ├── hermes-classify-include # Hermes dynamic role/include support
│   ├── iscsi                 # iSCSI prerequisites for QNAP-backed storage
│   ├── mem0-client           # Workstation OpenMemory MCP + Claude recall hook
│   ├── ollama                # Ollama (retired on data-hub 2026-10-27; kept for rollback)
│   ├── llama-server          # llama.cpp llama-server, one LaunchDaemon per model + watchdog (macOS)
│   ├── inference-server      # llama.cpp llama-server on Ubuntu (systemd, Vulkan/ROCm) for the GEEKOM A9: units, watchdog timer, TTM kernel params
│   ├── qnap-csi-bootstrap    # QNAP CSI/Trident bootstrap on the k3s primary
│   ├── homebrew              # Homebrew (macOS)
│   ├── ddclient              # Dynamic DNS client
│   ├── common                # Common OS setup (packages, sysctl, etc.)
│   └── node-prereqs          # k3s node prerequisites
├── playbooks/
│   ├── data-services.yml     # Push playbook for data-hub: Postgres + llama-server + LiteLLM
│   └── pull/                 # ansible-pull playbooks (run daily on hosts)
│       ├── compute-hub.yml
│       ├── management-hub.yml # Retired context, kept for history
│       └── olympus.yml        # Unified pull playbook for live hosts
└── inventory/
    ├── group_vars/           # Variables per group (all.yml, data-hub.yml, etc.)
    ├── host_vars/            # Variables per host
    ├── data-hub.yml          # Pull inventory for data-hub
    └── olympus.yml           # Unified push inventory: k3s, data tier, provisioning
```

## Managed Hosts

| Host | OS | Role |
|---|---|---|
| olympus | Ubuntu on onode-030c31/0312ce/0314ac, onode-0636e4/062caa, plus naraka-01 | Single k3s HA cluster: control-plane (embedded etcd) on the five onodes, naraka-01 as agent/ingress node |
| data-hub | macOS (Apple Silicon) | Native data tier and model host; **not** a k8s node |
| styx | Linux (Ubuntu 26.04; bond0) | PXE provisioning host, Plex, iSCSI + NFS mounts; **not** a k8s node |
| management-hub | Retired | Historical context only; do not add new services here |

### k3s server pools (inventory/olympus.yml)

| Group | Hosts | Notes |
|---|---|---|
| `compute_hub` | onode-030c31 (cluster-init), onode-0312ce, onode-0314ac | Default compute pool, untainted. Carries the cluster-scoped one-shot roles (1Password Connect, ESO, cloudflared-k8s, Trident bootstrap) on the primary. |
| `agent_services` | onode-0636e4 (.11), onode-062caa (.12) | HW9 (olympus-sdk#567): etcd members too (5 in all), but labelled `olympus.io/role=agent-services`, `olympus.io/ci=true` and tainted `olympus.io/role=agent-services:NoSchedule`; only ARC, memory and inference are pinned there. Bootstrapped with `playbooks/push/bootstrap-host.yml`, joined one at a time with `playbooks/push/join-k3s-server.yml`. Pull inventory `inventory/agent-services.yml`. |
| `k3s_servers` | parent of both | Every etcd member; `playbooks/push/kube-vip.yml` targets it. |
| `k3s_agents` | naraka-01 | `join-naraka-agent.yml` refuses any other host. |

The old `compute-hub`/`management-hub` split has converged into the single
`olympus` cluster. Ansible changes should target the live `olympus` inventory
unless a legacy playbook explicitly says otherwise.

### data-hub data tier (retired)

`data-hub` runs host-native services because Apple Silicon GPU/Metal acceleration
is not available to Linux containers. After the 2026-10-20 decommission
(olympus-sdk#446) the host runs only:

| Service | Port | Notes |
|---|---:|---|
| llama-server + LiteLLM | 8081-8083 / 4000 | The fleet's inference node; see "data-hub serving profile" |
| PostgreSQL | 5432 | Temporary, until WS9 of olympus-sdk#444 confirms nothing is left in `claude_mem` |

`data-services` manages the `_postgres` account, the Postgres directories under
`/opt/olympus`, and the Postgres LaunchDaemon. ClickHouse, Redis and the QNAP
archive NFS mount (`com.olympus.nfs._Volumes_ai-hub-data`) were unused (no data,
no clients) and are gone: `tasks/macos-legacy-cleanup.yml` boots out, disables and
deletes their LaunchDaemons (`data_services_retired_daemons`) on any host that
still has them, and keeps the data directories. Redpanda and Colima are retired
the same way (`/opt/olympus/{config,data,logs}/redpanda` and the `_redpanda` user
are removed; set `data_services_remove_redpanda_user: false` to keep the user).

Operational constraints:

- `data_services_tailscale_ip` is `100.95.232.41`; services bind to tailnet
  addresses or allow the Tailscale CGNAT range instead of public interfaces.
- Every data-hub LaunchDaemon that binds the tailnet IP (Postgres, llama-server, LiteLLM)
  starts through a wrapper that waits for that address and has `KeepAlive` plus
  `ThrottleInterval`. At the 2026-07-05 boot Postgres started before tailscaled and
  bound `127.0.0.1` only, unnoticed for 3.5 months.
- Secrets are not stored in this public repo. The push wrapper in the private
  `olympus-sdk` repo passes `ds_pg_password` (only used to `initdb` a new data
  dir). `ds_redis_password` and `ds_ch_password` are no longer used.
- `roles/llama-server` owns the model servers and `roles/ollama` only removes Ollama
  (see "data-hub serving profile" below).

### data-hub serving profile (llama-server + LiteLLM)

data-hub is the fleet's inference node. `roles/llama-server` and `roles/litellm` own it
end to end; `playbooks/data-services.yml` runs `ollama`, `llama-server`, `litellm` as a
second play after `data-services`, and the hourly pull (`playbooks/pull/olympus.yml`)
runs `ollama` then `llama-server` on Darwin. Vars live in `inventory/group_vars/data_hub.yml`
(the host is in the `data_hub` group in both `inventory/olympus.yml` and the pull
inventory `inventory/data-hub.yml`; before 2026-10-20 the file was `data-hub.yml`,
matched no group, and applied to nothing).

History: Ollama 0.30.11's MLX engine stopped completing generations for
`qwen3.6:27b-mlx` on 2026-10-26 (also after a restart), while its `/api/tags` probe
stayed green. The owner chose a hard cutover with no soak (olympus-sdk#588, plan
`docs/plans/2026-10-27-data-hub-llama-server-cutover.md` in olympus-sdk).

- **llama-server** (Homebrew `llama.cpp` >= 0.7.0, installed `present` and `brew pin`ned).
  One process and LaunchDaemon per model, all resident; there is no model swapper,
  because on-demand swapping is the scheduler layer that wedged Ollama.

  | Instance | Port | Model | LiteLLM aliases |
  |---|---:|---|---|
  | `qwen36-27b` | 8081 | `Qwen3.6-27B-Q5_K_M.gguf` (`unsloth/Qwen3.6-27B-GGUF`) | `memory-extract`, `coder-heavy` |
  | `qwen25-7b` | 8082 | `Qwen2.5-7B-Instruct-Q4_K_M.gguf` (`bartowski/...`) | `coder-light` |
  | `nomic-embed` | 8083 | `nomic-embed-text-v1.5.f16.gguf` (768-dim) | `memory-embed` |

  - Labels `com.olympus.llama-server.<name>`, wrappers `/usr/local/bin/llama-server-serve-<name>`,
    logs `/var/log/llama-server-<name>.{log,err}` (rotated by `/etc/newsyslog.d/llama-server.conf`).
    Each binds `100.95.232.41` only, never `0.0.0.0`, and has no API key (tailnet only,
    parity with Ollama; LiteLLM is the client door). The wrapper waits for the tailnet
    address like Postgres and LiteLLM, then `exec sudo -Hu nwilliams-lucas`.
  - Arguments are per-instance lists in group_vars (`-np 1`, 32k context, `-fa on`,
    `--jinja`, `--metrics`, `--no-webui`, `--timeout 900`; the 27B also
    `--reasoning-format deepseek` and thinking off by default). A flag the installed
    `llama-server --help` does not know goes in `llama_server_drop_flags`.
  - Models live in `/opt/olympus/models/gguf` (run-user owned; `/opt/olympus` itself is
    left as `data-services` made it). They are downloaded from Hugging Face at pinned
    revisions with `get_url` and a sha256 (the LFS oid), only when missing; the size is
    asserted on every run, the full sha256 only with `-e llama_server_verify_checksums=true`.
  - Homebrew refuses to run as a user that does not own `/opt/homebrew` (the login user),
    so the pull (as `ansible`) only asserts the binary and its version; install and pin
    happen in the push. `--tags llama_server_prepare` runs only the asserts, package,
    models directory, downloads and removals, without touching a LaunchDaemon.
  - A changed wrapper or plist is reloaded (bootout, then a retried bootstrap); an
    unloaded daemon is bootstrapped; a running, unchanged one is never touched. Plists
    of instances that left the list are booted out and removed (never the watchdog).
    After a (re)start the role waits for `/health` 200 and probes: a strict
    `json_schema` chat request must return `{"ok": <bool>}`, an embedding must have 768
    values. Unchanged runs skip the probes (`llama_server_probe_mode`), so an hourly pull
    never queues behind a long extraction on a single slot.
  - **Watchdog** (`com.olympus.llama-server-watchdog`, `/usr/local/bin/llama-server-watchdog`,
    every 60 s, log `/var/log/llama-server-watchdog.log`): `/health` 503 means loading and
    is fine for 10 minutes. A busy chat instance must show decode progress
    (`llamacpp:requests_processing`, `llamacpp:n_decode_total` from `/metrics`, falling
    back to `/slots`); an idle one must answer a 4-token completion; the embedder must
    return 768 values. Three failed checks or three stalled minutes, at most once per
    10-minute cooldown, mean `SIGKILL` and a launchd restart, logged as
    `RESTART <name> reason=...` (also to syslog via `logger`).
  - Timeouts: memory worker 300 s < LiteLLM 600 s < llama-server 900 s.
- **LiteLLM** (`com.litellm.proxy` LaunchDaemon, wrapper `/usr/local/bin/litellm-serve`):
  binds the tailnet IP on `:4000`, same wait-for-address guard. `litellm_backend:
  llama_server` renders each alias as `openai/<instance alias>` with `api_base
  http://100.95.232.41:<port>/v1` and `api_key: not-used`; `memory-extract` and
  `coder-heavy` send `extra_body.chat_template_kwargs.enable_thinking`
  (`litellm_extract_thinking`, `litellm_coder_heavy_thinking`, both false). There is no
  fallback alias. `coder-cloud` stays disabled until an Anthropic key exists at
  `litellm_anthropic_key_op_ref` (then set `litellm_coder_cloud_enabled: true`). The
  master key is read on the host with `op read` using `/etc/olympus/op-service-account-token`;
  the config is mode 0600. `litellm_backend: ollama` renders the previous Ollama config
  byte for byte (rollback).
- **Ollama** is retired: `ollama_state: absent` with `ollama_remove_package: true` and
  `ollama_purge_models: true` boots out `homebrew.mxcl.ollama`, uninstalls the package and
  deletes `~nwilliams-lucas/.ollama/models`. Rollback is a push with olympus-sdk's
  `infra/rollback/data-hub-serving-ollama.yml` (`ollama_state: present`,
  `llama_server_state: absent`, `litellm_backend: ollama`, `litellm_extract_model:
  qwen2.5:7b-instruct`): it reinstalls the pinned Ollama and re-pulls `nomic-embed-text`
  and `qwen2.5:7b-instruct` (about 5 GB). A follow-up removes the Ollama role from the
  playbooks once the cutover is verified. `roles/data-services` no longer installs Ollama.

Residency budget (64 GiB unified memory; computed from the GGUF sizes, so confirm with
`vm_stat` and the llama-server load logs after the first start):

| Item | GiB |
|---|---:|
| `Qwen3.6-27B-Q5_K_M` weights | 18.2 |
| ...KV cache at 32k, f16: 16 full-attention layers x 4 KV heads x 256 dim = 64 KiB/token | 2.0 |
| ...linear-attention state (48 layers) plus compute buffers | 1.7 |
| `Qwen2.5-7B-Instruct-Q4_K_M` weights | 4.4 |
| ...KV cache at 32k, f16: 28 layers x 4 KV heads x 128 dim = 56 KiB/token | 1.75 |
| ...compute buffers | 0.5 |
| `nomic-embed-text-v1.5` f16 weights plus KV (8k ctx, 4 slots) and buffers | 0.5 |

- All three resident: about 29 GiB, always (Ollama's MLX 27B alone took 30-45 GiB).
- Against 64 GiB: macOS 8, LiteLLM and server processes 0.5, Postgres until WS9 4.5,
  models 29, macOS CI runner (#391) budget 16 = 58 GiB, leaving about 6 GiB (about 10.5
  once Postgres is gone). If that is tight, the 27B drops to Q4_K_M (16.8 GB, same pin).
  The default Metal working-set cap (`iogpu.wired_limit_mb=0`, roughly 48 GiB) is well
  above the model total.

### Linux node QUIC tuning

`roles/common` sets `net.core.rmem_max` and `net.core.wmem_max` to `7500000` on
Linux hosts. These kernel parameters are global, so setting them on k3s nodes
also affects the cloudflared pods. The value matches quic-go's expected UDP
buffer ceiling and prevents intermittent tunnel control-stream failures and edge
502s caused by packet loss. The unified pull playbook skips `common` on Darwin,
so this tuning is not applied to data-hub.

`roles/common` also raises `fs.inotify.max_user_instances` to `8192` and
`fs.inotify.max_user_watches` to `1048576`. On k3s nodes root alone holds one
inotify instance per containerd-shim, so the Ubuntu default of 128 is exhausted
and watcher-based pods (argo-events controller) crash-loop with "too many open
files".

### k3s versions

- One pin for every k3s install: `k3s_version` in `inventory/group_vars/all.yml` (an exact release, e.g. `v1.35.9+k3s1`). The `k3s` role refuses to install without one; it never upgrades an installed node (`creates:` guard).
- Upgrades go only through the system-upgrade-controller Plans in olympus-gitops (`clusters/olympus/system-upgrade/`), one minor at a time, per `docs/superpowers/plans/2026-10-04-k3s-upgrade-1.35.md`. Bump the pin here after an upgrade completes.
- Plans pin an exact `version:` (a patch release is a one-line bump). Never add `drain` or `channel` to a Plan.

### k3s node networking

Each k3s node pins its IPv4 address as `node-ip` (`k3s_node_ip` in
`inventory/host_vars/<node>.yml`, a marked block in
`/etc/rancher/k3s/config.yaml` written by `roles/k3s/tasks/node-ip.yml`).
Without it, k3s picks the node IP at start from the default route, and after a
link outage it could pick the public IPv6 address and fail the etcd membership
check. The addresses must match the router's DHCP reservations.

`roles/baseline/tasks/k8s-network.yml` (`baseline_k8s_node_network: true` on
the onodes and naraka-01) codifies the host networking:

- `/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg`: cloud-init no longer
  rewrites netplan. The netplan files themselves are hand-maintained (onodes:
  one `id0` ethernet matching `en*`; naraka-01: `bond0`).
- `/etc/systemd/network/05-k8s-unmanaged.network`: networkd never manages
  `veth*`, `cni0` or `flannel.*` (this replaced `k3s-cni-bridge-fixer`, which
  the k3s role now removes).
- `/etc/systemd/network/10-netplan-id0.network.d/50-carrier.conf`
  (`IgnoreCarrierLoss=10min`, onodes): a short link outage no longer drops
  the DHCP address and default route. naraka-01's `bond0` already has
  `ConfigureWithoutCarrier=yes`, which implies `IgnoreCarrierLoss=yes`.
- `systemd-networkd-wait-online.service.d/50-any-ipv4.conf`: boot waits for
  any link with a routable IPv4 address, instead of every NIC in the netplan
  file (an unplugged NIC timed it out on every boot).

**Never `networkctl reload` (or `systemctl reload systemd-networkd`) a live
node.** On systemd 255 a reload re-configures every link whose `.network`
file or drop-ins changed: it releases the DHCP lease, removes the address and
default route, and drops foreign addresses and routing rules (the kube-vip
VIP, Tailscale's rules). The networkd files take effect at the next reboot;
reboot one node at a time. Apply or check by hand with
`playbooks/push/k3s-node-network.yml`, which never restarts k3s or networkd.

### mem0-client workstation wiring

`roles/mem0-client` is a workstation role for Claude Code clients, not a cluster
service. It:

- Merges an OpenMemory MCP entry into `~/.claude.json` without clobbering other
  MCP servers.
- Installs `~/.claude/hooks/mem0-recall-hook.sh`.
- Appends a `SessionStart` hook to `~/.claude/settings.json`.

The hook posts the session working directory to
`/api/v1/memories/filter` with `mem0_user_id: mnemosyne` and fails open on any
timeout, missing dependency, or non-200 response, so Claude Code startup is never
blocked by memory recall.

## Variable Naming Conventions

Variables in `group_vars/` and `host_vars/` follow `<role>_<setting>` patterns:

```yaml
tailscale_authkey: "{{ vault_tailscale_authkey }}"
k3s_version: "v1.29.0+k3s1"
ollama_models:
  - nomic-embed-text
  - qwen3.6:27b-mlx
  - qwen2.5:7b-instruct
data_services_tailscale_ip: "100.95.232.41"
flux_version: "v2.3.0"
cloudflared_state: present   # present | absent
```

State variables (`<role>_state: present|absent`) control whether a role installs or removes.

## Adding a New Role

1. Create `roles/<name>/` with standard Ansible structure (`tasks/main.yml`, `defaults/main.yml`, etc.)
2. Add role defaults with sensible values
3. Document any required variables in `defaults/main.yml`
4. Wire into the appropriate push playbook in `olympus-sdk/infra/push-playbooks/`
5. Add group/host vars as needed in `inventory/`

## Testing

Always test roles with `--check` before applying:

```bash
ansible-playbook -i inventory/olympus.yml playbook.yml --check
ansible-playbook -i inventory/olympus.yml playbook.yml --diff --check
ansible-playbook -i inventory/olympus.yml --limit data_services playbooks/data-services.yml \
  --check --diff
```

Pull playbooks run daily via ansible-pull on each host. Keep them idempotent and
fast; avoid slow package/service mutations unless the role is explicitly
opted-in by a `<role>_state` variable.

To merge without a merge command, label the PR `automerge` (`gh pr edit <n> --add-label automerge`) and `.github/workflows/automerge.yml` squash-merges it once the base branch's required checks pass (GitHub App credentials: olympus-sdk#576).

<!-- gitnexus:start -->
# GitNexus — Code Intelligence

This project is indexed by GitNexus as **olympus-infra**. Use the GitNexus MCP tools to understand code, assess impact, and navigate safely.

> Index stale? Run `node .gitnexus/run.cjs analyze` from the project root — it auto-selects an available runner. No `.gitnexus/run.cjs` yet? `npx gitnexus analyze` (npm 11 crash → `npm i -g gitnexus`; #1939).

## Always Do

- **MUST run impact analysis before editing any symbol.** Before modifying a function, class, or method, run `impact({target: "symbolName", direction: "upstream"})` and report the blast radius (direct callers, affected processes, risk level) to the user.
- **MUST run `detect_changes()` before committing** to verify your changes only affect expected symbols and execution flows. For regression review, compare against the default branch: `detect_changes({scope: "compare", base_ref: "main"})`.
- **MUST warn the user** if impact analysis returns HIGH or CRITICAL risk before proceeding with edits.
- When exploring unfamiliar code, use `query({search_query: "concept"})` to find execution flows instead of grepping. It returns process-grouped results ranked by relevance.
- When you need full context on a specific symbol — callers, callees, which execution flows it participates in — use `context({name: "symbolName"})`.
- For security review, `explain({target: "fileOrSymbol"})` lists taint findings (source→sink flows; needs `analyze --pdg`).

## Never Do

- NEVER edit a function, class, or method without first running `impact` on it.
- NEVER ignore HIGH or CRITICAL risk warnings from impact analysis.
- NEVER rename symbols with find-and-replace — use `rename` which understands the call graph.
- NEVER commit changes without running `detect_changes()` to check affected scope.

## Resources

| Resource | Use for |
|----------|---------|
| `gitnexus://repo/olympus-infra/context` | Codebase overview, check index freshness |
| `gitnexus://repo/olympus-infra/clusters` | All functional areas |
| `gitnexus://repo/olympus-infra/processes` | All execution flows |
| `gitnexus://repo/olympus-infra/process/{name}` | Step-by-step execution trace |

<!-- gitnexus:end -->
