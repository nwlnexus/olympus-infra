# Management-Hub End-to-End Push/Pull Design

**Date:** 2026-05-31
**Scope:** Four targeted changes to bring management-hub (naraka-01) push and pull playbooks to a fully functional, self-healing state.

---

## Context

Management-hub is a bare-metal k3s single-node cluster. Its Ansible inventory alias is `management-hub`; the real OS hostname is `naraka-01`. iSCSI volumes are served to workloads via the QNAP Trident CSI driver (deployed by Flux GitOps) — Ansible's only responsibility is ensuring the host-level prerequisites that Trident requires are in place.

**Current host state (naraka-01, confirmed 2026-05-31):**

| Package | State |
|---------|-------|
| `open-iscsi` 2.1.10 | Installed |
| `multipath-tools` 0.9.9 | Installed, `multipathd` active |
| iSCSI initiator name | `iqn.2004-10.com.ubuntu:01:dfbae5d5031` (Ubuntu default — WRONG) |
| `atlas` binary | Not installed, not registered |

---

## 1. Fix iSCSI Initiator Name Template (cross-cutting bug fix)

### Problem
The iscsi role sets the initiator IQN as:
```
InitiatorName=iqn.2004-04.net.olympus:{{ inventory_hostname }}
```
`inventory_hostname` is the Ansible inventory alias. For management-hub, the alias is `management-hub` but the machine's OS hostname is `naraka-01`. This would produce `iqn.2004-04.net.olympus:management-hub` — wrong, and inconsistent with the fleet standard which uses the real hostname.

### Fix
Change to `ansible_facts['hostname']` in all three iscsi task files:
```
InitiatorName=iqn.2004-04.net.olympus:{{ ansible_facts['hostname'] }}
```
`ansible_facts['hostname']` is the short OS hostname — `naraka-01` for management-hub, `styx` for styx (no behavioral change there since names match).

**Files to update:**
- `roles/iscsi/tasks/linux_host_mount.yml` (line with `Set deterministic iSCSI initiator name`)
- `roles/iscsi/tasks/linux_initiator_only.yml` (same task)
- `roles/iscsi/tasks/linux_csi_node.yml` (new file, see Piece 2 — write it correctly from the start)

---

## 2. Add `csi_node` Mode to iscsi Role

### Purpose
Bare-metal k3s nodes running the QNAP Trident CSI driver need the iSCSI stack available at the host level. Trident handles target discovery, CHAP authentication, and iSCSI login itself — Ansible must only ensure the prerequisites exist.

This is distinct from `host_mount` (Ansible mounts the volume) and `initiator_only` (Ansible logs in; used for Longhorn compute-hub nodes). For CSI-managed nodes we need even less from Ansible.

### New file: `roles/iscsi/tasks/linux_csi_node.yml`

```yaml
---
- name: Install iSCSI and multipath packages
  ansible.builtin.apt:
    name:
      - open-iscsi
      - multipath-tools
    state: present
    update_cache: false
  become: true

- name: Enable and start iscsid
  ansible.builtin.systemd:
    name: iscsid
    enabled: true
    state: started
  become: true

- name: Enable and start multipathd
  ansible.builtin.systemd:
    name: multipathd
    enabled: true
    state: started
  become: true

- name: Set deterministic iSCSI initiator name
  ansible.builtin.copy:
    content: "InitiatorName=iqn.2004-04.net.olympus:{{ ansible_facts['hostname'] }}\n"
    dest: /etc/iscsi/initiatorname.iscsi
    mode: "0600"
  become: true
  notify: Restart iscsid
```

### Dispatcher update: `roles/iscsi/tasks/main.yml`

Add a fourth branch:
```yaml
- name: iSCSI — Linux csi_node
  ansible.builtin.include_tasks: linux_csi_node.yml
  when:
    - ansible_facts['os_family'] == "Debian"
    - iscsi_mode == "csi_node"
    - iscsi_state == "present"
```

### Defaults update: `roles/iscsi/defaults/main.yml`

`csi_node` is not the default mode (existing default `host_mount` is unchanged). No new defaults required beyond what already exists.

---

## 3. Add Atlas and iSCSI to Management-Hub Pull Playbook

### `playbooks/pull/management-hub.yml` — updated role sequence

```yaml
roles:
  - role: baseline
    tags: [baseline]

  - role: iscsi
    tags: [iscsi]
    when: iscsi_state is defined

  - role: atlas
    tags: [atlas]
    when: atlas_state is defined

  - role: ddclient
    tags: [ddclient]
    when: ddclient_state is defined

  - role: 1password-connect
    tags: [1password-connect]

  # ── Hermes ENC (must be LAST) ────────────────────────────────────────────
  - role: hermes-classify-include
    tags: [hermes-classify]
```

`iscsi` before `atlas` (storage prereqs first). `1password-connect` keeps its unconditional placement since it's a cluster service.

---

## 4. Add Vars to Management-Hub Group Vars

### `inventory/group_vars/management-hub.yml` additions

```yaml
# iSCSI host prereqs — Trident CSI driver manages login/CHAP; Ansible sets initiator name only
iscsi_state: present
iscsi_mode: csi_node

# Atlas daemon
atlas_state: present
```

No `iscsi_op_item` — credentials are not fetched at the host level. Trident CSI owns them via ExternalSecret from 1Password Connect.

---

## 5. Atlas Registration (first-time path)

Atlas has never been installed on naraka-01. The role will:
1. Download binary from `https://assets.nwlnexus.net/install/atlas` (install.sh)
2. Create `atlas` system user (home `/var/lib/atlas`, nologin)
3. `atlas status` → exit 1 (not registered)
4. Fetch bootstrap key from `op://Dev/hermes-secrets/bootstrap-key` via OP SA token at `/etc/olympus/op-service-account-token`
5. Run `atlas setup --server https://api.nwlnexus.net --bootstrap-key <key>` as atlas user → registers `naraka-01` with Hermes
6. Deploy systemd units and start service

This is the first full end-to-end registration path (styx was already registered when the role ran).

---

## Summary of File Changes

### olympus-infra

| Action | File |
|--------|------|
| Bug fix | `roles/iscsi/tasks/linux_host_mount.yml` — `inventory_hostname` → `ansible_facts['hostname']` |
| Bug fix | `roles/iscsi/tasks/linux_initiator_only.yml` — same fix |
| New file | `roles/iscsi/tasks/linux_csi_node.yml` — csi_node mode tasks |
| Modified | `roles/iscsi/tasks/main.yml` — add csi_node dispatcher branch |
| Modified | `playbooks/pull/management-hub.yml` — add iscsi and atlas roles |
| Modified | `inventory/group_vars/management-hub.yml` — add iscsi_state, iscsi_mode, atlas_state |

### Not in scope (GitOps territory)
`clusters/management-hub/qnap-storage/` — TridentBackendConfig, StorageClass, ExternalSecret (handled by olympus-gitops, separate agent).

---

## Constraints

- `inject_facts_as_vars = False` in ansible.cfg — use `ansible_facts['hostname']`, not `ansible_hostname`
- Roles must be idempotent — `apt` install of already-present packages is a no-op; initiator name write is idempotent
- The `csi_node` mode must NOT login to targets or configure CHAP — that would conflict with Trident's session management
- Pull playbook must remain fast — the new tasks are all no-ops after first run on naraka-01 (packages already installed)
