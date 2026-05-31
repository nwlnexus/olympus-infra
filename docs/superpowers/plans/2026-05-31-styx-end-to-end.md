# Styx End-to-End Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring the styx push and pull playbooks to a fully functional, self-healing state by adding an Atlas role, iSCSI host-mount, a second Plex transcoding directory, and a generic NFS-mounts role.

**Architecture:** Four independent role changes all land in the styx pull playbook (`playbooks/pull/styx.yml`). Credentials are fetched at runtime from 1Password via `op read` (pattern established by `nas-media-mount`). The Atlas role is the most complex — it creates a system user, runs `atlas setup` as that user to autonomously register with Hermes, then Ansible places the exact systemd units that `atlas service install` would generate.

**Tech Stack:** Ansible 2.15+, systemd, open-iscsi, NFS (nfsvers=4), 1Password CLI (`op`), Atlas Rust daemon.

**Env prerequisite:** `source ~/projects/personal/.env` before any push commands from olympus-sdk.

**Testing pattern for each task:**
1. `--check --diff` from control machine to preview changes
2. Apply (push to git + trigger pull, or ad-hoc push)
3. Verify expected state on styx
4. Re-run `--check` — expect zero changes (idempotency)

**Ad-hoc push command** (for testing pull playbook changes without waiting for cron):
```bash
# From olympus-sdk root, after source ~/projects/personal/.env
ANSIBLE_CONFIG=infra/styx-push.cfg \
  ansible-playbook -i infra/inventories/styx.yml \
  ../olympus-infra/playbooks/pull/styx.yml \
  --check --diff --tags=<tag>
# Drop --check to apply
```

---

## File Map

### New files
| File | Purpose |
|------|---------|
| `roles/atlas/defaults/main.yml` | Atlas role variable defaults |
| `roles/atlas/tasks/main.yml` | Atlas install, register, service tasks |
| `roles/atlas/files/atlas.service` | Exact systemd unit (matches service.rs output) |
| `roles/atlas/files/atlas-updater.service` | Exact updater service unit |
| `roles/atlas/files/atlas-updater.timer` | Exact hourly update timer unit |
| `roles/nfs-mounts/defaults/main.yml` | nfs-mounts variable defaults |
| `roles/nfs-mounts/tasks/main.yml` | Entry point — install prereqs, loop over mounts |
| `roles/nfs-mounts/tasks/configure_mount.yml` | Per-mount OP resolve + unit deploy |
| `roles/nfs-mounts/templates/mount.mount.j2` | systemd .mount unit template |
| `roles/nfs-mounts/templates/mount.automount.j2` | systemd .automount unit template |

### Modified files
| File | Change |
|------|--------|
| `roles/plex/defaults/main.yml` | Add `plex_tmp_dir` |
| `roles/plex/tasks/main.yml` | Add create + absent tasks for `plex_tmp_dir` |
| `roles/plex/templates/plexmedia-tmpfiles.conf.j2` | Add second `d` entry for `plex_tmp_dir` |
| `roles/iscsi/defaults/main.yml` | Add `iscsi_state`, `iscsi_op_item`, `iscsi_op_token_file` |
| `roles/iscsi/tasks/main.yml` | Add `iscsi_state == "present"` guard to all three branches |
| `roles/iscsi/tasks/linux_host_mount.yml` | Prepend OP credential fetch + `set_fact` override block |
| `playbooks/pull/styx.yml` | Add `iscsi`, `nfs-mounts`, `atlas`; replace `nas-media-mount` |
| `inventory/host_vars/styx.yml` | Add `iscsi_*` vars, `nfs_mounts` list; remove `hermes_token_op_item` |

### Deferred (coordinate with other agent)
| File | Change |
|------|--------|
| `olympus-sdk/infra/inventories/host_vars/styx/vars.yml` | Remove `hermes_token_op_item` |

---

## Task 1 — Plex: Add `plex_tmp_dir`

**Files:**
- Modify: `roles/plex/defaults/main.yml`
- Modify: `roles/plex/templates/plexmedia-tmpfiles.conf.j2`
- Modify: `roles/plex/tasks/main.yml`

- [ ] **Step 1: Verify current state on styx**

```bash
ssh ansible@100.72.84.56 'stat /tmp/plextmp 2>&1'
# Expected: stat: cannot statx '/tmp/plextmp': No such file or directory
```

- [ ] **Step 2: Add `plex_tmp_dir` default**

`roles/plex/defaults/main.yml` — full file after change:
```yaml
---
plex_state: present
plex_transcoding_dir: /tmp/plexmedia
plex_tmp_dir: /tmp/plextmp
plex_ufw_tailscale_src: "100.64.0.0/10"
```

- [ ] **Step 3: Update tmpfiles.d template**

`roles/plex/templates/plexmedia-tmpfiles.conf.j2` — full file after change:
```
d {{ plex_transcoding_dir }} 0755 plex plex -
d {{ plex_tmp_dir }} 0755 plex plex -
```

- [ ] **Step 4: Add create task for `plex_tmp_dir`**

In `roles/plex/tasks/main.yml`, insert after the existing "Create transcoding directory" task (line 44-52):
```yaml
- name: Create plex tmp directory
  ansible.builtin.file:
    path: "{{ plex_tmp_dir }}"
    state: directory
    owner: plex
    group: plex
    mode: '0755'
  become: true
  when: plex_state == "present"
```

- [ ] **Step 5: Add absent task for `plex_tmp_dir`**

In `roles/plex/tasks/main.yml`, insert after the existing "Remove transcoding directory (state=absent)" task:
```yaml
- name: Remove plex tmp directory (state=absent)
  ansible.builtin.file:
    path: "{{ plex_tmp_dir }}"
    state: absent
  become: true
  when: plex_state == "absent"
```

- [ ] **Step 6: Check run**

```bash
# From olympus-sdk root
source ~/projects/personal/.env
ANSIBLE_CONFIG=infra/styx-push.cfg \
  ansible-playbook -i infra/inventories/styx.yml \
  ../olympus-infra/playbooks/pull/styx.yml \
  --check --diff --tags=plex
```

Expected diff: new directory `/tmp/plextmp` (owner plex, mode 0755), updated tmpfiles.d config.

- [ ] **Step 7: Apply**

```bash
ANSIBLE_CONFIG=infra/styx-push.cfg \
  ansible-playbook -i infra/inventories/styx.yml \
  ../olympus-infra/playbooks/pull/styx.yml \
  --tags=plex
```

- [ ] **Step 8: Verify**

```bash
ssh ansible@100.72.84.56 'stat /tmp/plextmp && ls -la /tmp/plextmp'
# Expected: directory, owned plex:plex, mode 0755

ssh ansible@100.72.84.56 'cat /etc/tmpfiles.d/plexmedia.conf'
# Expected: two d lines, one for /tmp/plexmedia and one for /tmp/plextmp
```

- [ ] **Step 9: Idempotency check**

```bash
ANSIBLE_CONFIG=infra/styx-push.cfg \
  ansible-playbook -i infra/inventories/styx.yml \
  ../olympus-infra/playbooks/pull/styx.yml \
  --check --tags=plex
```

Expected: 0 changes.

- [ ] **Step 10: Commit**

```bash
git add roles/plex/defaults/main.yml \
        roles/plex/tasks/main.yml \
        roles/plex/templates/plexmedia-tmpfiles.conf.j2
git commit -m "feat(plex): add plex_tmp_dir for transcoding scratch space"
```

---

## Task 2 — iSCSI Role: State Gate + 1Password Credential Fetch

**Files:**
- Modify: `roles/iscsi/defaults/main.yml`
- Modify: `roles/iscsi/tasks/main.yml`
- Modify: `roles/iscsi/tasks/linux_host_mount.yml`

- [ ] **Step 1: Add new defaults**

`roles/iscsi/defaults/main.yml` — full file after change:
```yaml
---
iscsi_state: present
iscsi_portal: ""
iscsi_target_iqn: ""
iscsi_chap_user: ""
iscsi_chap_password: ""
iscsi_mode: "host_mount"
iscsi_mount_path: "/mnt/data"
iscsi_filesystem: "ext4"
iscsi_port: 3260
iscsi_nfs_export: ""
iscsi_op_item: ""
iscsi_op_token_file: /etc/olympus/op-service-account-token
```

- [ ] **Step 2: Add `iscsi_state` guard to dispatcher**

`roles/iscsi/tasks/main.yml` — full file after change:
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
```

- [ ] **Step 3: Prepend OP fetch block to `linux_host_mount.yml`**

Insert the following block at the TOP of `roles/iscsi/tasks/linux_host_mount.yml`, before the existing "Set deterministic iSCSI initiator name" task:

```yaml
# roles/iscsi/tasks/linux_host_mount.yml
---
# ── 1Password credential resolution ─────────────────────────────────────────
- name: Read 1Password service account token
  ansible.builtin.slurp:
    src: "{{ iscsi_op_token_file }}"
  register: _iscsi_op_token
  become: true
  when: iscsi_op_item | length > 0

- name: Fetch iSCSI storage address from 1Password
  ansible.builtin.command:
    cmd: op read "op://Dev/{{ iscsi_op_item }}/storageAddress"
  environment:
    OP_SERVICE_ACCOUNT_TOKEN: "{{ _iscsi_op_token.content | b64decode | trim }}"
  register: _iscsi_op_portal
  changed_when: false
  when: iscsi_op_item | length > 0

- name: Fetch iSCSI target IQN from 1Password
  ansible.builtin.command:
    cmd: op read "op://Dev/{{ iscsi_op_item }}/iqn"
  environment:
    OP_SERVICE_ACCOUNT_TOKEN: "{{ _iscsi_op_token.content | b64decode | trim }}"
  register: _iscsi_op_iqn
  changed_when: false
  when: iscsi_op_item | length > 0

- name: Fetch iSCSI CHAP username from 1Password
  ansible.builtin.command:
    cmd: op read "op://Dev/{{ iscsi_op_item }}/chapInitiatorUsername"
  environment:
    OP_SERVICE_ACCOUNT_TOKEN: "{{ _iscsi_op_token.content | b64decode | trim }}"
  register: _iscsi_op_chap_user
  changed_when: false
  when: iscsi_op_item | length > 0

- name: Fetch iSCSI CHAP password from 1Password
  ansible.builtin.command:
    cmd: op read "op://Dev/{{ iscsi_op_item }}/chapInitiatorPassword"
  environment:
    OP_SERVICE_ACCOUNT_TOKEN: "{{ _iscsi_op_token.content | b64decode | trim }}"
  register: _iscsi_op_chap_password
  changed_when: false
  no_log: true
  when: iscsi_op_item | length > 0

- name: Override iSCSI vars from 1Password values
  ansible.builtin.set_fact:
    iscsi_portal: "{{ _iscsi_op_portal.stdout | trim }}"
    iscsi_target_iqn: "{{ _iscsi_op_iqn.stdout | trim }}"
    iscsi_chap_user: "{{ _iscsi_op_chap_user.stdout | trim }}"
    iscsi_chap_password: "{{ _iscsi_op_chap_password.stdout | trim }}"
  no_log: true
  when: iscsi_op_item | length > 0

# ── Existing tasks ────────────────────────────────────────────────────────────
- name: Set deterministic iSCSI initiator name
  # ... (rest of file unchanged)
```

- [ ] **Step 4: Commit role changes (no host_vars yet)**

```bash
git add roles/iscsi/defaults/main.yml \
        roles/iscsi/tasks/main.yml \
        roles/iscsi/tasks/linux_host_mount.yml
git commit -m "feat(iscsi): add state gate and 1Password credential fetch"
```

---

## Task 3 — `nfs-mounts` Role: Create New Role

**Files:**
- Create: `roles/nfs-mounts/defaults/main.yml`
- Create: `roles/nfs-mounts/tasks/main.yml`
- Create: `roles/nfs-mounts/tasks/configure_mount.yml`
- Create: `roles/nfs-mounts/templates/mount.mount.j2`
- Create: `roles/nfs-mounts/templates/mount.automount.j2`

- [ ] **Step 1: Create defaults**

`roles/nfs-mounts/defaults/main.yml`:
```yaml
---
nfs_mounts: []
nfs_mounts_op_token_file: /etc/olympus/op-service-account-token
```

- [ ] **Step 2: Create main task entry point**

`roles/nfs-mounts/tasks/main.yml`:
```yaml
---
- name: Install nfs-common
  ansible.builtin.apt:
    name: nfs-common
    state: present
    update_cache: false
  become: true
  when: ansible_facts['os_family'] == "Debian"

- name: Read 1Password service account token
  ansible.builtin.slurp:
    src: "{{ nfs_mounts_op_token_file }}"
  register: _nfs_op_token
  become: true
  when: nfs_mounts | selectattr('op_host_ref', 'defined') | list | length > 0

- name: Configure NFS mounts
  ansible.builtin.include_tasks: configure_mount.yml
  loop: "{{ nfs_mounts }}"
  loop_control:
    loop_var: _nfs_mount
    label: "{{ _nfs_mount.path }}"
```

- [ ] **Step 3: Create per-mount task file**

`roles/nfs-mounts/tasks/configure_mount.yml`:
```yaml
---
- name: Resolve NFS source host from 1Password
  ansible.builtin.command:
    cmd: op read "{{ _nfs_mount.op_host_ref }}"
  environment:
    OP_SERVICE_ACCOUNT_TOKEN: "{{ _nfs_op_token.content | b64decode | trim }}"
  register: _nfs_op_host
  changed_when: false
  no_log: true
  when: _nfs_mount.op_host_ref is defined

- name: Set resolved NFS source
  ansible.builtin.set_fact:
    _nfs_resolved_src: >-
      {{
        _nfs_mount.src
        if (_nfs_mount.src is defined)
        else ((_nfs_op_host.stdout | trim) ~ (_nfs_mount.export | default('')))
      }}

- name: Derive systemd unit name from path
  ansible.builtin.set_fact:
    _nfs_unit_name: "{{ _nfs_mount.path[1:] | replace('/', '-') }}"

# ── Present state ─────────────────────────────────────────────────────────────
- name: Create NFS mount point
  ansible.builtin.file:
    path: "{{ _nfs_mount.path }}"
    state: directory
    mode: "0755"
  become: true
  when: _nfs_mount.state == "present"

- name: Deploy systemd .mount unit
  ansible.builtin.template:
    src: mount.mount.j2
    dest: "/etc/systemd/system/{{ _nfs_unit_name }}.mount"
    owner: root
    group: root
    mode: "0644"
  become: true
  when: _nfs_mount.state == "present"

- name: Deploy systemd .automount unit
  ansible.builtin.template:
    src: mount.automount.j2
    dest: "/etc/systemd/system/{{ _nfs_unit_name }}.automount"
    owner: root
    group: root
    mode: "0644"
  become: true
  when: _nfs_mount.state == "present"

- name: Enable and start .automount unit
  ansible.builtin.systemd:
    name: "{{ _nfs_unit_name }}.automount"
    enabled: true
    state: started
    daemon_reload: true
  become: true
  when: _nfs_mount.state == "present"

# ── Absent state ──────────────────────────────────────────────────────────────
- name: Stop and disable .automount unit
  ansible.builtin.systemd:
    name: "{{ _nfs_unit_name }}.automount"
    enabled: false
    state: stopped
  become: true
  failed_when: false
  when: _nfs_mount.state == "absent"

- name: Remove .mount and .automount unit files
  ansible.builtin.file:
    path: "/etc/systemd/system/{{ _nfs_unit_name }}.{{ item }}"
    state: absent
  loop:
    - mount
    - automount
  become: true
  when: _nfs_mount.state == "absent"

- name: Reload systemd after removing units
  ansible.builtin.systemd:
    daemon_reload: true
  become: true
  when: _nfs_mount.state == "absent"
```

- [ ] **Step 4: Create .mount template**

`roles/nfs-mounts/templates/mount.mount.j2`:
```ini
[Unit]
Description=NFS mount {{ _nfs_mount.path }}
After=network-online.target
Wants=network-online.target

[Mount]
What={{ _nfs_resolved_src }}
Where={{ _nfs_mount.path }}
Type=nfs
Options={{ _nfs_mount.opts | default('nfsvers=4,hard,_netdev') }}

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 5: Create .automount template**

`roles/nfs-mounts/templates/mount.automount.j2`:
```ini
[Unit]
Description=Automount {{ _nfs_mount.path }}
After=network-online.target

[Automount]
Where={{ _nfs_mount.path }}
TimeoutIdleSec=0

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 6: Commit role skeleton**

```bash
git add roles/nfs-mounts/
git commit -m "feat(nfs-mounts): add generic per-host NFS mount role"
```

---

## Task 4 — Atlas Role: Create New Role

**Files:**
- Create: `roles/atlas/defaults/main.yml`
- Create: `roles/atlas/tasks/main.yml`
- Create: `roles/atlas/files/atlas.service`
- Create: `roles/atlas/files/atlas-updater.service`
- Create: `roles/atlas/files/atlas-updater.timer`

- [ ] **Step 1: Create defaults**

`roles/atlas/defaults/main.yml`:
```yaml
---
atlas_state: present
atlas_server: https://api.nwlnexus.net
atlas_install_url: https://assets.nwlnexus.net/install/atlas
atlas_op_bootstrap_key_ref: "op://Dev/hermes-secrets/bootstrap-key"
atlas_op_token_file: /etc/olympus/op-service-account-token
atlas_user: atlas
atlas_home: /var/lib/atlas
```

- [ ] **Step 2: Create `atlas.service` static file**

`roles/atlas/files/atlas.service` — content must exactly match `generate_atlas_service_unit("/usr/local/bin/atlas", "atlas")` from service.rs:
```
[Unit]
Description=Atlas homelab management daemon
After=network.target

[Service]
Type=simple
User=atlas
Environment=HOME=/var/lib/atlas
ExecStart=/usr/local/bin/atlas daemon
Restart=always
RestartSec=10
TimeoutStopSec=35
AmbientCapabilities=CAP_DAC_READ_SEARCH

[Install]
WantedBy=multi-user.target
```

(File must end with a single trailing newline. No blank line after `WantedBy=multi-user.target`.)

- [ ] **Step 3: Create `atlas-updater.service` static file**

`roles/atlas/files/atlas-updater.service` — content must exactly match `generate_atlas_updater_service_unit("/usr/local/bin/atlas", "atlas")`:
```
[Unit]
Description=Atlas self-updater
After=network.target

[Service]
Type=oneshot
User=atlas
ExecStart=/usr/local/bin/atlas self update
ExecStartPost=/bin/systemctl restart atlas.service
```

(Single trailing newline. No `[Install]` section — the timer activates it.)

- [ ] **Step 4: Create `atlas-updater.timer` static file**

`roles/atlas/files/atlas-updater.timer` — content must exactly match `generate_atlas_updater_timer_unit()`:
```
[Unit]
Description=Atlas hourly update check

[Timer]
OnBootSec=10min
OnUnitActiveSec=1h

[Install]
WantedBy=timers.target
```

- [ ] **Step 5: Verify unit file contents match service.rs output**

The Rust format strings produce content with `\n` delimiters. Cross-check each file:

For `atlas.service`, the format string (service.rs line 24-26) produces:
`[Unit]\nDescription=Atlas homelab management daemon\nAfter=network.target\n\n[Service]\nType=simple\nUser=atlas\nEnvironment=HOME=/var/lib/atlas\nExecStart=/usr/local/bin/atlas daemon\nRestart=always\nRestartSec=10\nTimeoutStopSec=35\nAmbientCapabilities=CAP_DAC_READ_SEARCH\n\n[Install]\nWantedBy=multi-user.target\n`

```bash
# After the file exists, sanity check line count
wc -l roles/atlas/files/atlas.service
# Expected: 14 (13 content lines + 1 trailing newline = 14 lines with wc -l)
```

- [ ] **Step 6: Create tasks**

`roles/atlas/tasks/main.yml`:
```yaml
---
# ── Install binary ────────────────────────────────────────────────────────────
- name: Check if atlas binary is installed
  ansible.builtin.stat:
    path: /usr/local/bin/atlas
  register: _atlas_binary
  become: true

- name: Install atlas binary
  ansible.builtin.shell:
    cmd: "curl -fsSL {{ atlas_install_url }} | sh"
  become: true
  when:
    - atlas_state == "present"
    - not _atlas_binary.stat.exists
  changed_when: true

# ── System user ───────────────────────────────────────────────────────────────
- name: Create atlas system user
  ansible.builtin.user:
    name: "{{ atlas_user }}"
    system: true
    home: "{{ atlas_home }}"
    shell: /usr/sbin/nologin
    create_home: true
    comment: "Atlas daemon"
  become: true
  when: atlas_state == "present"

- name: Ensure atlas config directory exists
  ansible.builtin.file:
    path: "{{ atlas_home }}/.config/atlas"
    state: directory
    owner: "{{ atlas_user }}"
    group: "{{ atlas_user }}"
    mode: "0750"
  become: true
  when: atlas_state == "present"

- name: Write install-method marker
  ansible.builtin.copy:
    content: "shell\n"
    dest: "{{ atlas_home }}/.config/atlas/install-method"
    owner: "{{ atlas_user }}"
    group: "{{ atlas_user }}"
    mode: "0644"
  become: true
  when: atlas_state == "present"

# ── Registration ──────────────────────────────────────────────────────────────
- name: Check atlas registration status
  ansible.builtin.command:
    cmd: /usr/local/bin/atlas status
  become: true
  become_user: "{{ atlas_user }}"
  environment:
    HOME: "{{ atlas_home }}"
  register: _atlas_status
  failed_when: false
  changed_when: false
  when: atlas_state == "present"

- name: Read 1Password service account token
  ansible.builtin.slurp:
    src: "{{ atlas_op_token_file }}"
  register: _op_token
  become: true
  when:
    - atlas_state == "present"
    - _atlas_status.rc != 0

- name: Fetch atlas bootstrap key from 1Password
  ansible.builtin.command:
    cmd: op read "{{ atlas_op_bootstrap_key_ref }}"
  environment:
    OP_SERVICE_ACCOUNT_TOKEN: "{{ _op_token.content | b64decode | trim }}"
  register: _atlas_bootstrap_key
  changed_when: false
  no_log: true
  when:
    - atlas_state == "present"
    - _atlas_status.rc != 0

- name: Register atlas with Hermes
  ansible.builtin.command:
    cmd: "/usr/local/bin/atlas setup --server {{ atlas_server }} --bootstrap-key {{ _atlas_bootstrap_key.stdout | trim }}"
  become: true
  become_user: "{{ atlas_user }}"
  environment:
    HOME: "{{ atlas_home }}"
  no_log: true
  changed_when: true
  when:
    - atlas_state == "present"
    - _atlas_status.rc != 0

# ── Systemd units ─────────────────────────────────────────────────────────────
- name: Deploy atlas.service unit
  ansible.builtin.copy:
    src: atlas.service
    dest: /etc/systemd/system/atlas.service
    owner: root
    group: root
    mode: "0644"
  become: true
  when: atlas_state == "present"

- name: Deploy atlas-updater.service unit
  ansible.builtin.copy:
    src: atlas-updater.service
    dest: /etc/systemd/system/atlas-updater.service
    owner: root
    group: root
    mode: "0644"
  become: true
  when: atlas_state == "present"

- name: Deploy atlas-updater.timer unit
  ansible.builtin.copy:
    src: atlas-updater.timer
    dest: /etc/systemd/system/atlas-updater.timer
    owner: root
    group: root
    mode: "0644"
  become: true
  when: atlas_state == "present"

- name: Enable and start atlas service
  ansible.builtin.systemd:
    name: atlas
    enabled: true
    state: started
    daemon_reload: true
  become: true
  when: atlas_state == "present"

- name: Enable and start atlas-updater timer
  ansible.builtin.systemd:
    name: atlas-updater.timer
    enabled: true
    state: started
  become: true
  when: atlas_state == "present"

# ── Absent state ──────────────────────────────────────────────────────────────
- name: Stop and disable atlas service (state=absent)
  ansible.builtin.systemd:
    name: atlas
    enabled: false
    state: stopped
  become: true
  failed_when: false
  when: atlas_state == "absent"

- name: Stop and disable atlas-updater timer (state=absent)
  ansible.builtin.systemd:
    name: atlas-updater.timer
    enabled: false
    state: stopped
  become: true
  failed_when: false
  when: atlas_state == "absent"

- name: Remove atlas systemd units (state=absent)
  ansible.builtin.file:
    path: "/etc/systemd/system/{{ item }}"
    state: absent
  loop:
    - atlas.service
    - atlas-updater.service
    - atlas-updater.timer
  become: true
  when: atlas_state == "absent"

- name: Reload systemd after removing units (state=absent)
  ansible.builtin.systemd:
    daemon_reload: true
  become: true
  when: atlas_state == "absent"
```

- [ ] **Step 7: Commit atlas role**

```bash
git add roles/atlas/
git commit -m "feat(atlas): add atlas daemon install, register, and service role"
```

---

## Task 5 — Wire Styx: host_vars + Pull Playbook

**Files:**
- Modify: `inventory/host_vars/styx.yml`
- Modify: `playbooks/pull/styx.yml`

- [ ] **Step 1: Update styx host_vars**

`inventory/host_vars/styx.yml` — full file after change:
```yaml
---
# styx — homelab server host vars (pull-mode)
# Push-mode vars live in olympus-sdk/infra/inventories/host_vars/styx/vars.yml

# Plex Media Server
plex_state: present

# iSCSI — QNAP LUN for styx data storage
iscsi_state: present
iscsi_op_item: styx-qnap-iscsi
iscsi_mount_path: /mnt/styx-data
iscsi_mode: host_mount
iscsi_filesystem: ext4

# NFS mounts — managed by nfs-mounts role
# nas-media-mount role removed; media share declared here
nfs_mounts:
  - path: /mnt/media
    op_host_ref: "op://Dev/nas-media-share/host"
    export: /MEDIA
    opts: "nfsvers=4,hard,_netdev,rsize=1048576,wsize=1048576,timeo=600,retrans=2"
    state: present

# ddclient — tracks styx's LAN IP and publishes media-int.nwlnexus.io for internal Plex access
ddclient_state: present
ddclient_extra_fqdns:
  - media-int.nwlnexus.io

# Atlas daemon
atlas_state: present
```

Note: `hermes_token_op_item` removed (was a testing shim — registration is now autonomous via bootstrap key).

- [ ] **Step 2: Update pull playbook**

`playbooks/pull/styx.yml` — full file after change:
```yaml
---
# Pull-mode playbook for styx.
# Runs daily at 02:00 via crontab as the `ansible` user.

- name: Styx — Drift Correction
  hosts: styx
  gather_facts: true

  pre_tasks:
    - name: Fetch olympus inventory from Hermes
      ansible.builtin.import_tasks: "{{ playbook_dir }}/../../roles/baseline/tasks/olympus-inventory.yml"
      tags: [always, olympus-inventory]

  roles:
    - role: baseline
      tags: [baseline]

    - role: iscsi
      tags: [iscsi]

    - role: nfs-mounts
      tags: [nfs-mounts]

    - role: plex
      tags: [plex]

    - role: atlas
      tags: [atlas]

    - role: ddclient
      tags: [ddclient]

    # ── Hermes ENC (must be LAST — appends roles, never displaces) ───────────
    - role: hermes-classify-include
      tags: [hermes-classify]
```

- [ ] **Step 3: Full check run against styx**

```bash
source ~/projects/personal/.env
ANSIBLE_CONFIG=infra/styx-push.cfg \
  ansible-playbook -i infra/inventories/styx.yml \
  ../olympus-infra/playbooks/pull/styx.yml \
  --check --diff
```

Review diff carefully:
- iscsi: initiator name set, open-iscsi installed, target discovered, /mnt/styx-data created and mounted
- nfs-mounts: mnt-media.mount + mnt-media.automount units deployed, enabled
- plex: /tmp/plextmp created, tmpfiles.d updated
- atlas: binary installed, atlas user created, registration attempted, units deployed, service started

- [ ] **Step 4: Apply**

```bash
ANSIBLE_CONFIG=infra/styx-push.cfg \
  ansible-playbook -i infra/inventories/styx.yml \
  ../olympus-infra/playbooks/pull/styx.yml
```

- [ ] **Step 5: Verify all components**

```bash
# iSCSI
ssh ansible@100.72.84.56 'cat /etc/iscsi/initiatorname.iscsi'
# Expected: InitiatorName=iqn.2004-04.net.olympus:styx

ssh ansible@100.72.84.56 'mountpoint /mnt/styx-data && df -h /mnt/styx-data'
# Expected: /mnt/styx-data is a mountpoint, shows QNAP LUN

# NFS (media)
ssh ansible@100.72.84.56 'systemctl status mnt-media.automount'
# Expected: active (running)

ssh ansible@100.72.84.56 'ls /mnt/media | head -5'
# Expected: directory contents from QNAP /MEDIA share

# Plex
ssh ansible@100.72.84.56 'stat /tmp/plextmp && stat /tmp/plexmedia'
# Expected: both directories, owner plex

ssh ansible@100.72.84.56 'systemctl is-active plexmediaserver'
# Expected: active

# Atlas
ssh ansible@100.72.84.56 'systemctl is-active atlas'
# Expected: active

ssh ansible@100.72.84.56 'sudo -u atlas HOME=/var/lib/atlas atlas status'
# Expected: Status: REGISTERED with server and machine_id printed

ssh ansible@100.72.84.56 'cat /var/lib/atlas/.config/atlas/install-method'
# Expected: shell
```

- [ ] **Step 6: Idempotency check**

```bash
ANSIBLE_CONFIG=infra/styx-push.cfg \
  ansible-playbook -i infra/inventories/styx.yml \
  ../olympus-infra/playbooks/pull/styx.yml \
  --check
```

Expected: 0 changes across all roles.

- [ ] **Step 7: Commit**

```bash
git add inventory/host_vars/styx.yml playbooks/pull/styx.yml
git commit -m "feat(styx): wire atlas, iscsi, nfs-mounts into pull playbook"
```

---

## Task 6 — Push + Pull

- [ ] **Step 1: Push to origin**

```bash
git push origin main
```

- [ ] **Step 2: Trigger ansible-pull on styx to confirm full autonomous cycle**

```bash
ssh ansible@100.72.84.56 \
  'sudo -u ansible /usr/bin/ansible-pull \
    -U https://github.com/nwlnexus/olympus-infra.git \
    -i inventory/styx.yml \
    playbooks/pull/styx.yml 2>&1 | tail -20'
```

Expected: play recap shows 0 failed, 0 unreachable. Changed count depends on whether state drifted since Task 5 apply — should be 0 if nothing changed.

- [ ] **Step 3: Olympus-sdk cleanup (coordinate with other agent)**

When the other agent's work in olympus-sdk is complete, remove `hermes_token_op_item` from:

`olympus-sdk/infra/inventories/host_vars/styx/vars.yml` — remove this line:
```yaml
hermes_token_op_item: "op://Dev/styx-hermes-token/credential"
```

Commit in that repo:
```bash
git add infra/inventories/host_vars/styx/vars.yml
git commit -m "chore(styx): remove hermes_token_op_item testing shim"
```

---

## Task 7 — Reboot Safety Check

- [ ] **Step 1: Reboot styx**

```bash
ssh ansible@100.72.84.56 'sudo reboot'
# Wait ~60 seconds for styx to come back
```

- [ ] **Step 2: Verify all mounts and services survived reboot**

```bash
ssh ansible@100.72.84.56 'mountpoint /mnt/styx-data && echo iSCSI OK'
# Expected: /mnt/styx-data is a mountpoint
# (automount may need a trigger — ls /mnt/styx-data first)

ssh ansible@100.72.84.56 'ls /mnt/media | head -3 && echo NFS OK'
# Expected: directory contents (automount fires on access)

ssh ansible@100.72.84.56 'systemctl is-active plexmediaserver && echo Plex OK'
# Expected: active

ssh ansible@100.72.84.56 'systemctl is-active atlas && echo Atlas OK'
# Expected: active

ssh ansible@100.72.84.56 'sudo -u atlas HOME=/var/lib/atlas atlas status'
# Expected: Status: REGISTERED (daemon reconnected to Hermes after reboot)
```

- [ ] **Step 3: Final idempotency check post-reboot**

```bash
source ~/projects/personal/.env
ANSIBLE_CONFIG=infra/styx-push.cfg \
  ansible-playbook -i infra/inventories/styx.yml \
  ../olympus-infra/playbooks/pull/styx.yml \
  --check
```

Expected: 0 changes.
