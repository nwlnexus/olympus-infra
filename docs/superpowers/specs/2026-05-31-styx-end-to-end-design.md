# Styx End-to-End Push/Pull Design

**Date:** 2026-05-31
**Scope:** Four changes to bring styx push and pull playbooks to a fully functional, self-healing state.

---

## 1. Atlas Role (`roles/atlas/`)

### Goal
Install the Atlas daemon binary, register the machine with Hermes autonomously using the bootstrap key, and run the daemon as a system service. The role is idempotent — safe to run on every pull cycle.

### Defaults

```yaml
atlas_state: present
atlas_server: https://api.nwlnexus.net
atlas_install_url: https://assets.nwlnexus.net/install/atlas
atlas_op_bootstrap_key_ref: "op://Dev/hermes-secrets/bootstrap-key"
atlas_op_token_file: /etc/olympus/op-service-account-token
```

### Task flow

1. **Install binary** — `stat /usr/local/bin/atlas`; if missing, run `curl -fsSL {{ atlas_install_url }} | sh` (no sudo, install script handles arch detection and fallback to `~/.local/bin`).
2. **Create system user** — `ansible.builtin.user`: name=atlas, system=true, home=/var/lib/atlas, shell=/usr/sbin/nologin, create_home=true. Idempotent.
3. **Ensure config directory** — `file`: `/var/lib/atlas/.config/atlas/`, owner=atlas, mode=0750.
4. **Write install-method marker** — `copy`: content=`shell\n` → `/var/lib/atlas/.config/atlas/install-method`, owner=atlas, mode=0644. (Required by atlas self-update.)
5. **Check registration** — `command: atlas status` with `become_user: atlas`, `environment: HOME=/var/lib/atlas`. Register result, `failed_when: false`, `changed_when: false`.
6. **Register if needed** (when `_atlas_status.rc != 0`):
   a. Slurp `/etc/olympus/op-service-account-token`.
   b. `op read {{ atlas_op_bootstrap_key_ref }}` with `OP_SERVICE_ACCOUNT_TOKEN` set, `no_log: true`.
   c. `atlas setup --server {{ atlas_server }} --bootstrap-key <key>` as `become_user: atlas`, `HOME=/var/lib/atlas`. Writes `config.toml` + `machine_token` (mode 0600) into atlas user's config dir.
7. **Deploy systemd units** — Ansible `copy` (static, not jinja2) three files:

   `/etc/systemd/system/atlas.service` — exact content to match `generate_atlas_service_unit("/usr/local/bin/atlas", "atlas")`:
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

   `/etc/systemd/system/atlas-updater.service` — exact content from `generate_atlas_updater_service_unit`:
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

   `/etc/systemd/system/atlas-updater.timer` — exact content from `generate_atlas_updater_timer_unit`:
   ```
   [Unit]
   Description=Atlas hourly update check

   [Timer]
   OnBootSec=10min
   OnUnitActiveSec=1h

   [Install]
   WantedBy=timers.target
   ```

   If a manual `atlas service install` is run later, `write_if_changed` compares content and finds these identical — no-op.

8. **Enable and start services**:
   - `systemd`: daemon_reload=true, name=atlas, enabled=true, state=started.
   - `systemd`: name=atlas-updater.timer, enabled=true, state=started.

### Absent state
Stop + disable `atlas` and `atlas-updater.timer`, remove unit files, daemon-reload. Binary and user are left in place (consistent with how `atlas service uninstall` behaves).

### Pull playbook change
Add `role: atlas` to `playbooks/pull/styx.yml`, before `hermes-classify-include`.

### Cleanup
Remove `hermes_token_op_item` from:
- `inventory/host_vars/styx.yml` (olympus-infra)
- `infra/inventories/host_vars/styx/vars.yml` (olympus-sdk)

This was a testing shim; registration is now fully autonomous via the bootstrap key.

---

## 2. iSCSI Role Update + Styx Config

### Goal
Mount styx's QNAP iSCSI LUN at `/mnt/styx-data` at the host level, reboot-safe, with credentials fetched from 1Password at runtime. No kubernetes involved — `host_mount` mode only.

### iscsi role changes

**New defaults:**
```yaml
iscsi_state: present
iscsi_op_item: ""             # 1Password item name, e.g. "styx-qnap-iscsi"
iscsi_op_token_file: /etc/olympus/op-service-account-token
```

**Gate:** Wrap ALL tasks in `linux_host_mount.yml` (existing and new) under `when: iscsi_state == "present"`. The `main.yml` dispatcher also gains this gate so the role is a no-op when `iscsi_state == "absent"` or unset.

**`linux_host_mount.yml` additions:** When `iscsi_op_item` is set, before running `iscsiadm`:
1. Slurp `{{ iscsi_op_token_file }}`.
2. Use `op read` to resolve four fields from `op://Dev/{{ iscsi_op_item }}/`:
   - `storageAddress` → overrides `iscsi_portal`
   - `iqn` → overrides `iscsi_target_iqn`
   - `chapInitiatorUsername` → overrides `iscsi_chap_user`
   - `chapInitiatorPassword` → overrides `iscsi_chap_password` (`no_log: true`)

The static var defaults remain as fallback when `iscsi_op_item` is empty (existing usage for non-OP hosts).

**Initiator IQN** — already standardized in the role:
```
InitiatorName=iqn.2004-04.net.olympus:{{ inventory_hostname }}
```
For styx: `iqn.2004-04.net.olympus:styx`. No change needed.

**Mount persistence** — the existing role uses `ansible.posix.mount` with `opts: _netdev` and `state: mounted`, which writes an fstab entry. This is already reboot-safe.

### Styx host_vars additions (`inventory/host_vars/styx.yml`)

```yaml
iscsi_state: present
iscsi_op_item: styx-qnap-iscsi
iscsi_mount_path: /mnt/styx-data
iscsi_mode: host_mount
iscsi_filesystem: ext4
```

### Pull playbook change
Add `role: iscsi` to `playbooks/pull/styx.yml`, after `baseline`.

---

## 3. Plex Transcoding Tmp Directory

### Goal
The Plex role currently creates one directory (`/tmp/plexmedia`). A second ephemeral directory (`/tmp/plextmp`) is required for Plex's transcoding tmp scratch space.

### Plex role changes

**New default:**
```yaml
plex_tmp_dir: /tmp/plextmp
```

**`roles/plex/templates/plexmedia-tmpfiles.conf.j2`** — extend to cover both dirs (or add a second tmpfiles file):
```
d {{ plex_transcoding_dir }} 0755 plex plex -
d {{ plex_tmp_dir }} 0755 plex plex -
```

**New task** (after the existing transcoding dir task):
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

**Absent state** — mirror the existing absent block to also remove `plex_tmp_dir`.

No styx host_vars change needed — defaults match the requirement.

---

## 4. Generic `nfs-mounts` Role (replaces `nas-media-mount` for styx)

### Goal
A single role that manages any number of NFS mounts per host, declared in host_vars. Supports both static mount sources and dynamically-resolved sources (host fetched from 1Password at runtime). Uses systemd `.mount` + `.automount` units on Linux for reboot-safe, persistent mounts. The existing `nas-media-mount` role is not deleted but is no longer used by styx.

### Role: `roles/nfs-mounts/`

**Defaults:**
```yaml
nfs_mounts: []
nfs_mounts_op_token_file: /etc/olympus/op-service-account-token
```

**Per-mount entry schema:**
```yaml
nfs_mounts:
  - path: /mnt/media                         # local mount point
    src: "192.168.251.2:/MEDIA"              # option A: static source
    op_host_ref: "op://Dev/nas-media-share/host"  # option B: resolve host from OP
    export: /MEDIA                           # used with op_host_ref to form src
    opts: "nfsvers=4,hard,_netdev,rsize=1048576,wsize=1048576,timeo=600,retrans=2"
    state: present                           # present | absent
```

Either `src` or (`op_host_ref` + `export`) must be provided. `src` takes precedence if both are set.

**Task flow:**

1. **Resolve OP sources** — for any mount with `op_host_ref` set, slurp the OP token once (cached across mounts), then `op read {{ item.op_host_ref }}` to get the NAS host. Construct `src: "{{ resolved_host }}{{ item.export }}"`.
2. **Install `nfs-common`** — `apt: name=nfs-common, state=present` (once, not per-mount).
3. **For each `present` mount:**
   - Create mount point directory.
   - Derive systemd unit name from path using systemd-escape convention: `/mnt/media` → `mnt-media`.
   - Deploy `/etc/systemd/system/<unit>.mount` from template.
   - Deploy `/etc/systemd/system/<unit>.automount` from template.
   - `systemd`: daemon_reload=true, enable + start the `.automount` unit.
4. **For each `absent` mount:**
   - Stop + disable the `.automount` unit.
   - Remove `.mount` and `.automount` unit files.
   - `systemd`: daemon_reload.
   - Optionally remove mount point if empty.

**Systemd unit templates:**

`<unit>.mount`:
```ini
[Unit]
Description=NFS mount {{ item.path }}
After=network-online.target
Wants=network-online.target

[Mount]
What={{ _resolved_src }}
Where={{ item.path }}
Type=nfs
Options={{ item.opts | default('nfsvers=4,hard,_netdev') }}

[Install]
WantedBy=multi-user.target
```

`<unit>.automount`:
```ini
[Unit]
Description=Automount {{ item.path }}
After=network-online.target

[Automount]
Where={{ item.path }}
TimeoutIdleSec=0

[Install]
WantedBy=multi-user.target
```

### Styx host_vars (`inventory/host_vars/styx.yml`)

```yaml
nfs_mounts:
  - path: /mnt/media
    op_host_ref: "op://Dev/nas-media-share/host"
    export: /MEDIA
    opts: "nfsvers=4,hard,_netdev,rsize=1048576,wsize=1048576,timeo=600,retrans=2"
    state: present
```

Additional temporary mounts can be added here as needed per-host; the role picks them all up.

### Pull playbook change
In `playbooks/pull/styx.yml`:
- Remove `role: nas-media-mount`
- Add `role: nfs-mounts`

`nas-media-mount` role code is retained in the repo — other hosts that reference it continue to work.

---

## Summary of File Changes

### olympus-infra (this repo)

| Action | File |
|--------|------|
| New role | `roles/atlas/` (tasks, defaults, files for 3 systemd units) |
| Modified role | `roles/iscsi/` (add iscsi_state gate, iscsi_op_item support in linux_host_mount.yml) |
| Modified role | `roles/plex/` (add plex_tmp_dir default, task, tmpfiles entry) |
| New role | `roles/nfs-mounts/` (tasks, defaults, two unit templates) |
| Modified | `playbooks/pull/styx.yml` (add atlas, iscsi; replace nas-media-mount with nfs-mounts) |
| Modified | `inventory/host_vars/styx.yml` (add iscsi vars, nfs_mounts list; remove hermes_token_op_item) |

### olympus-sdk (external repo — another agent may be active)

| Action | File |
|--------|------|
| Modified | `infra/inventories/host_vars/styx/vars.yml` (remove hermes_token_op_item) |

---

## Constraints

- All roles must be idempotent — second run produces no changes on a healthy host.
- Pull playbook must complete in < 30s — atlas registration only runs once (skipped when already registered); OP reads are fast.
- Never commit secrets — all credentials fetched at runtime via `op read`.
- `inject_facts_as_vars = False` in ansible.cfg — always use `ansible_facts['key']` form in any new tasks.
- The olympus-sdk repo has another agent actively working — changes there should be minimal and surgical (only the `hermes_token_op_item` removal).
