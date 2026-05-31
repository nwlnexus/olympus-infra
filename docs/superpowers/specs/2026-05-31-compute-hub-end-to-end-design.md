# Compute-Hub End-to-End Push/Pull Design

**Date:** 2026-05-31
**Scope:** Five targeted changes to bring all compute-hub nodes (onode-030c31, onode-0312ce, onode-0314ac) into the same self-healing state as styx and management-hub, while also fixing the ansible-pull infrastructure that has been broken across the fleet since April.

---

## Context

Compute-hub is a 3-node k3s HA cluster. All three nodes run ansible-pull via a systemd timer invoking `/opt/ansible-pull/ansible-pull-run`. The service has been broken since April because `playbooks/pull/compute-hub.yml` was referenced in the script but never existed. This work takes a different approach: rather than creating a per-host playbook, **all hosts use `playbooks/pull/olympus.yml`** with opt-in role guards — less drift, one place to maintain.

**Confirmed node state (2026-05-31):**

| Node | LAN IP | Tailscale IP | open-iscsi | multipathd | Initiator IQN | atlas |
|------|--------|-------------|-----------|-----------|--------------|-------|
| onode-030c31 | 192.168.253.7 | 100.97.218.87 | 2.1.9 ✓ | active ✓ | Ubuntu default (wrong) | not installed |
| onode-0312ce | 192.168.253.8 | 100.126.57.18 | 2.1.9 ✓ | active ✓ | Ubuntu default (wrong) | not installed |
| onode-0314ac | **192.168.253.9** (not .20) | 100.81.35.111 | unknown | unknown | unknown | not installed |

**Critical:** onode-030c31 and onode-0312ce have the **identical** default IQN (`iqn.2004-10.com.ubuntu:01:dfbae5d5031`). The `csi_node` mode fixes this with per-hostname IQNs.

---

## Root Causes of Broken ansible-pull

1. **`compute-hub.yml` playbook never existed** — the run script called it since bootstrap
2. **`ProtectHome=true` in `ansible-pull.service.j2`** — systemd blocks Ansible's temp-file creation in `~/.ansible/tmp`; current deployed service is old (no ProtectHome) but any re-deploy would introduce the regression
3. **Missing `export HOME=` on Linux** — the run script sets HOME on macOS but not Linux; systemd services don't guarantee HOME is set
4. **OP token path inconsistency** — run script uses `/opt/ansible-pull/.op-service-account-token`; all other fleet tooling uses `/etc/olympus/op-service-account-token`
5. **`group_vars` mismatch** — `ansible_pull_playbook: playbooks/pull/olympus.yml` but the deployed service script calls `compute-hub.yml`

---

## 1. Add `iscsi` and `atlas` to `olympus.yml`

### Purpose
`olympus.yml` is the unified pull playbook for all nodes. Adding these two roles here (with opt-in guards) means any host — compute-hub, management-hub, future hosts — picks them up simply by setting the controlling `_state` var in their group or host vars. No per-host playbooks needed.

### Change to `playbooks/pull/olympus.yml`

Insert after the `baseline` role, before `ansible-pull`:

```yaml
    - role: iscsi
      tags: [iscsi]
      when: iscsi_state is defined

    - role: atlas
      tags: [atlas]
      when: atlas_state is defined
```

---

## 2. Add Vars to `compute_hub` Group Vars

### Change to `inventory/group_vars/compute_hub.yml`

Append:
```yaml

# iSCSI host prereqs — QNAP Trident CSI manages login/CHAP; Ansible sets initiator name only
iscsi_state: present
iscsi_mode: csi_node

# Atlas daemon
atlas_state: present
```

No `iscsi_op_item` — credentials are not needed at host level (CSI owns them).
`ansible_pull_playbook` already says `playbooks/pull/olympus.yml` — correct, no change needed.

---

## 3. Fix ansible-pull Role Templates

### 3a. `roles/ansible-pull/templates/ansible-pull.service.j2`

**Problem:** `ProtectHome=true` prevents Ansible from writing to `~/.ansible/tmp`.

**Fix:** Change to `ProtectHome=false` so the ansible user can access its own home directory:

```diff
-ProtectHome=true
+ProtectHome=false
```

### 3b. `roles/ansible-pull/templates/ansible-pull-run.j2`

**Problem 1:** Linux branch missing `export HOME=`. Without it, Ansible may resolve `~` incorrectly in systemd context.

**Problem 2:** OP token path is `/opt/ansible-pull/.op-service-account-token` for Linux. All other fleet tooling uses `/etc/olympus/op-service-account-token`. The user has placed the token at `/etc/olympus/` on compute nodes too.

**Fix the Linux section** (currently lines 29-33):

```bash
{% else %}
# ── Linux: ensure user-local bin is on PATH ───────────────────────────────────
export HOME="/home/{{ ansible_pull_user }}"
export PATH="${HOME}/.local/bin:${PATH}"
ANSIBLE_PULL_BIN="{{ ansible_pull_bin_linux }}"
OP_TOKEN_FILE="${WRAPPER_OP_TOKEN_FILE:-/etc/olympus/op-service-account-token}"
{% endif %}
```

Changes: added `export HOME=`, changed OP token path.

---

## 4. Fix `onode-0314ac` Host Vars Comment

### Change to `inventory/host_vars/onode-0314ac.yml`

The LAN IP comment is wrong. The actual IP (confirmed via Tailscale SSH) is `192.168.253.9`.

```diff
-# LAN IP: 192.168.253.20
+# LAN IP: 192.168.253.9
```

The `ansible_host: 127.0.0.1` (for local ansible-pull) is unchanged. This is documentation only.

---

## 5. Verification Approach

Since all three compute nodes use `ansible_connection: local` for ansible-pull, the ad-hoc test runs the pull playbook from the control machine against each node individually using SSH overrides.

**For each node, run:**
```bash
source ~/projects/personal/.env
cd /path/to/olympus-sdk
ANSIBLE_CONFIG=infra/compute-hub-push.cfg ansible-playbook \  # if cfg exists; otherwise use push pattern
  -i /path/to/olympus-infra/inventory/compute-hub.yml \
  -e "ansible_host=<node_ip> ansible_connection=ssh ansible_user=ansible ansible_ssh_private_key_file=~/.ssh/ansible ansible_limit=<node_name>" \
  /path/to/olympus-infra/playbooks/pull/olympus.yml \
  --limit <node_name>
```

**Verify per node:**
- `sudo cat /etc/iscsi/initiatorname.iscsi` → `iqn.2004-04.net.olympus:<hostname>`
- `sudo -u atlas HOME=/var/lib/atlas atlas status` → `Status: REGISTERED`
- `systemctl is-active atlas` → `active`

**Then trigger ansible-pull directly on each node** to confirm the systemd service works end-to-end:
```bash
ssh ansible@<node_ip> 'sudo -u ansible /opt/ansible-pull/ansible-pull-run 2>&1 | tail -10'
```

---

## Summary of File Changes

| Action | File |
|--------|------|
| Modify | `playbooks/pull/olympus.yml` — add iscsi and atlas opt-in roles |
| Modify | `inventory/group_vars/compute_hub.yml` — add iscsi_state, iscsi_mode, atlas_state |
| Modify | `roles/ansible-pull/templates/ansible-pull.service.j2` — ProtectHome=false |
| Modify | `roles/ansible-pull/templates/ansible-pull-run.j2` — add HOME export, fix OP token path on Linux |
| Modify | `inventory/host_vars/onode-0314ac.yml` — fix LAN IP comment |

**No new playbooks created.** `olympus.yml` is the single unified pull playbook for the fleet.

---

## Constraints

- `inject_facts_as_vars = False` — use `ansible_facts['hostname']` throughout
- `csi_node` mode sets initiator name to `iqn.2004-04.net.olympus:{{ ansible_facts['hostname'] }}`; for compute nodes the inventory hostname and OS hostname match, so no alias confusion
- Atlas registration: all 3 nodes are new (no existing registration); the bootstrap key flow runs on each
- onode-0314ac: only reachable via Tailscale (100.81.35.111) for ad-hoc testing; LAN SSH not routable from control machine
- Do not modify olympus-gitops (separate agent); no CSI manifests in scope
