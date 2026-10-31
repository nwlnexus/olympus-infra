# Join a Mac-mini arm64 VM to the cluster as a k3s agent

olympus-sdk#694, decision H20. Hosts: `mmini-01-vm`, `mmini-02-vm` (group `k3s_mac_agents`).
Agents only: no etcd, no control plane, never in `k3s_servers`. Each node is labelled
`olympus.io/host=mac-mini` and `olympus.io/mac-host=<mac name>` and tainted
`olympus.io/arch=arm64:NoSchedule`, so only workloads that tolerate the taint (an arm64
ARC runner scale set first) are scheduled there.

## Before the first run

1. The VM is up (Tart, bridged NIC on the .253 network) with a DHCP reservation. Set
   `k3s_node_ip` in `inventory/host_vars/<vm>.yml` and merge it. The play refuses to run
   while it is empty or not an address of the VM.
2. Bootstrap the VM once (ansible user, op token, baseline with key-only ssh and the
   `olympus-cni-ipv6-drop` unit, tailscale, atlas, ansible-pull). Dry run first, then for real;
   the first run connects as the owner, see the header of `playbooks/push/bootstrap-host.yml`:

   ```sh
   uv tool run --from ansible-core ansible-playbook -i inventory/olympus.yml playbooks/push/bootstrap-host.yml --limit mmini-01-vm --tags baseline,tailscale,atlas,ansible-pull --check --diff
   ```

3. atlas enrols with the shared bootstrap key (`atlas_op_bootstrap_key_ref`, read from
   1Password with the service-account token already on the VM); there is no per-host key. If
   enrolment is refused, issue one in Hermes and re-run `--tags atlas`.

## Join (owner runs it, from olympus-infra on ai-agent-host, one VM per run)

Health gate before:

```sh
scripts/k3s-health-gate.sh
```

Dry run (pre-checks only, renders the role, installs nothing):

```sh
uv tool run --from ansible-core ansible-playbook -i inventory/olympus.yml playbooks/push/join-k3s-agent.yml --limit mmini-01-vm --check --diff
```

Join (takes an etcd snapshot on the reference server, asks for a `yes`):

```sh
uv tool run --from ansible-core ansible-playbook -i inventory/olympus.yml playbooks/push/join-k3s-agent.yml --limit mmini-01-vm
```

Health gate after, with the node count raised by one in a copy of the config:

```sh
sed 's/^EXPECTED_NODE_COUNT=.*/EXPECTED_NODE_COUNT=8/' scripts/k3s-health-gate.conf > /tmp/gate-mmini.conf
scripts/k3s-health-gate.sh -c /tmp/gate-mmini.conf
```

Set the number to the current node count plus one. Then `kubectl get node mmini-01-vm --show-labels`
and `kubectl describe node mmini-01-vm | grep -A2 Taints`. Repeat for `mmini-02-vm`.

## Rollback

```sh
kubectl drain mmini-01-vm --ignore-daemonsets --delete-emptydir-data
kubectl delete node mmini-01-vm
```

Then run `/usr/local/bin/k3s-agent-uninstall.sh` on the VM.

## Notes

- k3s is pinned in `inventory/group_vars/all.yml` (`k3s_version`); the installer picks the
  arm64 binary. Upgrades go through the system-upgrade-controller Plans in olympus-gitops, and
  those Plans need to tolerate the arm64 taint before they can upgrade these nodes.
- Labels, the taint and the kubelet reservations (`system-reserved cpu=1,memory=2Gi`,
  `kube-reserved memory=1Gi`, eviction `memory.available<1Gi`, `pod-max-pids=4096`) are in
  `/etc/rancher/k3s/config.yaml` on the VM, so they survive restarts.
- `join-naraka-agent.yml` is unchanged and still refuses every host but naraka-01.
