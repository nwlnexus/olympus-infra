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
`k3s_cleanup_orphan_traefik_crds` (default true) deletes traefik.io CRDs cluster-wide
from any server that runs the role; it is false for joining servers.
etcd snapshots go to `k3s_etcd_snapshot_dir` (mount it first, e.g. QNAP NFS).
`k3s_node_ip` (per host) pins `node-ip` as a marked block in config.yaml
(`tasks/node-ip.yml`); k3s reads it only at start, so restart one server at a
time. `tasks/cni-bridge-fixer-retire.yml` removes the retired
k3s-cni-bridge-fixer. `playbooks/push/k3s-node-network.yml` runs both (and the
baseline node-network tasks) on their own, without restarting anything.
