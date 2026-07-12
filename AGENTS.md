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
│   ├── ansible-pull          # Configure ansible-pull cron/LaunchDaemon
│   ├── data-services         # ai-hub native Postgres/Redis/ClickHouse/Redpanda
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
│   ├── data-services.yml     # Push playbook for ai-hub data tier
│   └── pull/                 # ansible-pull playbooks (run daily on hosts)
│       ├── ai-hub.yml
│       ├── compute-hub.yml
│       ├── management-hub.yml # Retired context, kept for history
│       └── olympus.yml        # Unified pull playbook for live hosts
└── inventory/
    ├── group_vars/           # Variables per group (all.yml, ai-hub.yml, etc.)
    ├── host_vars/            # Variables per host
    ├── ai-hub.yml            # Pull inventory for ai-hub
    └── olympus.yml           # Unified push inventory: k3s, data tier, provisioning
```

## Managed Hosts

| Host | OS | Role |
|---|---|---|
| olympus | Ubuntu on onode-030c31/0312ce/0314ac plus naraka-01 | Single k3s HA cluster: control-plane on the onodes, naraka-01 as agent/ingress node |
| ai-hub | macOS (Apple Silicon) | Native data tier and model host; **not** a k8s node |
| styx | Linux | PXE/Packer provisioning host; **not** a k8s node |
| management-hub | Retired | Historical context only; do not add new services here |

The old `compute-hub`/`management-hub` split has converged into the single
`olympus` cluster. Ansible changes should target the live `olympus` inventory
unless a legacy playbook explicitly says otherwise.

### ai-hub data tier

`ai-hub` runs host-native services because Apple Silicon GPU/Metal acceleration
is not available to Linux containers. The `data-services` role manages service
accounts, directories under `/opt/olympus`, and macOS LaunchDaemons for:

| Service | Port | Notes |
|---|---:|---|
| PostgreSQL | 5432 | Tuned conservatively for a 64 GB Mac Studio so Ollama can load large models |
| Redis | 6379 | Tailnet-facing cache/service dependency |
| ClickHouse | 8123 / 9000 | HTTP/native endpoints; bound to `data_services_tailscale_ip` |
| Redpanda | 9092 | Kafka-compatible broker for platform event streams |

Operational constraints:

- `data_services_tailscale_ip` is `100.95.232.41`; services bind to tailnet
  addresses or allow the Tailscale CGNAT range instead of public interfaces.
- Secrets are not stored in this public repo. The push wrapper in the private
  `olympus-sdk` repo passes `ds_pg_password`, `ds_redis_password`, and
  `ds_ch_password` as extra vars to `playbooks/data-services.yml`.
- `roles/data-services` still contains an older `macos-ollama.yml` include.
  Treat `roles/ollama` as the canonical Ollama owner; rerun the ai-hub
  maintenance playbook after data-service changes if the legacy daemon appears.

### Ollama ownership and model residency

Use `roles/ollama` for Ollama. It installs/updates the Homebrew `ollama` package,
owns `/Library/LaunchDaemons/homebrew.mxcl.ollama.plist`, and removes the legacy
`com.olympus.ollama` LaunchDaemon that previously failed to bind `:11434`.

Current ai-hub model split:

| Workload | Models | Residency |
|---|---|---|
| OpenMemory/mem0 embedding | `nomic-embed-text` | Warmed after restart via `/api/embeddings` |
| OpenMemory categorization | `llama3.2:3b` | Warmed after restart via `/api/generate` |
| OpenMemory fact extraction | `qwen2.5:7b-instruct` | Warmed after restart; chosen because it is fast and non-thinking |
| Agentic coding | `qwen3.6:27b-mlx` | Pulled but loaded on demand; not warmed |

`ollama_keep_alive: "24h"`, `ollama_max_loaded_models: 3`, and
`ollama_num_parallel: 1` keep the mem0 path hot without forcing the large coding
model to stay resident. The large coding model can evict an idle warm model when
needed, then the mem0 trio warms again on the next role run or service restart.

### ClickHouse runbook notes

`roles/data-services/templates/clickhouse-config.xml.j2` replaces the default
ClickHouse config, so it must explicitly define `system.query_log`. The current
config creates `system.query_log` with a 14-day TTL; without it, dashboards or
telemetry queries backed by `system.query_log` fail with `UNKNOWN_TABLE`.

The Homebrew ClickHouse v26.5.x build has runtime expression JIT failures on
ai-hub. `clickhouse-users.xml.j2` disables `compile_expressions` and
`compile_aggregate_expressions`; do not re-enable them until the Homebrew build
is verified fixed.

### Linux node QUIC tuning

`roles/common` sets `net.core.rmem_max` and `net.core.wmem_max` to `7500000` on
Linux hosts. These kernel parameters are global, so setting them on k3s nodes
also affects the cloudflared pods. The value matches quic-go's expected UDP
buffer ceiling and prevents intermittent tunnel control-stream failures and edge
502s caused by packet loss. The unified pull playbook skips `common` on Darwin,
so this tuning is not applied to ai-hub.

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
  - llama3.2:3b
  - qwen2.5:7b-instruct
  - qwen3.6:27b-mlx
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
ansible-playbook -i inventory/olympus.yml playbooks/data-services.yml \
  -e "ds_pg_password=... ds_redis_password=... ds_ch_password=..." \
  --check --diff
```

Pull playbooks run daily via ansible-pull on each host. Keep them idempotent and
fast; avoid slow package/service mutations unless the role is explicitly
opted-in by a `<role>_state` variable.
