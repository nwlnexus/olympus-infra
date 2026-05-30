# Plex / NAS Mount / Ingress Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run Plex Media Server on styx with the QNAP MEDIA NFS share mounted, exposed externally at `media.nwlnexus.io` via Traefik on management-hub, with split-horizon DNS keeping local clients on-LAN.

**Architecture:** Three new Ansible roles (`nas-media-mount`, `plex`, `unifi-dns`) land in olympus-infra; `ddclient` gets a small extension for cross-zone public records; Traefik IngressRoute manifests land in olympus-gitops. styx runs Plex + NFS mount; management-hub runs Unifi DNS policy upsert and ddclient to keep `media.nwlnexus.io` current. Traefik on management-hub routes to styx via Tailscale direct-connect (physically on-LAN).

**Tech Stack:** Ansible, systemd (mount + automount), plexmediaserver apt package, community.general.ufw, ansible.builtin.uri (Cloudflare API + Unifi API), Traefik IngressRoute CRD, cert-manager, Flux CD / Kustomize.

---

## File Map

### olympus-infra (this repo)

**New files:**
- `roles/nas-media-mount/defaults/main.yml`
- `roles/nas-media-mount/tasks/main.yml`
- `roles/nas-media-mount/handlers/main.yml`
- `roles/nas-media-mount/templates/mnt-media.mount.j2`
- `roles/nas-media-mount/templates/mnt-media.automount.j2`
- `roles/plex/defaults/main.yml`
- `roles/plex/tasks/main.yml`
- `roles/plex/templates/plexmedia-tmpfiles.conf.j2`
- `roles/unifi-dns/defaults/main.yml`
- `roles/unifi-dns/tasks/main.yml`
- `roles/unifi-dns/tasks/upsert_policy.yml`

**Modified files:**
- `roles/ddclient/defaults/main.yml` — add `ddclient_extra_public_records`
- `roles/ddclient/tasks/main.yml` — add seeding tasks for extra public records
- `roles/ddclient/templates/ddclient.conf.j2` — add extra zone block
- `playbooks/pull/styx.yml` — add nas-media-mount + plex roles
- `playbooks/pull/management-hub.yml` — add unifi-dns role + ddclient role
- `inventory/host_vars/styx.yml` — plex + mount vars
- `inventory/group_vars/management-hub.yml` — unifi-dns + ddclient vars

### olympus-gitops (separate repo — `nwlnexus/olympus-gitops`)

**New files** (check existing `apps/` structure for exact parent Kustomization path):
- `apps/media/namespace.yaml`
- `apps/media/plex-external-service.yaml`
- `apps/media/plex-certificate.yaml`
- `apps/media/plex-ingressroute.yaml`
- `apps/media/kustomization.yaml`

---

## Task 1: `nas-media-mount` role

**Files:**
- Create: `roles/nas-media-mount/defaults/main.yml`
- Create: `roles/nas-media-mount/tasks/main.yml`
- Create: `roles/nas-media-mount/handlers/main.yml`
- Create: `roles/nas-media-mount/templates/mnt-media.mount.j2`
- Create: `roles/nas-media-mount/templates/mnt-media.automount.j2`

- [ ] **Step 1: Create defaults**

```yaml
# roles/nas-media-mount/defaults/main.yml
---
nas_media_mount_state: present
nas_media_mount_point: /mnt/media
nas_media_mount_share: /MEDIA
nas_media_op_token_file: /etc/olympus/op-service-account-token
nas_media_op_nas_host_ref: "op://Dev/nas-media-share/host"
```

- [ ] **Step 2: Create the mount unit template**

```ini
# roles/nas-media-mount/templates/mnt-media.mount.j2
# Managed by Ansible (nas-media-mount role) — do not edit manually
[Unit]
Description=QNAP NAS MEDIA share
After=network-online.target
Wants=network-online.target

[Mount]
What={{ _nas_media_host }}:/MEDIA
Where={{ nas_media_mount_point }}
Type=nfs
Options=nfsvers=4,hard,_netdev,rsize=1048576,wsize=1048576,timeo=600,retrans=2

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 3: Create the automount unit template**

```ini
# roles/nas-media-mount/templates/mnt-media.automount.j2
# Managed by Ansible (nas-media-mount role) — do not edit manually
[Unit]
Description=Automount QNAP NAS MEDIA share
After=network-online.target

[Automount]
Where={{ nas_media_mount_point }}
TimeoutIdleSec=0

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 4: Create tasks**

The unit filename must match the mount point path with slashes replaced by dashes. For `/mnt/media` → `mnt-media`.

```yaml
# roles/nas-media-mount/tasks/main.yml
---
- name: Install nfs-common
  ansible.builtin.apt:
    name: nfs-common
    state: present
    update_cache: false
  become: true
  when: nas_media_mount_state == "present"

- name: Read OP service account token
  ansible.builtin.slurp:
    src: "{{ nas_media_op_token_file }}"
  register: _nas_op_sat
  no_log: true
  failed_when: false
  when: nas_media_mount_state == "present"

- name: Fetch NAS host from 1Password
  ansible.builtin.command:
    argv:
      - op
      - read
      - "{{ nas_media_op_nas_host_ref }}"
  environment:
    OP_SERVICE_ACCOUNT_TOKEN: "{{ _nas_op_sat.content | b64decode | trim }}"
  register: _nas_host_result
  changed_when: false
  no_log: true
  when:
    - nas_media_mount_state == "present"
    - _nas_op_sat.content is defined

- name: Set NAS host fact
  ansible.builtin.set_fact:
    _nas_media_host: "{{ _nas_host_result.stdout | trim }}"
  when:
    - nas_media_mount_state == "present"
    - _nas_host_result.stdout is defined

- name: Create mount point directory
  ansible.builtin.file:
    path: "{{ nas_media_mount_point }}"
    state: directory
    owner: root
    group: root
    mode: '0755'
  become: true
  when:
    - nas_media_mount_state == "present"
    - _nas_media_host is defined

- name: Deploy systemd mount unit
  ansible.builtin.template:
    src: mnt-media.mount.j2
    dest: /etc/systemd/system/mnt-media.mount
    owner: root
    group: root
    mode: '0644'
  become: true
  notify: reload systemd and restart automount
  when:
    - nas_media_mount_state == "present"
    - _nas_media_host is defined

- name: Deploy systemd automount unit
  ansible.builtin.template:
    src: mnt-media.automount.j2
    dest: /etc/systemd/system/mnt-media.automount
    owner: root
    group: root
    mode: '0644'
  become: true
  notify: reload systemd and restart automount
  when:
    - nas_media_mount_state == "present"
    - _nas_media_host is defined

- name: Enable and start automount unit
  ansible.builtin.systemd:
    name: mnt-media.automount
    enabled: true
    state: started
    daemon_reload: true
  become: true
  when:
    - nas_media_mount_state == "present"
    - _nas_media_host is defined

- name: Remove mount and automount units (state=absent)
  ansible.builtin.systemd:
    name: "{{ item }}"
    enabled: false
    state: stopped
  loop:
    - mnt-media.automount
    - mnt-media.mount
  become: true
  failed_when: false
  when: nas_media_mount_state == "absent"

- name: Remove unit files (state=absent)
  ansible.builtin.file:
    path: "{{ item }}"
    state: absent
  loop:
    - /etc/systemd/system/mnt-media.mount
    - /etc/systemd/system/mnt-media.automount
  become: true
  when: nas_media_mount_state == "absent"
```

- [ ] **Step 5: Create handler**

```yaml
# roles/nas-media-mount/handlers/main.yml
---
- name: reload systemd and restart automount
  ansible.builtin.systemd:
    name: mnt-media.automount
    state: restarted
    daemon_reload: true
  become: true
```

- [ ] **Step 6: Commit**

```bash
git add roles/nas-media-mount/
git commit -m "feat(nas-media-mount): new role — systemd NFS automount for QNAP MEDIA share"
```

---

## Task 2: `plex` role

**Files:**
- Create: `roles/plex/defaults/main.yml`
- Create: `roles/plex/tasks/main.yml`
- Create: `roles/plex/templates/plexmedia-tmpfiles.conf.j2`

- [ ] **Step 1: Create defaults**

```yaml
# roles/plex/defaults/main.yml
---
plex_state: present
plex_transcoding_dir: /tmp/plexmedia
plex_ufw_tailscale_src: "100.64.0.0/10"
```

- [ ] **Step 2: Create tmpfiles template**

This file tells systemd-tmpfiles to recreate the transcoding directory on every boot (since `/tmp` is tmpfs and is wiped on reboot).

```
# roles/plex/templates/plexmedia-tmpfiles.conf.j2
# Managed by Ansible (plex role) — do not edit manually
d {{ plex_transcoding_dir }} 0755 plex plex -
```

- [ ] **Step 3: Create tasks**

```yaml
# roles/plex/tasks/main.yml
---
- name: Install apt-transport-https (prerequisite)
  ansible.builtin.apt:
    name: apt-transport-https
    state: present
    update_cache: false
  become: true
  when: plex_state == "present"

- name: Add Plex GPG key
  ansible.builtin.apt_key:
    url: https://downloads.plex.tv/plex-keys/PlexSign.key
    keyring: /usr/share/keyrings/plex-archive-keyring.gpg
    state: present
  become: true
  when: plex_state == "present"

- name: Add Plex apt repository
  ansible.builtin.apt_repository:
    repo: "deb [signed-by=/usr/share/keyrings/plex-archive-keyring.gpg] https://downloads.plex.tv/repo/deb public main"
    state: present
    filename: plexmediaserver
  become: true
  when: plex_state == "present"

- name: Install plexmediaserver
  ansible.builtin.apt:
    name: plexmediaserver
    state: present
    update_cache: true
  become: true
  when: plex_state == "present"

- name: Deploy tmpfiles.d config for transcoding directory
  ansible.builtin.template:
    src: plexmedia-tmpfiles.conf.j2
    dest: /etc/tmpfiles.d/plexmedia.conf
    owner: root
    group: root
    mode: '0644'
  become: true
  when: plex_state == "present"

- name: Create transcoding directory
  ansible.builtin.file:
    path: "{{ plex_transcoding_dir }}"
    state: directory
    owner: plex
    group: plex
    mode: '0755'
  become: true
  when: plex_state == "present"

- name: Allow Plex port from Tailscale range (UFW)
  community.general.ufw:
    rule: allow
    src: "{{ plex_ufw_tailscale_src }}"
    port: '32400'
    proto: tcp
  become: true
  when: plex_state == "present"

- name: Enable and start plexmediaserver
  ansible.builtin.systemd:
    name: plexmediaserver
    enabled: true
    state: started
  become: true
  when: plex_state == "present"

- name: Stop and disable plexmediaserver (state=absent)
  ansible.builtin.systemd:
    name: plexmediaserver
    enabled: false
    state: stopped
  become: true
  failed_when: false
  when: plex_state == "absent"

- name: Remove plexmediaserver (state=absent)
  ansible.builtin.apt:
    name: plexmediaserver
    state: absent
    purge: true
  become: true
  when: plex_state == "absent"

- name: Remove Plex apt repository (state=absent)
  ansible.builtin.apt_repository:
    repo: "deb [signed-by=/usr/share/keyrings/plex-archive-keyring.gpg] https://downloads.plex.tv/repo/deb public main"
    state: absent
    filename: plexmediaserver
  become: true
  when: plex_state == "absent"

- name: Remove tmpfiles config (state=absent)
  ansible.builtin.file:
    path: /etc/tmpfiles.d/plexmedia.conf
    state: absent
  become: true
  when: plex_state == "absent"
```

- [ ] **Step 4: Commit**

```bash
git add roles/plex/
git commit -m "feat(plex): new role — native plexmediaserver install with tmpfiles transcoding dir"
```

---

## Task 3: Wire styx roles, trigger pull, verify

**Files:**
- Modify: `playbooks/pull/styx.yml`
- Modify: `inventory/host_vars/styx.yml`

- [ ] **Step 1: Add roles to styx pull playbook**

In `playbooks/pull/styx.yml`, add `nas-media-mount` and `plex` before `hermes-classify-include`:

```yaml
---
# Pull-mode playbook for styx.
# Runs daily at 02:00 via crontab as the `ansible` user.

- name: Styx — Drift Correction
  hosts: styx
  gather_facts: true

  roles:
    - role: baseline
      tags: [baseline]

    - role: nas-media-mount
      tags: [nas-media-mount]

    - role: plex
      tags: [plex]

    # ── Hermes ENC (must be LAST — appends roles, never displaces) ───────────
    - role: hermes-classify-include
      tags: [hermes-classify]
```

- [ ] **Step 2: Add state vars to styx host_vars**

In `inventory/host_vars/styx.yml`, add at the bottom:

```yaml
# Plex Media Server
plex_state: present

# QNAP NAS MEDIA share mount
nas_media_mount_state: present
```

- [ ] **Step 3: Commit**

```bash
git add playbooks/pull/styx.yml inventory/host_vars/styx.yml
git commit -m "feat(styx): add nas-media-mount and plex roles to pull playbook"
```

- [ ] **Step 4: Push and trigger ansible-pull on styx**

```bash
git push origin main

ssh nwilliams-lucas@100.72.84.56 \
  'sudo su - ansible -c "/usr/bin/ansible-pull \
    -U https://github.com/nwlnexus/olympus-infra.git \
    -i inventory/styx.yml \
    playbooks/pull/styx.yml" 2>&1'
```

Expected: play recap with `failed=0`. Look for:
- `Install plexmediaserver` → changed
- `Enable and start plexmediaserver` → changed
- `Deploy systemd mount unit` → changed
- `Enable and start automount unit` → changed

- [ ] **Step 5: Verify NFS mount**

```bash
ssh nwilliams-lucas@100.72.84.56 \
  'sudo systemctl status mnt-media.automount mnt-media.mount; ls /mnt/media | head -5'
```

Expected: automount unit active, `/mnt/media` showing NAS contents.

- [ ] **Step 6: Verify Plex is listening**

```bash
ssh nwilliams-lucas@100.72.84.56 'sudo ss -tlnp | grep 32400'
```

Expected: `LISTEN 0 ... 0.0.0.0:32400`

- [ ] **Step 7: Complete Plex setup wizard (manual)**

Open an SSH tunnel on your Mac:

```bash
ssh -L 32400:localhost:32400 nwilliams-lucas@100.72.84.56
```

Navigate to `http://localhost:32400/web` in a browser. Complete the setup wizard:
1. Sign in to your Plex account
2. Name the server (e.g. `styx`)
3. Add a library → point it to `/mnt/media`
4. Go to Settings → Transcoder → set "Transcoder temporary directory" to `/tmp/plexmedia`

---

## Task 4: Extend `ddclient` role for extra public records

**Files:**
- Modify: `roles/ddclient/defaults/main.yml`
- Modify: `roles/ddclient/tasks/main.yml`
- Modify: `roles/ddclient/templates/ddclient.conf.j2`

- [ ] **Step 1: Add `ddclient_extra_public_records` to defaults**

In `roles/ddclient/defaults/main.yml`, add after `ddclient_extra_fqdns`:

```yaml
# Extra public A records in potentially different zones.
# Each entry: { fqdn: "media.nwlnexus.io", zone: "nwlnexus.io" }
# Seeded via Cloudflare API; tracked by ddclient daemon.
ddclient_extra_public_records: []
```

- [ ] **Step 2: Add seeding tasks to main.yml**

In `roles/ddclient/tasks/main.yml`, add AFTER the "Create missing internal A records" task (around line 206) and BEFORE the "ddclient config" section:

```yaml
# --- Extra public records (cross-zone) ---

- name: Look up Cloudflare zone IDs for extra public records
  ansible.builtin.uri:
    url: "https://api.cloudflare.com/client/v4/zones?name={{ item }}"
    method: GET
    headers:
      Authorization: "Bearer {{ _ddclient_cf_token }}"
    status_code: 200
  register: _ddclient_extra_zone_resps
  no_log: true
  loop: "{{ ddclient_extra_public_records | map(attribute='zone') | unique | list }}"
  when:
    - _ddclient_state == 'present'
    - ddclient_extra_public_records | length > 0

- name: Check existing extra public A records
  ansible.builtin.uri:
    url: "https://api.cloudflare.com/client/v4/zones/{{ _extra_zone_id }}/dns_records?type=A&name={{ item.fqdn }}"
    method: GET
    headers:
      Authorization: "Bearer {{ _ddclient_cf_token }}"
    status_code: 200
  vars:
    _extra_zone_id: >-
      {{ (_ddclient_extra_zone_resps.results
          | selectattr('item', 'equalto', item.zone)
          | list | first).json.result[0].id }}
  register: _ddclient_extra_checks
  no_log: true
  loop: "{{ ddclient_extra_public_records }}"
  when:
    - _ddclient_state == 'present'
    - ddclient_extra_public_records | length > 0

- name: Create missing extra public A records
  ansible.builtin.uri:
    url: "https://api.cloudflare.com/client/v4/zones/{{ _extra_zone_id }}/dns_records"
    method: POST
    headers:
      Authorization: "Bearer {{ _ddclient_cf_token }}"
      Content-Type: "application/json"
    body_format: json
    body:
      type: A
      name: "{{ item.item.fqdn }}"
      content: "{{ ansible_facts['default_ipv4']['address'] }}"
      ttl: "{{ ddclient_ttl }}"
      proxied: false
    status_code: 200
  vars:
    _extra_zone_id: >-
      {{ (_ddclient_extra_zone_resps.results
          | selectattr('item', 'equalto', item.item.zone)
          | list | first).json.result[0].id }}
  no_log: true
  loop: "{{ _ddclient_extra_checks.results | default([]) }}"
  when:
    - _ddclient_state == 'present'
    - ddclient_extra_public_records | length > 0
    - (item.json.result | default([]) | length) == 0
```

- [ ] **Step 3: Add extra zone block to ddclient.conf.j2**

At the end of `roles/ddclient/templates/ddclient.conf.j2`, add:

```jinja2
{% for zone_group in ddclient_extra_public_records | default([]) | groupby('zone') %}
# Extra public records — zone {{ zone_group.0 }}
protocol=cloudflare
zone={{ zone_group.0 }}
ttl={{ ddclient_ttl }}
login=token
password='{{ _ddclient_cf_token }}'
use=web, web=https://api.ipify.org/
{% for record in zone_group.1 %}
{{ record.fqdn }}
{% endfor %}

{% endfor %}
```

- [ ] **Step 4: Commit**

```bash
git add roles/ddclient/
git commit -m "feat(ddclient): add ddclient_extra_public_records for cross-zone public A records"
```

---

## Task 5: `unifi-dns` role

**Files:**
- Create: `roles/unifi-dns/defaults/main.yml`
- Create: `roles/unifi-dns/tasks/main.yml`
- Create: `roles/unifi-dns/tasks/upsert_policy.yml`

The Unifi Network API base URL on the local UDM SE is:
`https://{udm-host}/proxy/network/v2/api`

Endpoint paths are versioned as `/v1/...`. Self-signed cert — disable cert validation.

- [ ] **Step 1: Create defaults**

```yaml
# roles/unifi-dns/defaults/main.yml
---
unifi_dns_state: present
unifi_dns_op_token_file: /etc/olympus/op-service-account-token
unifi_dns_op_credential_ref: "op://Dev/unifi-api/credential"
unifi_dns_op_host_ref: "op://Dev/unifi-api/host"
unifi_dns_site_name: default
unifi_dns_policies: []
# Each policy entry: { domain, type (default A_RECORD), ttlSeconds (default 300) }
# ipv4Address is always resolved at run time from ansible_facts['default_ipv4']['address']
```

- [ ] **Step 2: Create main tasks**

```yaml
# roles/unifi-dns/tasks/main.yml
---
- name: Read OP service account token
  ansible.builtin.slurp:
    src: "{{ unifi_dns_op_token_file }}"
  register: _unifi_op_sat
  no_log: true
  failed_when: false
  when:
    - unifi_dns_state == "present"
    - unifi_dns_policies | length > 0

- name: Fetch Unifi API key from 1Password
  ansible.builtin.command:
    argv:
      - op
      - read
      - "{{ unifi_dns_op_credential_ref }}"
  environment:
    OP_SERVICE_ACCOUNT_TOKEN: "{{ _unifi_op_sat.content | b64decode | trim }}"
  register: _unifi_api_key
  changed_when: false
  no_log: true
  when:
    - unifi_dns_state == "present"
    - unifi_dns_policies | length > 0
    - _unifi_op_sat.content is defined

- name: Fetch Unifi host from 1Password
  ansible.builtin.command:
    argv:
      - op
      - read
      - "{{ unifi_dns_op_host_ref }}"
  environment:
    OP_SERVICE_ACCOUNT_TOKEN: "{{ _unifi_op_sat.content | b64decode | trim }}"
  register: _unifi_host
  changed_when: false
  no_log: true
  when:
    - unifi_dns_state == "present"
    - unifi_dns_policies | length > 0
    - _unifi_op_sat.content is defined

- name: Set Unifi API base URL fact
  ansible.builtin.set_fact:
    _unifi_base_url: "https://{{ _unifi_host.stdout | trim }}/proxy/network/v2/api"
  no_log: true
  when:
    - unifi_dns_state == "present"
    - unifi_dns_policies | length > 0
    - _unifi_host.stdout is defined

- name: Discover Unifi site ID
  ansible.builtin.uri:
    url: "{{ _unifi_base_url }}/v1/sites"
    method: GET
    headers:
      X-API-KEY: "{{ _unifi_api_key.stdout | trim }}"
    validate_certs: false
    status_code: 200
  register: _unifi_sites
  no_log: true
  when:
    - unifi_dns_state == "present"
    - unifi_dns_policies | length > 0
    - _unifi_base_url is defined

- name: Set site ID fact
  ansible.builtin.set_fact:
    _unifi_site_id: >-
      {{ (_unifi_sites.json.data
          | selectattr('name', 'equalto', unifi_dns_site_name)
          | list | first).id }}
  when:
    - unifi_dns_state == "present"
    - unifi_dns_policies | length > 0
    - _unifi_sites.json.data is defined

- name: Retrieve existing DNS policies
  ansible.builtin.uri:
    url: "{{ _unifi_base_url }}/v1/sites/{{ _unifi_site_id }}/dns/policies"
    method: GET
    headers:
      X-API-KEY: "{{ _unifi_api_key.stdout | trim }}"
    validate_certs: false
    status_code: 200
  register: _unifi_dns_policies_resp
  no_log: true
  when:
    - unifi_dns_state == "present"
    - unifi_dns_policies | length > 0
    - _unifi_site_id is defined

- name: Upsert DNS policies
  ansible.builtin.include_tasks: upsert_policy.yml
  loop: "{{ unifi_dns_policies }}"
  loop_control:
    loop_var: _policy
  when:
    - unifi_dns_state == "present"
    - _unifi_dns_policies_resp.json is defined
```

- [ ] **Step 3: Create upsert task**

```yaml
# roles/unifi-dns/tasks/upsert_policy.yml
---
- name: "Find existing policy for {{ _policy.domain }}"
  ansible.builtin.set_fact:
    _existing_policy: >-
      {{ (_unifi_dns_policies_resp.json.data
          | selectattr('domain', 'equalto', _policy.domain)
          | list | first) | default({}) }}

- name: "Create DNS policy for {{ _policy.domain }}"
  ansible.builtin.uri:
    url: "{{ _unifi_base_url }}/v1/sites/{{ _unifi_site_id }}/dns/policies"
    method: POST
    headers:
      X-API-KEY: "{{ _unifi_api_key.stdout | trim }}"
      Content-Type: application/json
    body_format: json
    body:
      type: "{{ _policy.type | default('A_RECORD') }}"
      enabled: true
      domain: "{{ _policy.domain }}"
      ipv4Address: "{{ ansible_facts['default_ipv4']['address'] }}"
      ttlSeconds: "{{ _policy.ttlSeconds | default(300) }}"
    validate_certs: false
    status_code: 201
  no_log: true
  when: _existing_policy | length == 0

- name: "Update DNS policy for {{ _policy.domain }} if IP changed"
  ansible.builtin.uri:
    url: "{{ _unifi_base_url }}/v1/sites/{{ _unifi_site_id }}/dns/policies/{{ _existing_policy.id }}"
    method: PUT
    headers:
      X-API-KEY: "{{ _unifi_api_key.stdout | trim }}"
      Content-Type: application/json
    body_format: json
    body:
      type: "{{ _policy.type | default('A_RECORD') }}"
      enabled: true
      domain: "{{ _policy.domain }}"
      ipv4Address: "{{ ansible_facts['default_ipv4']['address'] }}"
      ttlSeconds: "{{ _policy.ttlSeconds | default(300) }}"
    validate_certs: false
    status_code: 200
  no_log: true
  when:
    - _existing_policy | length > 0
    - _existing_policy.ipv4Address != ansible_facts['default_ipv4']['address']
```

- [ ] **Step 4: Commit**

```bash
git add roles/unifi-dns/
git commit -m "feat(unifi-dns): new role — idempotent Unifi DNS policy upsert via local API"
```

---

## Task 6: Wire management-hub roles, trigger pull, verify

**Files:**
- Modify: `playbooks/pull/management-hub.yml`
- Modify: `inventory/group_vars/management-hub.yml`

- [ ] **Step 1: Add roles to management-hub pull playbook**

In `playbooks/pull/management-hub.yml`, add `unifi-dns` and `ddclient` after `baseline`:

```yaml
  roles:
    - role: baseline
      tags: [baseline]

    - role: unifi-dns
      tags: [unifi-dns]

    - role: ddclient
      tags: [ddclient]

    - role: 1password-connect
      tags: [1password-connect]

    # ── Hermes ENC (must be LAST — appends roles, never displaces) ───────────
    - role: hermes-classify-include
      tags: [hermes-classify]
```

- [ ] **Step 2: Add vars to management-hub group_vars**

In `inventory/group_vars/management-hub.yml`, add:

```yaml
# Unifi DNS policy — local split-horizon DNS for media.nwlnexus.io
unifi_dns_state: present
unifi_dns_policies:
  - domain: media.nwlnexus.io
    type: A_RECORD
    ttlSeconds: 300

# ddclient — keep media.nwlnexus.io DNS-only A record current in Cloudflare
ddclient_state: present
ddclient_extra_public_records:
  - fqdn: media.nwlnexus.io
    zone: nwlnexus.io
```

- [ ] **Step 3: Commit, push, and trigger pull on management-hub**

```bash
git add playbooks/pull/management-hub.yml inventory/group_vars/management-hub.yml
git commit -m "feat(management-hub): add unifi-dns and ddclient roles to pull playbook"
git push origin main

ssh nwilliams-lucas@100.65.140.75 \
  'sudo su - ansible -c "/usr/bin/ansible-pull \
    -U https://github.com/nwlnexus/olympus-infra.git \
    -i inventory/management-hub.yml \
    playbooks/pull/management-hub.yml" 2>&1'
```

Expected: `failed=0`. Look for:
- `Create DNS policy for media.nwlnexus.io` → changed (first run)
- `Create missing extra public A records` → changed (first run, seeding CF record)

- [ ] **Step 4: Verify Unifi DNS policy**

```bash
ssh nwilliams-lucas@100.65.140.75 \
  'sudo -u ansible bash -c "
    TOKEN=\$(cat /etc/olympus/op-service-account-token)
    HOST=\$(OP_SERVICE_ACCOUNT_TOKEN=\$TOKEN op read op://Dev/unifi-api/host)
    KEY=\$(OP_SERVICE_ACCOUNT_TOKEN=\$TOKEN op read op://Dev/unifi-api/credential)
    SITE=\$(curl -sk -H \"X-API-KEY: \$KEY\" https://\$HOST/proxy/network/v2/api/v1/sites | python3 -c \"import sys,json; d=json.load(sys.stdin)['data']; print([s for s in d if s['name']=='default'][0]['id'])\")
    curl -sk -H \"X-API-KEY: \$KEY\" https://\$HOST/proxy/network/v2/api/v1/sites/\$SITE/dns/policies | python3 -m json.tool
  "' 2>&1 | grep -A5 "media.nwlnexus"
```

Expected: JSON entry with `"domain": "media.nwlnexus.io"` and `"ipv4Address"` matching management-hub's LAN IP.

- [ ] **Step 5: Verify Cloudflare A record was seeded**

In the Cloudflare dashboard, check that `media.nwlnexus.io` exists under `nwlnexus.io` as a DNS-only (grey cloud) A record.

---

## Task 7: olympus-gitops `apps/media/` manifests

**Files (in `nwlnexus/olympus-gitops` repo):**
- Create: `apps/media/namespace.yaml`
- Create: `apps/media/plex-external-service.yaml`
- Create: `apps/media/plex-certificate.yaml`
- Create: `apps/media/plex-ingressroute.yaml`
- Create: `apps/media/kustomization.yaml`
- Modify: parent `apps/kustomization.yaml` — add `./media` to resources

> **Before starting:** Check the existing `apps/` directory structure to confirm the parent Kustomization path and the ClusterIssuer name + `websecure` entryPoint name used by other IngressRoutes in the repo.

- [ ] **Step 1: Create namespace**

```yaml
# apps/media/namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: media
```

- [ ] **Step 2: Create external service (selector-less Service + Endpoints)**

Traefik routes to styx via Tailscale IP. Tailscale establishes a direct peer connection on the same LAN — traffic stays local, Tailscale just provides the stable addressable IP.

```yaml
# apps/media/plex-external-service.yaml
apiVersion: v1
kind: Service
metadata:
  name: plex-styx
  namespace: media
spec:
  ports:
    - name: plex
      port: 32400
      targetPort: 32400
      protocol: TCP
---
apiVersion: v1
kind: Endpoints
metadata:
  name: plex-styx
  namespace: media
subsets:
  - addresses:
      - ip: 100.72.84.56   # styx Tailscale IP — direct LAN peer connection
    ports:
      - name: plex
        port: 32400
        protocol: TCP
```

- [ ] **Step 3: Create TLS certificate**

Replace `<clusterissuer-name>` with the actual ClusterIssuer name from the repo (e.g. `letsencrypt-production`).

```yaml
# apps/media/plex-certificate.yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: plex-tls
  namespace: media
spec:
  secretName: plex-tls
  dnsNames:
    - media.nwlnexus.io
  issuerRef:
    name: <clusterissuer-name>
    kind: ClusterIssuer
```

- [ ] **Step 4: Create IngressRoute**

Replace `<websecure-entrypoint>` with the actual entryPoint name (e.g. `websecure`). The real-IP middleware ensures Plex sees client IPs correctly for remote access detection.

```yaml
# apps/media/plex-ingressroute.yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: plex-real-ip
  namespace: media
spec:
  headers:
    customRequestHeaders:
      X-Forwarded-For: ""
      X-Real-Ip: ""
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: plex
  namespace: media
spec:
  entryPoints:
    - <websecure-entrypoint>
  routes:
    - match: Host(`media.nwlnexus.io`)
      kind: Rule
      middlewares:
        - name: plex-real-ip
      services:
        - name: plex-styx
          port: 32400
  tls:
    secretName: plex-tls
```

- [ ] **Step 5: Create Kustomization**

```yaml
# apps/media/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - plex-external-service.yaml
  - plex-certificate.yaml
  - plex-ingressroute.yaml
```

- [ ] **Step 6: Add to parent Kustomization**

In the parent `apps/kustomization.yaml`, add `./media` to the resources list.

- [ ] **Step 7: Commit and push to olympus-gitops**

```bash
git add apps/media/ apps/kustomization.yaml
git commit -m "feat(media): Plex IngressRoute at media.nwlnexus.io via styx Tailscale"
git push origin main
```

- [ ] **Step 8: Watch Flux reconcile**

```bash
ssh nwilliams-lucas@100.65.140.75 \
  'sudo kubectl get kustomization -A -w'
```

Wait for the `apps` Kustomization to reconcile to `Ready`. Then check:

```bash
ssh nwilliams-lucas@100.65.140.75 \
  'sudo kubectl get ingressroute,certificate,service,endpoints -n media'
```

Expected: IngressRoute present, Certificate `READY=True`, Service and Endpoints present.

---

## Task 8: End-to-end verification

- [ ] **Step 1: Verify local DNS resolution (split-horizon)**

From a device on your local network (not styx or management-hub):

```bash
dig media.nwlnexus.io
```

Expected: resolves to management-hub's LAN IP (e.g. `192.168.253.14`). If it resolves to the public IP, the Unifi DNS policy hasn't propagated yet — check the Unifi UI under Settings → DNS Policies.

- [ ] **Step 2: Verify external DNS (Cloudflare)**

```bash
dig media.nwlnexus.io @1.1.1.1
```

Expected: resolves to your public WAN IP, not a Cloudflare proxy IP.

- [ ] **Step 3: Verify TLS and Plex UI**

Navigate to `https://media.nwlnexus.io` in a browser. Expected: Plex web UI loads with a valid Let's Encrypt certificate.

- [ ] **Step 4: Test media playback**

Play a media item from the Plex UI. Monitor for smooth playback — if transcoding is required, confirm `/tmp/plexmedia` is being used:

```bash
ssh nwilliams-lucas@100.72.84.56 'ls /tmp/plexmedia'
```

Expected: Plex session temp files present during playback.

- [ ] **Step 5: Verify idempotency — re-run management-hub pull**

```bash
ssh nwilliams-lucas@100.65.140.75 \
  'sudo su - ansible -c "/usr/bin/ansible-pull \
    -U https://github.com/nwlnexus/olympus-infra.git \
    -i inventory/management-hub.yml \
    playbooks/pull/management-hub.yml" 2>&1' | grep -E "changed|failed|RECAP"
```

Expected: `changed=0, failed=0` for unifi-dns and ddclient tasks on second run.

---

## Notes

- **Unifi API base URL:** If the API calls in `unifi-dns` fail with 404, the base URL path may differ. Try `/proxy/network/api/` instead of `/proxy/network/v2/api/`. Verify against your UDM SE firmware version.
- **Cloudflare A record proxied flag:** The ddclient role seeds records with `proxied: false` (DNS-only). Verify this in the Cloudflare dashboard after the first management-hub pull run.
- **Port 443 forwarding:** Ensure Unifi has a port forward rule: 443 → management-hub LAN IP. If other services already use this forward, it's already in place.
- **Plex claim token:** If Plex doesn't associate with your account via the web UI, you may need to use a `PLEX_CLAIM` env var during first startup. Get a claim token from `https://www.plex.tv/claim/` and set it before starting the service: `sudo systemctl set-environment PLEX_CLAIM=<token> && sudo systemctl restart plexmediaserver`.
