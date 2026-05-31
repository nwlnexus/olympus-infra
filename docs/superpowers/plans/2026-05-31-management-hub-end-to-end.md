# Management-Hub End-to-End Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring management-hub (naraka-01) pull playbook to a fully functional, self-healing state: fix the iSCSI initiator name template bug, add a CSI-node iSCSI prereq mode, add the Atlas daemon, and fix a broken path in the unified olympus.yml playbook.

**Architecture:** Four small role changes plus two playbook/group_vars updates. The iSCSI `csi_node` mode only ensures host prereqs (packages, service, initiator name); Trident CSI owns target login and CHAP. Atlas registration runs for the first time here (full bootstrap key flow). The `olympus.yml` unified playbook has a wrong OP token path on Linux — also fixed here since management-hub's future ansible-pull cron will use it.

**Tech Stack:** Ansible 2.15+, systemd, open-iscsi, multipath-tools, Atlas Rust daemon, 1Password CLI (`op`).

**Environment note:** Before any push/ad-hoc run from olympus-sdk, run `source ~/projects/personal/.env`. Pass vars via pull inventory override pattern: `-i olympus-infra/inventory/management-hub.yml -e "ansible_host=100.65.140.75 ansible_connection=ssh ansible_user=ansible ansible_ssh_private_key_file=~/.ssh/ansible"`.

**Discovered state on naraka-01 (2026-05-31):**
- `open-iscsi` 2.1.10 and `multipath-tools` 0.9.9 already installed, `multipathd` active
- Initiator name: `iqn.2004-10.com.ubuntu:01:dfbae5d5031` (Ubuntu default — must change)
- `atlas`: not installed, not registered (first full bootstrap path)
- No ansible-pull cron configured yet
- OP token at `/etc/olympus/op-service-account-token`; `olympus.yml` incorrectly checks `/opt/ansible-pull/.op-service-account-token`

---

## File Map

| Action | File |
|--------|------|
| Modify | `roles/iscsi/tasks/linux_host_mount.yml:87` — `inventory_hostname` → `ansible_facts['hostname']` |
| Modify | `roles/iscsi/tasks/linux_initiator_only.yml:9` — same fix |
| Create | `roles/iscsi/tasks/linux_csi_node.yml` — new CSI-node prereq mode |
| Modify | `roles/iscsi/tasks/main.yml` — add csi_node dispatcher branch |
| Modify | `playbooks/pull/olympus.yml` — fix OP token path pre_task |
| Modify | `playbooks/pull/management-hub.yml` — add iscsi and atlas roles |
| Modify | `inventory/group_vars/management-hub.yml` — add iscsi_state, iscsi_mode, atlas_state |

---

## Task 1 — Fix Initiator Name Template (bug fix, all modes)

**Files:**
- Modify: `roles/iscsi/tasks/linux_host_mount.yml:87`
- Modify: `roles/iscsi/tasks/linux_initiator_only.yml:9`

- [ ] **Step 1: Verify current content**

```bash
grep -n "inventory_hostname" \
  roles/iscsi/tasks/linux_host_mount.yml \
  roles/iscsi/tasks/linux_initiator_only.yml
```

Expected output:
```
roles/iscsi/tasks/linux_host_mount.yml:87:    content: "InitiatorName=iqn.2004-04.net.olympus:{{ inventory_hostname }}\n"
roles/iscsi/tasks/linux_initiator_only.yml:9:    content: "InitiatorName=iqn.2004-04.net.olympus:{{ inventory_hostname }}\n"
```

- [ ] **Step 2: Fix linux_host_mount.yml**

In `roles/iscsi/tasks/linux_host_mount.yml`, change line 87:

```yaml
    content: "InitiatorName=iqn.2004-04.net.olympus:{{ ansible_facts['hostname'] }}\n"
```

- [ ] **Step 3: Fix linux_initiator_only.yml**

In `roles/iscsi/tasks/linux_initiator_only.yml`, change line 9:

```yaml
    content: "InitiatorName=iqn.2004-04.net.olympus:{{ ansible_facts['hostname'] }}\n"
```

- [ ] **Step 4: Verify no remaining inventory_hostname in initiator name context**

```bash
grep -n "inventory_hostname" \
  roles/iscsi/tasks/linux_host_mount.yml \
  roles/iscsi/tasks/linux_initiator_only.yml
```

Expected: no output (both lines changed).

- [ ] **Step 5: Commit**

```bash
git add roles/iscsi/tasks/linux_host_mount.yml \
        roles/iscsi/tasks/linux_initiator_only.yml
git commit -m "fix(iscsi): use ansible_facts hostname for initiator IQN

inventory_hostname is the Ansible alias (e.g. 'management-hub') not the
real OS hostname ('naraka-01'). ansible_facts['hostname'] is the actual
system hostname and produces the correct IQN for fleet standardisation."
```

---

## Task 2 — Create `csi_node` Mode

**Files:**
- Create: `roles/iscsi/tasks/linux_csi_node.yml`
- Modify: `roles/iscsi/tasks/main.yml`

- [ ] **Step 1: Create linux_csi_node.yml**

Create `roles/iscsi/tasks/linux_csi_node.yml` with this exact content:

```yaml
# roles/iscsi/tasks/linux_csi_node.yml
---
# Ensures host-level iSCSI prerequisites for Trident CSI driver.
# The CSI driver handles target discovery, CHAP authentication, and login.
# Ansible only needs: packages installed, services running, initiator name set.

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

- [ ] **Step 2: Add csi_node branch to dispatcher**

In `roles/iscsi/tasks/main.yml`, append after the existing `initiator_only` block:

```yaml
- name: iSCSI — Linux csi_node
  ansible.builtin.include_tasks: linux_csi_node.yml
  when:
    - ansible_facts['os_family'] == "Debian"
    - iscsi_mode == "csi_node"
    - iscsi_state == "present"
```

Full file after change:
```yaml
---
- name: iSCSI — macOS
  ansible.builtin.include_tasks: macos.yml
  when:
    - ansible_facts['os_family'] == "Darwin"
    - iscsi_state == "present"

- name: iSCSI — Linux host_mount
  ansible.builtin.include_tasks: linux_host_mount.yml
  when:
    - ansible_facts['os_family'] == "Debian"
    - iscsi_mode == "host_mount"
    - iscsi_state == "present"

- name: iSCSI — Linux initiator_only
  ansible.builtin.include_tasks: linux_initiator_only.yml
  when:
    - ansible_facts['os_family'] == "Debian"
    - iscsi_mode == "initiator_only"
    - iscsi_state == "present"

- name: iSCSI — Linux csi_node
  ansible.builtin.include_tasks: linux_csi_node.yml
  when:
    - ansible_facts['os_family'] == "Debian"
    - iscsi_mode == "csi_node"
    - iscsi_state == "present"
```

- [ ] **Step 3: Verify dispatcher has all four branches**

```bash
grep -c "include_tasks" roles/iscsi/tasks/main.yml
```

Expected: `4`

- [ ] **Step 4: Commit**

```bash
git add roles/iscsi/tasks/linux_csi_node.yml \
        roles/iscsi/tasks/main.yml
git commit -m "feat(iscsi): add csi_node mode for Trident CSI host prereqs

New mode installs open-iscsi + multipath-tools, enables iscsid + multipathd,
and sets the initiator name. Does NOT do target discovery, CHAP config, or
login — those are owned by the Trident CSI driver."
```

---

## Task 3 — Fix olympus.yml OP Token Path

**Files:**
- Modify: `playbooks/pull/olympus.yml:22`

The pre_task on line 22 checks `/opt/ansible-pull/.op-service-account-token` for Linux, but all deployed hosts use `/etc/olympus/op-service-account-token`. This would cause every ansible-pull run on Linux hosts to fail.

- [ ] **Step 1: Read current pre_task**

```bash
sed -n '20,26p' playbooks/pull/olympus.yml
```

Expected current content:
```yaml
    - name: Assert OP service account token is readable
      ansible.builtin.stat:
        path: "{{ '/etc/olympus/op-service-account-token' if ansible_facts['os_family'] == 'Darwin' else '/opt/ansible-pull/.op-service-account-token' }}"
      register: _op_token_stat
      failed_when: not _op_token_stat.stat.exists
      tags: [always]
```

- [ ] **Step 2: Fix the path**

In `playbooks/pull/olympus.yml`, change the `path:` in the "Assert OP service account token is readable" task from:

```yaml
        path: "{{ '/etc/olympus/op-service-account-token' if ansible_facts['os_family'] == 'Darwin' else '/opt/ansible-pull/.op-service-account-token' }}"
```

to:

```yaml
        path: /etc/olympus/op-service-account-token
```

(All hosts — macOS included — use `/etc/olympus/op-service-account-token`.)

- [ ] **Step 3: Commit**

```bash
git add playbooks/pull/olympus.yml
git commit -m "fix(olympus): use correct OP token path for all platforms

All deployed hosts store the OP SA token at /etc/olympus/op-service-account-token.
The /opt/ansible-pull/ path was hypothetical and never deployed."
```

---

## Task 4 — Update Management-Hub Pull Playbook

**Files:**
- Modify: `playbooks/pull/management-hub.yml`

- [ ] **Step 1: Read current roles section**

```bash
grep -A 20 "^  roles:" playbooks/pull/management-hub.yml
```

- [ ] **Step 2: Add iscsi and atlas roles**

Replace the `roles:` block in `playbooks/pull/management-hub.yml` with:

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

    # ── Hermes ENC (must be LAST — appends roles, never displaces) ───────────
    - role: hermes-classify-include
      tags: [hermes-classify]
```

- [ ] **Step 3: Verify role order**

```bash
grep -E "role:|tags:" playbooks/pull/management-hub.yml
```

Expected order: baseline → iscsi → atlas → ddclient → 1password-connect → hermes-classify-include.

- [ ] **Step 4: Commit**

```bash
git add playbooks/pull/management-hub.yml
git commit -m "feat(management-hub): add iscsi (csi_node) and atlas to pull playbook"
```

---

## Task 5 — Update Management-Hub Group Vars

**Files:**
- Modify: `inventory/group_vars/management-hub.yml`

- [ ] **Step 1: Append new vars**

Add to the end of `inventory/group_vars/management-hub.yml`:

```yaml

# iSCSI host prereqs — Trident CSI driver manages login/CHAP; Ansible sets initiator name only
iscsi_state: present
iscsi_mode: csi_node

# Atlas daemon
atlas_state: present
```

- [ ] **Step 2: Verify vars are present**

```bash
grep -E "iscsi_state|iscsi_mode|atlas_state" inventory/group_vars/management-hub.yml
```

Expected:
```
iscsi_state: present
iscsi_mode: csi_node
atlas_state: present
```

- [ ] **Step 3: Push to origin**

```bash
git add inventory/group_vars/management-hub.yml
git commit -m "feat(management-hub): add iscsi prereqs and atlas to group vars"
git push origin main
```

---

## Task 6 — Verify on naraka-01

**Ad-hoc push command** (from olympus-sdk root, after `source ~/projects/personal/.env`):

```bash
cd /path/to/olympus-sdk
source ~/projects/personal/.env
ANSIBLE_CONFIG=infra/management-hub-push.cfg ansible-playbook \
  -i /path/to/olympus-infra/inventory/management-hub.yml \
  -e "ansible_host=100.65.140.75 ansible_connection=ssh ansible_user=ansible ansible_ssh_private_key_file=~/.ssh/ansible" \
  /path/to/olympus-infra/playbooks/pull/management-hub.yml
```

- [ ] **Step 1: Check current initiator name before running**

```bash
ssh -i ~/.ssh/ansible -o StrictHostKeyChecking=no ansible@100.65.140.75 \
  'sudo cat /etc/iscsi/initiatorname.iscsi'
```

Expected: `InitiatorName=iqn.2004-10.com.ubuntu:01:dfbae5d5031` (still Ubuntu default)

- [ ] **Step 2: Run the playbook**

Run the ad-hoc push command above. Watch for:
- `iscsi : Set deterministic iSCSI initiator name` → changed (updates Ubuntu default IQN)
- `atlas : Install atlas binary` → changed (first install)
- `atlas : Register atlas with Hermes` → changed (first registration)
- `atlas : Enable and start atlas service` → ok or changed
- Overall: 0 failed, 0 unreachable

- [ ] **Step 3: Verify initiator name updated**

```bash
ssh -i ~/.ssh/ansible -o StrictHostKeyChecking=no ansible@100.65.140.75 \
  'sudo cat /etc/iscsi/initiatorname.iscsi'
```

Expected: `InitiatorName=iqn.2004-04.net.olympus:naraka-01`

- [ ] **Step 4: Verify atlas is registered and running**

```bash
ssh -i ~/.ssh/ansible -o StrictHostKeyChecking=no ansible@100.65.140.75 \
  'sudo -u atlas HOME=/var/lib/atlas atlas status && systemctl is-active atlas'
```

Expected:
```
Status: REGISTERED
  server:     https://api.nwlnexus.net
  machine_id: <uuid>
  ...
active
```

- [ ] **Step 5: Trigger ansible-pull on naraka-01 and monitor**

```bash
ssh -i ~/.ssh/ansible ansible@100.65.140.75 \
  'sudo -u ansible /usr/bin/ansible-pull \
    -U https://github.com/nwlnexus/olympus-infra.git \
    -i inventory/management-hub.yml \
    playbooks/pull/management-hub.yml 2>&1'
```

Expected: 0 failed, 0 unreachable. Changes should be minimal (only acl install on atlas first pull run, CHAP tasks if iscsi has CHAP configured).

- [ ] **Step 6: Idempotency check — second pull run**

Re-trigger ansible-pull. Expected: 0 failed, 0 unreachable, minimal changes (only the inherently non-idempotent items).
