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
│   ├── ollama                # Ollama AI inference server (macOS + Linux)
│   ├── qnap-csi-bootstrap    # QNAP CSI/Trident bootstrap on the k3s primary
│   ├── homebrew              # Homebrew (macOS)
│   ├── ddclient              # Dynamic DNS client
│   ├── common                # Common OS setup (packages, sysctl, etc.)
│   └── node-prereqs          # k3s node prerequisites
├── playbooks/
│   ├── data-services.yml     # Push playbook for data-hub: Postgres + Ollama + LiteLLM
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
| olympus | Ubuntu on onode-030c31/0312ce/0314ac plus naraka-01 | Single k3s HA cluster: control-plane on the onodes, naraka-01 as agent/ingress node |
| data-hub | macOS (Apple Silicon) | Native data tier and model host; **not** a k8s node |
| styx | Linux (Ubuntu 26.04; bond0) | PXE provisioning host, Plex, iSCSI + NFS mounts; **not** a k8s node |
| management-hub | Retired | Historical context only; do not add new services here |

The old `compute-hub`/`management-hub` split has converged into the single
`olympus` cluster. Ansible changes should target the live `olympus` inventory
unless a legacy playbook explicitly says otherwise.

### data-hub data tier (retired)

`data-hub` runs host-native services because Apple Silicon GPU/Metal acceleration
is not available to Linux containers. After the 2026-10-20 decommission
(olympus-sdk#446) the host runs only:

| Service | Port | Notes |
|---|---:|---|
| Ollama + LiteLLM | 11434 / 4000 | The fleet's inference node; see "data-hub serving profile" |
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
- Every data-hub LaunchDaemon that binds the tailnet IP (Postgres, Ollama, LiteLLM)
  starts through a wrapper that waits for that address and has `KeepAlive` plus
  `ThrottleInterval`. At the 2026-07-05 boot Postgres started before tailscaled and
  bound `127.0.0.1` only, unnoticed for 3.5 months.
- Secrets are not stored in this public repo. The push wrapper in the private
  `olympus-sdk` repo passes `ds_pg_password` (only used to `initdb` a new data
  dir). `ds_redis_password` and `ds_ch_password` are no longer used.
- `roles/ollama` is the only Ollama owner (see "data-hub serving profile" below).

### data-hub serving profile (Ollama + LiteLLM)

data-hub is the fleet's inference node. `roles/ollama` and `roles/litellm` own it
end to end; `playbooks/data-services.yml` runs them as a second play after
`data-services`. Vars live in `inventory/group_vars/data_hub.yml` (the host is in
the `data_hub` group in both `inventory/olympus.yml` and the pull inventory
`inventory/data-hub.yml`; before 2026-10-20 the file was `data-hub.yml`, matched no
group, and applied to nothing).

- **Ollama** (`homebrew.mxcl.ollama` LaunchDaemon, wrapper `/usr/local/bin/ollama-serve`,
  runs as `ollama_run_user`): binds `100.95.232.41:11434` only, never `0.0.0.0`
  (olympus-infra#1). The wrapper waits for that address before it execs, and launchd
  `KeepAlive` retries, so a boot where tailscaled is late cannot leave it unbound.
  `OLLAMA_KEEP_ALIVE=24h`, `NUM_PARALLEL=1`, `MAX_LOADED_MODELS=2`,
  `CONTEXT_LENGTH=32768`, `FLASH_ATTENTION=1`. Models live in the run user's
  `~/.ollama/models` (`OLLAMA_MODELS` is unset). Roster: `nomic-embed-text`,
  `qwen3.6:27b-mlx`, `qwen2.5:7b-instruct`; `llama3.2:3b` is removed from disk if present.
- **LiteLLM** (`com.litellm.proxy` LaunchDaemon, wrapper `/usr/local/bin/litellm-serve`):
  binds the tailnet IP on `:4000`, same wait-for-address guard. Aliases
  `memory-embed` (nomic-embed-text), `memory-extract` and `coder-heavy`
  (qwen3.6:27b-mlx), `coder-light` (qwen2.5:7b-instruct), `coder-cloud` (disabled
  until an Anthropic key exists at `litellm_anthropic_key_op_ref`; then set
  `litellm_coder_cloud_enabled: true`). The master key is read on the host with
  `op read` using `/etc/olympus/op-service-account-token`; the config is mode 0600.
  The role removes the old hand-made `~/Library/LaunchAgents/com.litellm.proxy.plist`.
  Per-client virtual keys need LiteLLM's database and are not provisioned yet.
- `roles/data-services` no longer installs Ollama (its `com.olympus.ollama` daemon is
  gone; `roles/ollama` still boots out any stray copy).

Residency budget (64 GiB unified memory; computed from model metadata, so confirm with
`ollama ps` and `vm_stat` after the first warm):

| Item | GiB |
|---|---:|
| `qwen3.6:27b-mlx` weights (nvfp4, 27.4B) | 17.7 |
| ...KV cache at 32k, f16: 16 full-attention layers x 4 KV heads x 256 dim = 64 KiB/token | 2.0 |
| ...linear-attention state (48 layers) plus compute buffers | 1.7 |
| `nomic-embed-text` weights plus KV | 0.4 |
| `qwen2.5:7b-instruct` weights (Q4_K_M) | 4.4 |
| ...KV cache at 32k, f16: 28 layers x 4 KV heads x 128 dim = 56 KiB/token | 1.75 |
| ...compute buffers | 0.5 |

- Steady state, 27B plus embedder: about 21.8 GiB.
- Worst allowed pair, 27B plus 7B: about 28.1 GiB (all three together would be about
  28.5 GiB; `MAX_LOADED_MODELS=2` is a policy limit, not a memory one).
- Against 64 GiB: macOS 8, Ollama/LiteLLM processes 0.5, Postgres until WS9 4.5, worst
  pair 28.1, macOS CI runner (#391) budget 16 = 57.1 GiB, leaving about 6.9 GiB (about
  11.4 once Postgres is gone). The default Metal working-set cap
  (`iogpu.wired_limit_mb=0`, roughly 48 GiB) is well above the 28.1 GiB model peak.
- With only two slots, an embed request while 27B and 7B are both warm evicts one of
  them, and the reload costs seconds (7B) to tens of seconds (27B). Raising
  `ollama_max_loaded_models` to 3 costs about 0.4 GiB if that thrash shows up.

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
