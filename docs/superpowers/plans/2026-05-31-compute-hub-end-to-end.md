# Compute-Hub End-to-End Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring all 3 compute-hub nodes (onode-030c31, onode-0312ce, onode-0314ac) into a self-healing state with correct iSCSI initiator names and Atlas daemon, and fix the fleet-wide ansible-pull infrastructure that has been broken since April.

**Architecture:** All nodes use `playbooks/pull/olympus.yml` (the unified playbook) with opt-in role guards — no per-host playbook created. The `iscsi` and `atlas` roles are added to `olympus.yml` so any host with `iscsi_state`/`atlas_state` defined picks them up automatically. The broken ansible-pull systemd service is fixed in the role templates (`ProtectHome=false`, `export HOME=`, consistent OP token path) and will heal fleet-wide on next baseline run.

**Tech Stack:** Ansible 2.15+, systemd, open-iscsi, multipath-tools, Atlas Rust daemon, 1Password CLI.

**Env prerequisite:** `source ~/projects/personal/.env` before any push/ad-hoc run from olympus-sdk.

**Node IPs for ad-hoc testing:**
- onode-030c31: LAN `192.168.253.7`
- onode-0312ce: LAN `192.168.253.8`
- onode-0314ac: Tailscale only `100.81.35.111` (LAN .9 not routable from laptop)

**Baseline SHA:** `5a176e3b09384a8597151f7eae75ca465c98fc1f`

---

## File Map

| Action | File |
|--------|------|
| Modify | `playbooks/pull/olympus.yml` — add iscsi and atlas opt-in roles |
| Modify | `roles/ansible-pull/templates/ansible-pull.service.j2` — ProtectHome=false |
| Modify | `roles/ansible-pull/templates/ansible-pull-run.j2` — add HOME export, fix OP token path on Linux |
| Modify | `inventory/group_vars/compute_hub.yml` — add iscsi_state, iscsi_mode, atlas_state |
| Modify | `inventory/host_vars/onode-0314ac.yml` — fix LAN IP comment |

---

## Task 1 — Add `iscsi` and `atlas` to `olympus.yml`

**Files:**
- Modify: `playbooks/pull/olympus.yml` (after line 48, before the `ansible-pull` role at line 51)

- [ ] **Step 1: Read current roles block**

```bash
grep -n "role:" playbooks/pull/olympus.yml
```

Expected: baseline at line ~48, ansible-pull at line ~51, then the opt-in roles.

- [ ] **Step 2: Insert iscsi and atlas after baseline, before ansible-pull**

In `playbooks/pull/olympus.yml`, insert after the baseline role block and before the ansible-pull role block:

```yaml
    - role: iscsi
      tags: [iscsi]
      when: iscsi_state is defined

    - role: atlas
      tags: [atlas]
      when: atlas_state is defined
```

Full roles section after change:
```yaml
  roles:
    # ── Always run — roles handle OS/arch internally ──────────────────────────
    - role: common
      tags: [common]
      when: ansible_facts['os_family'] != 'Darwin'

    - role: baseline
      tags: [baseline]

    - role: iscsi
      tags: [iscsi]
      when: iscsi_state is defined

    - role: atlas
      tags: [atlas]
      when: atlas_state is defined

    - role: ansible-pull
      tags: [ansible-pull]

    # ── Opt-in via _state vars set in host/group vars ─────────────────────────
    - role: tailscale
      tags: [tailscale]
      when: tailscale_state is defined

    - role: colima
      tags: [colima]
      when: colima_state is defined

    - role: cloudflared
      tags: [cloudflared]
      when: cloudflared_state is defined

    - role: cloudflared-k8s
      tags: [cloudflared-k8s]
      when: >
        cloudflared_k8s_state is defined and
        k3s_primary | default(false)

    - role: ollama
      tags: [ollama]
      when: ollama_state is defined

    # ── Always last — Hermes-injected dynamic roles ───────────────────────────
    - role: hermes-classify-include
      tags: [hermes-classify]
```

- [ ] **Step 3: Verify iscsi and atlas appear in correct position**

```bash
grep -n "role:" playbooks/pull/olympus.yml
```

Expected: iscsi and atlas appear after baseline (line ~48) and before ansible-pull (line ~55).

- [ ] **Step 4: Commit**

```bash
git add playbooks/pull/olympus.yml
git commit -m "feat(olympus): add iscsi and atlas opt-in roles to unified pull playbook

Both roles fire when their controlling _state var is defined in host/group
vars. No per-host playbook needed — all fleet nodes use olympus.yml."
```

---

## Task 2 — Fix ansible-pull Templates

**Files:**
- Modify: `roles/ansible-pull/templates/ansible-pull.service.j2` line 22
- Modify: `roles/ansible-pull/templates/ansible-pull-run.j2` lines 29-33

### 2a — Fix `ansible-pull.service.j2`

- [ ] **Step 1: Read current service template**

```bash
grep -n "ProtectHome" roles/ansible-pull/templates/ansible-pull.service.j2
```

Expected: `ProtectHome=true` at line 22.

- [ ] **Step 2: Change ProtectHome to false**

In `roles/ansible-pull/templates/ansible-pull.service.j2`, change line 22:

```
ProtectHome=false
```

Also add `Environment=HOME=/home/ansible` before the `ReadWritePaths` line so the systemd service always has HOME set:

Full `[Service]` section after change:
```ini
[Service]
Type=oneshot
User=ansible
Group=ansible
WorkingDirectory=/opt/ansible-pull
ExecStart=/opt/ansible-pull/ansible-pull-run
StandardOutput=journal
StandardError=journal
SyslogIdentifier=ansible-pull

# ansible-pull needs full system access to manage the host
NoNewPrivileges=false
PrivateTmp=true
ProtectSystem=false
ProtectHome=false
Environment=HOME=/home/ansible
ReadWritePaths=/opt/ansible-pull {{ ansible_pull_log_dir }}
```

### 2b — Fix `ansible-pull-run.j2`

- [ ] **Step 3: Read the current Linux section**

```bash
sed -n '28,35p' roles/ansible-pull/templates/ansible-pull-run.j2
```

Expected current content (lines 28-34):
```bash
{% else %}
# ── Linux: ensure user-local bin is on PATH ───────────────────────────────────
export PATH="${HOME}/.local/bin:${PATH}"
ANSIBLE_PULL_BIN="{{ ansible_pull_bin_linux }}"
OP_TOKEN_FILE="${WRAPPER_OP_TOKEN_FILE:-/opt/ansible-pull/.op-service-account-token}"
{% endif %}
```

- [ ] **Step 4: Fix Linux section — add HOME export and correct OP token path**

In `roles/ansible-pull/templates/ansible-pull-run.j2`, replace the Linux `{% else %}` block (lines 28-33):

```bash
{% else %}
# ── Linux: ensure user-local bin is on PATH ───────────────────────────────────
export HOME="/home/{{ ansible_pull_user }}"
export PATH="${HOME}/.local/bin:${PATH}"
ANSIBLE_PULL_BIN="{{ ansible_pull_bin_linux }}"
OP_TOKEN_FILE="${WRAPPER_OP_TOKEN_FILE:-/etc/olympus/op-service-account-token}"
{% endif %}
```

Changes: added `export HOME=` line; changed OP token path from `/opt/ansible-pull/.op-service-account-token` to `/etc/olympus/op-service-account-token`.

- [ ] **Step 5: Verify changes**

```bash
grep -n "ProtectHome\|HOME\|OP_TOKEN_FILE" \
  roles/ansible-pull/templates/ansible-pull.service.j2 \
  roles/ansible-pull/templates/ansible-pull-run.j2
```

Expected:
```
ansible-pull.service.j2:22:ProtectHome=false
ansible-pull.service.j2:23:Environment=HOME=/home/ansible
ansible-pull-run.j2:30:export HOME="/home/{{ ansible_pull_user }}"
ansible-pull-run.j2:32:OP_TOKEN_FILE="${WRAPPER_OP_TOKEN_FILE:-/etc/olympus/op-service-account-token}"
```

- [ ] **Step 6: Commit**

```bash
git add roles/ansible-pull/templates/ansible-pull.service.j2 \
        roles/ansible-pull/templates/ansible-pull-run.j2
git commit -m "fix(ansible-pull): fix HOME + ProtectHome in systemd service, standardise OP token path

- ProtectHome=true prevented Ansible writing to ~/.ansible/tmp in systemd context
- Environment=HOME= ensures HOME is always set (not guaranteed by systemd for system services)
- export HOME= in run script mirrors macOS pattern and fixes PATH expansion
- OP token path unified to /etc/olympus/op-service-account-token across all platforms"
```

---

## Task 3 — Update `compute_hub` Group Vars

**Files:**
- Modify: `inventory/group_vars/compute_hub.yml`

- [ ] **Step 1: Read current end of file**

```bash
tail -5 inventory/group_vars/compute_hub.yml
```

Expected: ends with `ansible_pull_limit: "$(hostname -s)"` at line 79.

- [ ] **Step 2: Append iSCSI and atlas vars**

Append to `inventory/group_vars/compute_hub.yml`:

```yaml

# iSCSI host prereqs — QNAP Trident CSI manages login/CHAP; Ansible sets initiator name only
iscsi_state: present
iscsi_mode: csi_node

# Atlas daemon
atlas_state: present
```

- [ ] **Step 3: Verify vars present**

```bash
grep -E "iscsi_state|iscsi_mode|atlas_state" inventory/group_vars/compute_hub.yml
```

Expected:
```
iscsi_state: present
iscsi_mode: csi_node
atlas_state: present
```

- [ ] **Step 4: Commit**

```bash
git add inventory/group_vars/compute_hub.yml
git commit -m "feat(compute-hub): add iSCSI csi_node prereqs and atlas to group vars"
```

---

## Task 4 — Fix `onode-0314ac` Host Vars Comment

**Files:**
- Modify: `inventory/host_vars/onode-0314ac.yml` line 3

- [ ] **Step 1: Fix LAN IP comment**

In `inventory/host_vars/onode-0314ac.yml`, change line 3 from:
```yaml
# LAN IP: 192.168.253.20
```
to:
```yaml
# LAN IP: 192.168.253.9
```

(Confirmed via Tailscale SSH: `ip -4 addr show enp2s0` returned `192.168.253.9/27`)

- [ ] **Step 2: Commit and push**

```bash
git add inventory/host_vars/onode-0314ac.yml
git commit -m "fix(compute-hub): correct onode-0314ac LAN IP comment (.20 → .9)"
git push origin main
```

---

## Task 5 — Prepare Compute Nodes and Verify

The `olympus.yml` pre_tasks check for `/etc/olympus/hermes-token` or `/etc/olympus/hermes-disabled`. Compute nodes have neither yet (atlas registration happened but hermes-token placement at `/etc/olympus/` is separate infrastructure). Create a `hermes-disabled` flag on each node so the pre_task passes and the playbook can run.

**Ad-hoc run command pattern** (run from olympus-sdk root after `source ~/projects/personal/.env`):

No `compute-hub-push.cfg` exists — use `management-hub-push.cfg` (same `roles_path = ../../olympus-infra/roles`; the `-i` flag overrides the inventory setting):

```bash
ANSIBLE_CONFIG=infra/management-hub-push.cfg ansible-playbook \
  -i /Users/nwilliams-lucas/projects/personal/olympus-infra/inventory/compute-hub.yml \
  -e "ansible_host=<IP> ansible_connection=ssh ansible_user=ansible ansible_ssh_private_key_file=~/.ssh/ansible" \
  /Users/nwilliams-lucas/projects/personal/olympus-infra/playbooks/pull/olympus.yml \
  --limit <node_name>
```

### Per-node steps

#### onode-030c31 (192.168.253.7)

- [ ] **Step 1: Create hermes-disabled flag**

```bash
ssh -i ~/.ssh/ansible -o IdentityAgent=none ansible@192.168.253.7 \
  'sudo touch /etc/olympus/hermes-disabled && echo done'
```

- [ ] **Step 2: Verify pre-run state**

```bash
ssh -i ~/.ssh/ansible -o IdentityAgent=none ansible@192.168.253.7 \
  'sudo cat /etc/iscsi/initiatorname.iscsi; which atlas 2>/dev/null || echo "atlas: not found"'
```

Expected: Ubuntu default IQN, atlas not found.

- [ ] **Step 3: Run playbook against onode-030c31**

```bash
cd /Users/nwilliams-lucas/projects/personal/olympus-sdk && source ~/projects/personal/.env
ANSIBLE_CONFIG=infra/management-hub-push.cfg ansible-playbook \
  -i /Users/nwilliams-lucas/projects/personal/olympus-infra/inventory/compute-hub.yml \
  -e "ansible_host=192.168.253.7 ansible_connection=ssh ansible_user=ansible ansible_ssh_private_key_file=~/.ssh/ansible" \
  /Users/nwilliams-lucas/projects/personal/olympus-infra/playbooks/pull/olympus.yml \
  --limit onode-030c31
```

Watch for: `iscsi : Set deterministic iSCSI initiator name` → changed, `atlas : Register atlas with Hermes` → changed, `ansible-pull : ...service` → changed (deploys new service template with ProtectHome=false).

- [ ] **Step 4: Verify onode-030c31**

```bash
ssh -i ~/.ssh/ansible -o IdentityAgent=none ansible@192.168.253.7 \
  'sudo cat /etc/iscsi/initiatorname.iscsi && \
   sudo -u atlas HOME=/var/lib/atlas atlas status && \
   systemctl is-active atlas && \
   grep ProtectHome /etc/systemd/system/ansible-pull.service'
```

Expected:
```
InitiatorName=iqn.2004-04.net.olympus:onode-030c31
Status: REGISTERED
  server: https://api.nwlnexus.net
  machine_id: <uuid>
active
ProtectHome=false
```

#### onode-0312ce (192.168.253.8)

- [ ] **Step 5: Create hermes-disabled flag and run**

```bash
ssh -i ~/.ssh/ansible -o IdentityAgent=none ansible@192.168.253.8 \
  'sudo touch /etc/olympus/hermes-disabled'

ANSIBLE_CONFIG=infra/management-hub-push.cfg ansible-playbook \
  -i /Users/nwilliams-lucas/projects/personal/olympus-infra/inventory/compute-hub.yml \
  -e "ansible_host=192.168.253.8 ansible_connection=ssh ansible_user=ansible ansible_ssh_private_key_file=~/.ssh/ansible" \
  /Users/nwilliams-lucas/projects/personal/olympus-infra/playbooks/pull/olympus.yml \
  --limit onode-0312ce
```

- [ ] **Step 6: Verify onode-0312ce**

```bash
ssh -i ~/.ssh/ansible -o IdentityAgent=none ansible@192.168.253.8 \
  'sudo cat /etc/iscsi/initiatorname.iscsi && \
   sudo -u atlas HOME=/var/lib/atlas atlas status && \
   systemctl is-active atlas'
```

Expected: `iqn.2004-04.net.olympus:onode-0312ce`, registered, active.

#### onode-0314ac (Tailscale: 100.81.35.111)

- [ ] **Step 7: Create hermes-disabled flag and run**

```bash
ssh -i ~/.ssh/ansible -o IdentityAgent=none ansible@100.81.35.111 \
  'sudo touch /etc/olympus/hermes-disabled'

ANSIBLE_CONFIG=infra/management-hub-push.cfg ansible-playbook \
  -i /Users/nwilliams-lucas/projects/personal/olympus-infra/inventory/compute-hub.yml \
  -e "ansible_host=100.81.35.111 ansible_connection=ssh ansible_user=ansible ansible_ssh_private_key_file=~/.ssh/ansible" \
  /Users/nwilliams-lucas/projects/personal/olympus-infra/playbooks/pull/olympus.yml \
  --limit onode-0314ac
```

- [ ] **Step 8: Verify onode-0314ac**

```bash
ssh -i ~/.ssh/ansible -o IdentityAgent=none ansible@100.81.35.111 \
  'sudo cat /etc/iscsi/initiatorname.iscsi && \
   sudo -u atlas HOME=/var/lib/atlas atlas status && \
   systemctl is-active atlas'
```

Expected: `iqn.2004-04.net.olympus:onode-0314ac`, registered, active.

### Trigger systemd timer on each node

- [ ] **Step 9: Trigger ansible-pull timer on all 3 nodes**

Each node's systemd timer now runs the corrected service (ProtectHome=false, HOME set). Trigger manually to confirm end-to-end:

```bash
for ip in 192.168.253.7 192.168.253.8 100.81.35.111; do
  echo "=== Triggering $ip ==="
  ssh -i ~/.ssh/ansible -o IdentityAgent=none ansible@$ip \
    'sudo systemctl start ansible-pull.service && \
     sudo journalctl -u ansible-pull.service -n 5 --no-pager'
  echo
done
```

Expected: each shows "Starting Ansible Pull at ..." and exits 0 (no makedirs PermissionError).

- [ ] **Step 10: Idempotency check on one node**

Re-run against onode-030c31 with `--check`:

```bash
ANSIBLE_CONFIG=infra/management-hub-push.cfg ansible-playbook \
  -i /Users/nwilliams-lucas/projects/personal/olympus-infra/inventory/compute-hub.yml \
  -e "ansible_host=192.168.253.7 ansible_connection=ssh ansible_user=ansible ansible_ssh_private_key_file=~/.ssh/ansible" \
  /Users/nwilliams-lucas/projects/personal/olympus-infra/playbooks/pull/olympus.yml \
  --limit onode-030c31 --check
```

Expected: 0 failed, 0 unreachable. Changes limited to inherently non-idempotent items only.
