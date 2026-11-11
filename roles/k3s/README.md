# k3s role

| Mode | Vars |
|---|---|
| HA server (control-plane) | `k3s_ha: true`, `k3s_primary: true/false`, `k3s_init` (one node), `k3s_vip`, `k3s_token_op_ref`, optional `k3s_node_labels`, `k3s_etcd_snapshot_dir` |
| Agent (worker) | `k3s_agent: true`, `k3s_server_url: https://<vip>:6443`, `k3s_token_op_ref`, `k3s_node_labels`, `k3s_node_taints` |
| Single-node (legacy) | neither `k3s_ha` nor `k3s_agent` |

Labels apply at first join (config.yaml) and are reconciled on servers via kubectl.
A secondary (joining) server's config comes from `templates/config-server-join.yaml.j2`:
it also renders `tls-san`, `disable` and the marked `kubelet-arg` block, so a new server
matches the existing ones and starts with its kubelet arguments (no restart). Join new
servers with `playbooks/push/join-k3s-server.yml` only, and never re-run the role on an
existing server: the config is rewritten whole (token included) and a hand-added block
(e.g. from `playbooks/k3s-disable-traefik.yml`) would be lost at the next restart.
`k3s_cleanup_orphan_traefik_crds` (default false, opt-in) deletes traefik.io CRDs
cluster-wide from any server that runs the role; joining servers also set
`k3s_remove_disable_skip_files` (its removal notifies a k3s restart).
`tasks/node-labels.yml` retries for up to two minutes while a just-started node
registers.
etcd snapshots go to `k3s_etcd_snapshot_dir` (mount it first, e.g. QNAP NFS).
`k3s_node_ip` (per host) pins `node-ip` as a marked block in config.yaml
(`tasks/node-ip.yml`); k3s reads it only at start, so restart one server at a
time. `tasks/cni-bridge-fixer-retire.yml` removes the retired
k3s-cni-bridge-fixer. `playbooks/push/k3s-node-network.yml` runs both (and the
baseline node-network tasks) on their own, without restarting anything.
`k3s_etcd_expose_metrics` (servers, default false) writes `etcd-expose-metrics: true`
as a marked block (`tasks/etcd-metrics.yml`) so etcd serves /metrics on the node
address (port 2381), and first installs an nftables table that admits only
loopback, the pod network and the cluster nodes to that port.
`playbooks/push/k3s-etcd-metrics.yml` applies it without restarting k3s; restart
one server at a time with `scripts/k3s-health-gate.sh` between servers.

## Kubernetes API audit log

`k3s_audit_log_enabled` (HA servers, default false) turns on kube-apiserver audit
logging (`tasks/audit-log.yml`). It writes, in this order:

1. the log directory `k3s_audit_log_dir` (default `/var/lib/rancher/k3s/server/logs`, root 0700);
2. the policy `k3s_audit_policy_path` (default `/var/lib/rancher/k3s/server/audit.yaml`,
   root 0600, from `templates/audit-policy.yaml.j2`);
3. an assert that both exist (kube-apiserver does not start without the policy file);
4. a marked `kube-apiserver-arg:` block in `/etc/rancher/k3s/config.yaml`
   (`audit-policy-file`, `audit-log-path=<dir>/audit.log`, `audit-log-maxage`,
   `audit-log-maxbackup`, `audit-log-maxsize`). The join template and the primary's
   inline config render the same block, so a new server starts with it.

This block is the only `kube-apiserver-arg` key the role writes. Do not add a second
one anywhere (another block, a hand edit or a `config.yaml.d` drop-in): a duplicated
top-level key in config.yaml silently replaces the first list. Add further API server
arguments to this block instead. `tests/k3s-join-server` fails if the key appears twice.

| Variable | Default | Meaning |
|---|---|---|
| `k3s_audit_log_enabled` | `false` | Write the policy and the flags (false removes the flags) |
| `k3s_audit_policy_path` | `/var/lib/rancher/k3s/server/audit.yaml` | Policy file |
| `k3s_audit_log_dir` | `/var/lib/rancher/k3s/server/logs` | Log directory; the log is `audit.log` there |
| `k3s_audit_log_maxage` | `7` | Days to keep rotated files |
| `k3s_audit_log_maxbackup` | `5` | Rotated files to keep |
| `k3s_audit_log_maxsize` | `100` | MB per file before rotation |
| `k3s_audit_always_log_users` | `[system:serviceaccount:atlas-system:k8s-mcp]` | Users whose every request is recorded |
| `k3s_audit_always_log_groups` | `[olympus:agents-view]` | Groups whose every request is recorded |

Disk use per server is bounded by maxsize x (maxbackup + 1): 600 MB with the defaults.

What the policy records (first matching rule wins; Metadata = who, what, when, verb and
response code, never a body; Request adds the request body, never the response):

- dropped: `/healthz*`, `/readyz*`, `/livez*`, `/metrics`, `/version`, `/openapi*`;
- Metadata for every request (reads included) by the always-logged users and groups,
  ahead of all noise rules (an empty list omits its rule);
- dropped: reads by `system:nodes`, and by the control plane and k3s itself
  (`system:kube-proxy`, `system:kube-controller-manager`, `system:kube-scheduler`,
  `system:apiserver`, `system:k3s-supervisor`, `system:k3s-controller`,
  `k3s-cloud-controller-manager`; one list in the template, used by every machine rule);
  kubelet `nodes/status` and `pods/status` update/patch heartbeats by `system:nodes`;
  lease get/list/watch/update/patch and all event requests, but only by nodes,
  ServiceAccounts and that control-plane list (a person touching a lease or deleting
  events falls through and is recorded);
- Metadata for Secrets, ConfigMaps, `serviceaccounts/token` and token reviews, for every
  user, ahead of every Request rule, so no body of those is ever recorded;
- dropped: other ServiceAccount reads (controller watch traffic);
- Metadata (no body) for create/update/patch/delete/deletecollection by nodes,
  ServiceAccounts and the control-plane list;
- Request (with the request body) for those writes by everyone else (people);
- Metadata for everything else.

It is on for the cluster: `k3s_audit_log_enabled: true` in the `compute_hub` and
`agent_services` group vars (every server must agree; `tests/k3s-join-server` checks it), so
a server joined later gets the same config. Stage it with `playbooks/push/k3s-audit-log.yml`
(`--limit <server>`, `--check --diff` first). The play never restarts k3s; the flags take
effect at the next restart. Restart one server at a time, the canary first, with
`scripts/k3s-health-gate.sh` before and after each.

The flags come from config.yaml, so they do not appear on the `k3s server` command line
(`pgrep -af 'k3s server'` shows no audit flag). Audit logging is active on a server when
its log exists, is non-empty and keeps growing; run this twice a minute apart and compare
the timestamps:

```sh
sudo test -s /var/lib/rancher/k3s/server/logs/audit.log && sudo stat -c '%s %Y' /var/lib/rancher/k3s/server/logs/audit.log
```

### What to check on the first server

- `sudo journalctl -u k3s --since -10min | grep -iE 'audit|policy'` shows no error;
- `sudo k3s kubectl get --raw /readyz` prints `ok`, and the node is Ready;
- the audit log exists, is non-empty and grows (command above);
- `scripts/k3s-health-gate.sh` passes. Only then restart the next server.

### Rollback on a server

If kube-apiserver does not come up after a restart with the flags: remove the marked
`k3s_audit_log` block (`# BEGIN/END ANSIBLE MANAGED - k3s_audit_log`) from
`/etc/rancher/k3s/config.yaml` on that server, or run the play with
`-e k3s_audit_log_enabled=false --limit <host>`; restart k3s on it and run
`scripts/k3s-health-gate.sh`. Do not restart the next server until the first is healthy.

To disable, set the flag to false and run the play: it removes the block and keeps the
policy file and the logs. A server keeps logging until its next restart (the running
kube-apiserver still has the flags), and the policy file must stay until then; delete the
file and the logs by hand after every server has been restarted, if ever needed.
