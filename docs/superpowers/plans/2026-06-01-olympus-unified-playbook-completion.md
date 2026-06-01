# Olympus Unified Playbook Completion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete `olympus.yml` as the single self-healing pull playbook for the fleet by adding ddclient, 1password-connect, and eso-bootstrap, fixing role bugs that block safe fleet-wide use, and updating group_vars for all three k8s clusters plus retiring argocd.

**Architecture:** ddclient goes in the always-run section (self-exits if no token). 1password-connect and eso-bootstrap are opt-in via `when: <role>_state is defined`. The 1password-connect role has three bugs that must be fixed first: `end_play` → `end_host`, hardcoded `k3s_kubeconfig_path` → configurable var (needed for ai-hub Colima), and a missing platform guard on the Linux-only Helm install step. The eso-bootstrap role gets an OP token fetch prepended so it works in pull mode without vault.

**Tech Stack:** Ansible 2.15+, Helm 3, kubectl, 1Password CLI (`op`), Jinja2 templates.

**Env prerequisite:** `source ~/projects/personal/.env` before any push/ad-hoc runs from olympus-sdk.

**Ad-hoc verification pattern** (from olympus-sdk root):
```bash
source ~/projects/personal/.env
ANSIBLE_CONFIG=infra/management-hub-push.cfg \
ANSIBLE_SSH_ARGS="-o IdentityAgent=none -o StrictHostKeyChecking=no" \
ansible-playbook \
  -i /Users/nwilliams-lucas/projects/personal/olympus-infra/inventory/<INVENTORY>.yml \
  -e "ansible_host=<IP> ansible_connection=ssh ansible_user=ansible ansible_ssh_private_key_file=~/.ssh/ansible" \
  /Users/nwilliams-lucas/projects/personal/olympus-infra/playbooks/pull/olympus.yml \
  --limit <HOSTNAME> --tags=<TAGS>
```

**Baseline SHA:** `1576a273c12c9ba5dc051755cd4f904f3fadd197`

---

## File Map

| Action | File |
|--------|------|
| Modify | `roles/1password-connect/defaults/main.yml` — add `onepassword_connect_kubeconfig` |
| Modify | `roles/1password-connect/tasks/main.yml` — end_play→end_host, replace k3s_kubeconfig_path, add Darwin guard |
| Modify | `roles/eso-bootstrap/defaults/main.yml` — add OP token fetch vars |
| Modify | `roles/eso-bootstrap/tasks/main.yml` — prepend OP fetch + end_host gate |
| Modify | `playbooks/pull/olympus.yml` — add ddclient (always), 1password-connect + eso-bootstrap (opt-in) |
| Modify | `inventory/group_vars/ai-hub.yml` — add Connect + ESO opt-in with Colima kubeconfig paths |
| Modify | `inventory/group_vars/compute_hub.yml` — add Connect + ESO opt-in |
| Modify | `inventory/group_vars/management-hub.yml` — add eso_bootstrap_state, remove argocd_state |

---

## Task 1 — Fix `1password-connect` Role

**Files:**
- Modify: `roles/1password-connect/defaults/main.yml`
- Modify: `roles/1password-connect/tasks/main.yml`

- [ ] **Step 1: Read both files to confirm current state**

```bash
grep -n "end_play\|k3s_kubeconfig_path\|ProtectHome\|kubeconfig" \
  roles/1password-connect/defaults/main.yml \
  roles/1password-connect/tasks/main.yml
```

Expected: `end_play` on line 14 of tasks, `k3s_kubeconfig_path` on lines 53, 67, 80, 99, 109. No `kubeconfig` in defaults.

- [ ] **Step 2: Add `onepassword_connect_kubeconfig` to defaults**

Append to `roles/1password-connect/defaults/main.yml`:

```yaml
# Kubeconfig path — override for non-standard k8s (e.g. Colima on macOS uses /var/ansible/.kube/config)
onepassword_connect_kubeconfig: "{{ k3s_kubeconfig_path | default('/var/ansible/.kube/config') }}"
```

Full file after change:
```yaml
---
onepassword_connect_state: present
onepassword_connect_namespace: "1password"
onepassword_connect_chart_version: "1.15.0"
onepassword_connect_credentials_file: "/etc/olympus/1password-credentials.json"
onepassword_connect_token_file: "/etc/olympus/onepassword-connect-token"
onepassword_connect_port: 8080
# Public hostname for Traefik IngressRoute (set in host_vars to enable)
onepassword_connect_hostname: ""
# k8s service name as created by the Helm chart (release: connect, chart: connect)
onepassword_connect_service_name: "onepassword-connect"
# Kubeconfig path — override for non-standard k8s (e.g. Colima on macOS uses /var/ansible/.kube/config)
onepassword_connect_kubeconfig: "{{ k3s_kubeconfig_path | default('/var/ansible/.kube/config') }}"
```

- [ ] **Step 3: Fix tasks/main.yml — three changes**

**Fix A:** Line 14, change `end_play` → `end_host`:
```yaml
- name: Skip if credentials file missing
  ansible.builtin.meta: end_host
```

**Fix B:** Replace ALL 5 occurrences of `KUBECONFIG: "{{ k3s_kubeconfig_path }}"` with `KUBECONFIG: "{{ onepassword_connect_kubeconfig }}"` (lines 53, 67, 80, 99, 109). Use replace_all to catch all:

Each occurrence becomes:
```yaml
  environment:
    KUBECONFIG: "{{ onepassword_connect_kubeconfig }}"
```

**Fix C:** Add Darwin platform guard to the Helm install task (lines 19-27). Change the `when:` from:
```yaml
  when: _1pw_state == 'present'
```
to:
```yaml
  when:
    - _1pw_state == 'present'
    - ansible_facts['os_family'] != 'Darwin'
```
This applies ONLY to the "Install helm (Linux)" task — every other task keeps its existing `when:` unchanged.

- [ ] **Step 4: Verify changes**

```bash
grep -n "end_host\|end_play\|k3s_kubeconfig_path\|onepassword_connect_kubeconfig\|Darwin" \
  roles/1password-connect/tasks/main.yml
```

Expected output:
```
14:  ansible.builtin.meta: end_host
27:    - ansible_facts['os_family'] != 'Darwin'
53:    KUBECONFIG: "{{ onepassword_connect_kubeconfig }}"
67:    KUBECONFIG: "{{ onepassword_connect_kubeconfig }}"
80:    KUBECONFIG: "{{ onepassword_connect_kubeconfig }}"
99:    KUBECONFIG: "{{ onepassword_connect_kubeconfig }}"
109:    KUBECONFIG: "{{ onepassword_connect_kubeconfig }}"
```

No remaining `k3s_kubeconfig_path`, no `end_play`.

- [ ] **Step 5: Commit**

```bash
git add roles/1password-connect/defaults/main.yml \
        roles/1password-connect/tasks/main.yml
git commit -m "fix(1password-connect): kubeconfig var, end_host gate, Darwin Helm guard

- Add onepassword_connect_kubeconfig var (falls back to ~/.kube/config for Colima)
- Replace hardcoded k3s_kubeconfig_path with new var in all 5 KUBECONFIG env blocks
- end_play → end_host: avoids aborting entire fleet play when one host lacks creds
- Helm install Linux-only: macOS already has Helm via Homebrew at a different path"
```

---

## Task 2 — Fix `eso-bootstrap` Role

**Files:**
- Modify: `roles/eso-bootstrap/defaults/main.yml`
- Modify: `roles/eso-bootstrap/tasks/main.yml`

- [ ] **Step 1: Add new defaults**

Append to `roles/eso-bootstrap/defaults/main.yml`:

```yaml
# Pull-mode token sourcing — reads Connect token from 1Password if eso_connect_token is empty
eso_op_token_file: /etc/olympus/op-service-account-token
eso_op_connect_token_ref: "op://Dev/onepassword-connect-token/credential"
```

Full file after change:
```yaml
---
eso_bootstrap_state: present
eso_connect_token: ""
eso_namespace: external-secrets
# Kubeconfig / context — override for non-k3s clusters
eso_kubeconfig_path: "{{ ansible_facts['env']['HOME'] }}/.kube/config"
eso_kubectl_context: ""
eso_kubectl_become: "{{ ansible_facts['system'] != 'Darwin' }}"
# Pull-mode token sourcing — reads Connect token from 1Password if eso_connect_token is empty
eso_op_token_file: /etc/olympus/op-service-account-token
eso_op_connect_token_ref: "op://Dev/onepassword-connect-token/credential"
```

- [ ] **Step 2: Prepend OP fetch block to tasks/main.yml**

Insert the following block at the VERY TOP of `roles/eso-bootstrap/tasks/main.yml`, BEFORE the existing "Set kubectl base command" task. The full file after change:

```yaml
---
# Seeds the 1Password Connect token into the cluster so ESO can bootstrap.
# This is a one-time operation — subsequent secret rotation goes through ESO itself.

# ── Pull-mode token resolution ────────────────────────────────────────────────
# If eso_connect_token is provided directly (push mode via vault), these tasks skip.
# In pull mode, the token is fetched from 1Password using the OP SA token.
- name: Read OP service account token for ESO bootstrap
  ansible.builtin.slurp:
    src: "{{ eso_op_token_file }}"
  register: _eso_op_token
  no_log: true
  failed_when: false
  become: true
  when:
    - eso_bootstrap_state == 'present'
    - eso_connect_token | length == 0

- name: Fetch 1Password Connect token from 1Password
  ansible.builtin.command:
    argv:
      - op
      - read
      - "{{ eso_op_connect_token_ref }}"
  environment:
    OP_SERVICE_ACCOUNT_TOKEN: "{{ _eso_op_token.content | b64decode | trim }}"
  register: _eso_connect_token_result
  changed_when: false
  no_log: true
  when:
    - eso_bootstrap_state == 'present'
    - eso_connect_token | length == 0
    - _eso_op_token.content is defined

- name: Set eso_connect_token from 1Password
  ansible.builtin.set_fact:
    eso_connect_token: "{{ _eso_connect_token_result.stdout | trim }}"
  no_log: true
  when:
    - eso_bootstrap_state == 'present'
    - eso_connect_token | length == 0
    - _eso_connect_token_result.stdout is defined

- name: Skip ESO bootstrap if no Connect token available
  ansible.builtin.meta: end_host
  when:
    - eso_bootstrap_state == 'present'
    - eso_connect_token | length == 0

# ── Existing tasks ────────────────────────────────────────────────────────────
- name: Set kubectl base command
  ansible.builtin.set_fact:
    _eso_kubectl: >-
      kubectl
      {%- if eso_kubectl_context != '' %} --context {{ eso_kubectl_context }}{% endif %}

- name: Create external-secrets namespace
  ansible.builtin.command: "{{ _eso_kubectl }} create namespace {{ eso_namespace }}"
  register: _eso_ns
  failed_when:
    - _eso_ns.rc != 0
    - "'already exists' not in _eso_ns.stderr"
  changed_when: _eso_ns.rc == 0
  become: "{{ eso_kubectl_become }}"
  environment:
    KUBECONFIG: "{{ eso_kubeconfig_path }}"
  when: eso_bootstrap_state == 'present'

- name: Seed ESO 1Password Connect token secret
  ansible.builtin.shell: |
    set -o pipefail
    {{ _eso_kubectl }} create secret generic eso-op-connect-token \
      --from-literal=token={{ eso_connect_token }} \
      -n {{ eso_namespace }} \
      --dry-run=client -o yaml | {{ _eso_kubectl }} apply -f -
  args:
    executable: /bin/bash
  become: "{{ eso_kubectl_become }}"
  environment:
    KUBECONFIG: "{{ eso_kubeconfig_path }}"
  no_log: true
  changed_when: true
  when: eso_bootstrap_state == 'present'
```

- [ ] **Step 3: Verify token fetch tasks appear before kubectl tasks**

```bash
grep -n "Read OP\|Fetch 1Password\|Set eso_connect\|Skip ESO\|Set kubectl" \
  roles/eso-bootstrap/tasks/main.yml
```

Expected: OP fetch tasks appear on lower line numbers than "Set kubectl base command".

- [ ] **Step 4: Commit**

```bash
git add roles/eso-bootstrap/defaults/main.yml \
        roles/eso-bootstrap/tasks/main.yml
git commit -m "feat(eso-bootstrap): pull-mode token sourcing via 1Password

In push mode, eso_connect_token is provided via vault — new tasks skip.
In pull mode, token is fetched from op://Dev/onepassword-connect-token/credential
using the host's OP service account token. end_host gate prevents silent
failures when neither token source is available."
```

---

## Task 3 — Update `olympus.yml`

**Files:**
- Modify: `playbooks/pull/olympus.yml`

- [ ] **Step 1: Add ddclient to always-run section, 1password-connect + eso-bootstrap to opt-in section**

Full `roles:` block after change (complete replacement of the roles section from line 42):

```yaml
  roles:
    # ── Always run — roles handle OS/arch internally ──────────────────────────
    - role: common
      tags: [common]
      when: ansible_facts['os_family'] != 'Darwin'

    - role: baseline
      tags: [baseline]

    - role: ddclient
      tags: [ddclient]

    - role: ansible-pull
      tags: [ansible-pull]

    # ── Opt-in via _state vars set in host/group vars ─────────────────────────
    - role: iscsi
      tags: [iscsi]
      when: iscsi_state is defined

    - role: atlas
      tags: [atlas]
      when: atlas_state is defined

    - role: 1password-connect
      tags: [1password-connect]
      when: onepassword_connect_state is defined

    - role: eso-bootstrap
      tags: [eso-bootstrap]
      when: eso_bootstrap_state is defined

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

- [ ] **Step 2: Verify role ordering**

```bash
grep -n "role:" playbooks/pull/olympus.yml
```

Expected order: common, baseline, ddclient, ansible-pull, iscsi, atlas, 1password-connect, eso-bootstrap, tailscale, colima, cloudflared, cloudflared-k8s, ollama, hermes-classify-include.

- [ ] **Step 3: Commit**

```bash
git add playbooks/pull/olympus.yml
git commit -m "feat(olympus): add ddclient (always), 1password-connect + eso-bootstrap (opt-in)

ddclient: no guard needed — role self-exits via end_host when no CF token.
1password-connect + eso-bootstrap: opt-in via _state vars; sequenced so
Connect server deploys before ESO bootstrap seeds its auth token."
```

---

## Task 4 — Update Group Vars

**Files:**
- Modify: `inventory/group_vars/ai-hub.yml`
- Modify: `inventory/group_vars/compute_hub.yml`
- Modify: `inventory/group_vars/management-hub.yml`

- [ ] **Step 1: Update ai-hub.yml — add Connect + ESO with Colima kubeconfig**

Append to `inventory/group_vars/ai-hub.yml`:

```yaml

# 1Password Connect — k3s via Colima; kubeconfig at non-standard path
onepassword_connect_state: present
onepassword_connect_kubeconfig: /var/ansible/.kube/config

# ESO bootstrap — seeds Connect token into ESO secret
eso_bootstrap_state: present
eso_kubeconfig_path: /var/ansible/.kube/config
```

- [ ] **Step 2: Update compute_hub.yml — add Connect + ESO**

Append to `inventory/group_vars/compute_hub.yml`:

```yaml

# 1Password Connect — k3s bare-metal; uses k3s_kubeconfig_path via onepassword_connect_kubeconfig default
onepassword_connect_state: present

# ESO bootstrap
eso_bootstrap_state: present
```

(compute_hub already has `eso_kubeconfig_path: "{{ k3s_kubeconfig_path }}"` — no override needed)

- [ ] **Step 3: Update management-hub.yml — add eso_bootstrap_state, remove argocd_state**

In `inventory/group_vars/management-hub.yml`:

Find and remove this line:
```yaml
argocd_state: present
```

Add `eso_bootstrap_state: present` — insert it near the other state vars (after `onepassword_connect_state: present`):
```yaml
onepassword_connect_state: present
eso_bootstrap_state: present
```

- [ ] **Step 4: Verify group vars**

```bash
grep -E "onepassword_connect_state|eso_bootstrap_state|argocd_state|kubeconfig" \
  inventory/group_vars/ai-hub.yml \
  inventory/group_vars/compute_hub.yml \
  inventory/group_vars/management-hub.yml
```

Expected:
- ai-hub: `onepassword_connect_state: present`, `onepassword_connect_kubeconfig: /var/ansible/.kube/config`, `eso_bootstrap_state: present`, `eso_kubeconfig_path: /var/ansible/.kube/config`
- compute_hub: `onepassword_connect_state: present`, `eso_bootstrap_state: present`
- management-hub: `onepassword_connect_state: present`, `eso_bootstrap_state: present`, NO `argocd_state`

- [ ] **Step 5: Commit and push**

```bash
git add inventory/group_vars/ai-hub.yml \
        inventory/group_vars/compute_hub.yml \
        inventory/group_vars/management-hub.yml
git commit -m "feat(fleet): opt-in 1password-connect + eso-bootstrap on all k8s clusters; retire argocd

- ai-hub: Connect + ESO with Colima kubeconfig (/var/ansible/.kube/config)
- compute-hub: Connect + ESO (uses k3s default kubeconfig path)
- management-hub: add eso_bootstrap_state; remove argocd_state (replaced by Flux)
All three clusters now run local 1PW Connect — ESO stays within the cluster."
git push origin main
```

---

## Task 5 — Verify on Management-Hub (already has 1PW Connect)

Management-hub is the safest first verification: 1password-connect is already deployed (Helm upgrade will be a no-op), and eso-bootstrap seeding the token is idempotent (`kubectl apply --dry-run`).

- [ ] **Step 1: Run 1password-connect + eso-bootstrap tags against naraka-01**

```bash
cd /Users/nwilliams-lucas/projects/personal/olympus-sdk && source ~/projects/personal/.env
ANSIBLE_CONFIG=infra/management-hub-push.cfg \
ANSIBLE_SSH_ARGS="-o IdentityAgent=none -o StrictHostKeyChecking=no" \
ansible-playbook \
  -i /Users/nwilliams-lucas/projects/personal/olympus-infra/inventory/management-hub.yml \
  -e "ansible_host=100.65.140.75 ansible_connection=ssh ansible_user=ansible ansible_ssh_private_key_file=~/.ssh/ansible" \
  /Users/nwilliams-lucas/projects/personal/olympus-infra/playbooks/pull/olympus.yml \
  --limit management-hub \
  --tags=1password-connect,eso-bootstrap
```

Expected: 0 failed, 0 unreachable. 1password-connect shows `changed: false` (already deployed). eso-bootstrap shows `changed: true` (first pull-mode run).

- [ ] **Step 2: Run ddclient tag against naraka-01 to confirm always-run**

```bash
ANSIBLE_CONFIG=infra/management-hub-push.cfg \
ANSIBLE_SSH_ARGS="-o IdentityAgent=none -o StrictHostKeyChecking=no" \
ansible-playbook \
  -i /Users/nwilliams-lucas/projects/personal/olympus-infra/inventory/management-hub.yml \
  -e "ansible_host=100.65.140.75 ansible_connection=ssh ansible_user=ansible ansible_ssh_private_key_file=~/.ssh/ansible" \
  /Users/nwilliams-lucas/projects/personal/olympus-infra/playbooks/pull/olympus.yml \
  --limit management-hub \
  --tags=ddclient
```

Expected: 0 failed. ddclient tasks run and resolve to mostly `ok`.

- [ ] **Step 3: Verify eso-bootstrap seeded the secret on management-hub**

```bash
ssh -i ~/.ssh/ansible -o IdentityAgent=none ansible@100.65.140.75 \
  'sudo -i kubectl get secret eso-op-connect-token -n external-secrets 2>/dev/null && echo "SECRET EXISTS" || echo "NOT FOUND"'
```

Expected: `SECRET EXISTS`.

- [ ] **Step 4: First-time deploy on compute-hub primary (onode-030c31)**

```bash
ANSIBLE_CONFIG=infra/management-hub-push.cfg \
ANSIBLE_SSH_ARGS="-o IdentityAgent=none -o StrictHostKeyChecking=no" \
ansible-playbook \
  -i /Users/nwilliams-lucas/projects/personal/olympus-infra/inventory/compute-hub.yml \
  -e "ansible_host=192.168.253.7 ansible_connection=ssh ansible_user=ansible ansible_ssh_private_key_file=~/.ssh/ansible" \
  /Users/nwilliams-lucas/projects/personal/olympus-infra/playbooks/pull/olympus.yml \
  --limit onode-030c31 \
  --tags=1password-connect,eso-bootstrap
```

Expected: 0 failed. 1password-connect Helm install shows changed (first time). eso-bootstrap seeds token. Note: the other two compute nodes can run separately or via the next ansible-pull cycle.

- [ ] **Step 5: First-time deploy on ai-hub**

```bash
ANSIBLE_CONFIG=infra/management-hub-push.cfg \
ANSIBLE_SSH_ARGS="-o IdentityAgent=none -o StrictHostKeyChecking=no" \
ansible-playbook \
  -i /Users/nwilliams-lucas/projects/personal/olympus-infra/inventory/ai-hub.yml \
  -e "ansible_host=100.95.232.41 ansible_connection=ssh ansible_user=ansible ansible_ssh_private_key_file=~/.ssh/ansible" \
  /Users/nwilliams-lucas/projects/personal/olympus-infra/playbooks/pull/olympus.yml \
  --limit ai-hub \
  --tags=1password-connect,eso-bootstrap
```

Expected: 0 failed. Helm install uses `/var/ansible/.kube/config` (Colima context). eso-bootstrap seeds token into the Colima k8s cluster.

- [ ] **Step 6: Verify ai-hub ESO secret**

```bash
ssh -i ~/.ssh/ansible -o IdentityAgent=none ansible@100.95.232.41 \
  'export KUBECONFIG=/var/ansible/.kube/config PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"; \
   kubectl get secret eso-op-connect-token -n external-secrets 2>/dev/null && echo "OK" || echo "NOT FOUND"'
```

Expected: `OK`.
