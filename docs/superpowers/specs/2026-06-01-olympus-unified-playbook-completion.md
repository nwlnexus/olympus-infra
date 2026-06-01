# Olympus Unified Playbook Completion Design

**Date:** 2026-06-01
**Scope:** Complete `olympus.yml` as the single self-healing pull playbook for the fleet by adding ddclient, 1password-connect, and eso-bootstrap. Fix bugs in the 1password-connect role that prevent safe fleet-wide use. Update group_vars for ai-hub, compute-hub, and management-hub to opt in. Retire argocd references.

---

## Context

After the compute-hub and styx work, `olympus.yml` covers: common, baseline, iscsi, atlas, ansible-pull, tailscale, colima, cloudflared, cloudflared-k8s, ollama, hermes-classify-include. Three gaps remain:

| Gap | Impact |
|-----|--------|
| `ddclient` missing | DNS records don't self-heal on any host |
| `1password-connect` missing | ESO must reach external Connect server; 1pw-connect not deployed on compute-hub or ai-hub |
| `eso-bootstrap` missing | External Secrets Operator can't authenticate to Connect after first push |

**Fleet state confirmed 2026-06-01:**

| Host | k8s platform | 1password-connect | ESO | 1password-credentials.json |
|------|-------------|-------------------|-----|---------------------------|
| management-hub (naraka-01) | k3s bare-metal | ✓ (via push) | ✓ | ✓ |
| compute-hub (3 × onode) | k3s bare-metal | ✗ | ✗ | ✓ (on all 3) |
| ai-hub | k3s via Colima (kubeconfig: `/var/ansible/.kube/config`, context: `colima`) | ✗ | ✗ | ✓ (just placed) |
| styx | no k8s | N/A | N/A | — |

---

## 1. Fix `1password-connect` Role Bugs

These bugs are safe in a push playbook (single host) but break fleet-wide pull:

### Bug 1: `meta: end_play` → `meta: end_host`

`roles/1password-connect/tasks/main.yml` line 14 uses `end_play`. In `olympus.yml` targeting the full fleet, a missing credentials file on one host aborts the play for ALL hosts. Must be `end_host`.

**Fix:**
```yaml
- name: Skip if credentials file missing
  ansible.builtin.meta: end_host    # was: end_play
```

### Bug 2: Kubeconfig hardcoded to `k3s_kubeconfig_path`

Every kubectl/helm task sets `KUBECONFIG: "{{ k3s_kubeconfig_path }}"`. For ai-hub (Colima), `k3s_kubeconfig_path` is undefined and the kubeconfig lives at `/var/ansible/.kube/config`.

**Fix:** Add `onepassword_connect_kubeconfig` to defaults with a fallback:
```yaml
# roles/1password-connect/defaults/main.yml
onepassword_connect_kubeconfig: "{{ k3s_kubeconfig_path | default('/var/ansible/.kube/config') }}"
```

Replace all `KUBECONFIG: "{{ k3s_kubeconfig_path }}"` → `KUBECONFIG: "{{ onepassword_connect_kubeconfig }}"` throughout tasks/main.yml (5 occurrences: namespace create, credentials secret, helm install, ingressroute apply, helm uninstall).

### Bug 3: Helm install is Linux-only but lacks platform guard

The Helm install task (line 19-27) uses `creates: /usr/local/bin/helm` and `become: true`. On macOS (ai-hub), Helm is installed via Homebrew at `/opt/homebrew/bin/helm` and `/usr/local/bin/helm` doesn't exist. The task would try to install a Linux Helm binary on macOS.

**Fix:** Add platform guard to the Helm install task:
```yaml
- name: Install helm (Linux)
  ...
  when:
    - _1pw_state == 'present'
    - ansible_facts['os_family'] != 'Darwin'
```

---

## 2. Add `ddclient` to `olympus.yml` (always-run)

ddclient self-exits via `meta: end_host` when no Cloudflare token is available, so it is safe as always-run. Add it to the "Always run" section after `baseline`, before `iscsi`:

```yaml
    - role: ddclient
      tags: [ddclient]
```

No `when:` guard. Role manages its own early-exit.

---

## 3. Add `1password-connect` and `eso-bootstrap` to `olympus.yml` (opt-in)

Place in the opt-in section, after `ansible-pull` and before `tailscale`. Sequencing matters: 1password-connect deploys the server, eso-bootstrap seeds the token ESO uses to reach it.

```yaml
    - role: 1password-connect
      tags: [1password-connect]
      when: onepassword_connect_state is defined

    - role: eso-bootstrap
      tags: [eso-bootstrap]
      when: eso_bootstrap_state is defined
```

### eso-bootstrap token sourcing in pull mode

The eso-bootstrap role requires `eso_connect_token`. In push mode this comes from ansible-vault. In pull mode, we fetch it from 1Password.

**New defaults:**
```yaml
# roles/eso-bootstrap/defaults/main.yml additions
eso_op_token_file: /etc/olympus/op-service-account-token
eso_op_connect_token_ref: "op://Dev/onepassword-connect-token/credential"
```

**New tasks prepended to `roles/eso-bootstrap/tasks/main.yml`** (before the namespace create task):
```yaml
# Fetch Connect token from 1Password if not provided directly
- name: Read OP service account token for ESO bootstrap
  ansible.builtin.slurp:
    src: "{{ eso_op_token_file }}"
  register: _eso_op_token
  no_log: true
  failed_when: false
  become: true
  when: eso_connect_token | length == 0

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
    - eso_connect_token | length == 0
    - _eso_op_token.content is defined

- name: Set eso_connect_token from 1Password
  ansible.builtin.set_fact:
    eso_connect_token: "{{ _eso_connect_token_result.stdout | trim }}"
  no_log: true
  when:
    - eso_connect_token | length == 0
    - _eso_connect_token_result.stdout is defined

- name: Skip ESO bootstrap if no Connect token available
  ansible.builtin.meta: end_host
  when: eso_connect_token | length == 0
```

This mirrors the iscsi OP fetch pattern. If `eso_connect_token` is already set (push mode via vault), the fetch is skipped entirely.

---

## 4. Group Vars Updates

### `inventory/group_vars/ai-hub.yml`

Add:
```yaml
# 1Password Connect — local k3s via Colima; kubeconfig at non-standard path
onepassword_connect_state: present
onepassword_connect_kubeconfig: /var/ansible/.kube/config

# ESO bootstrap (seeds Connect token secret into k8s)
eso_bootstrap_state: present
eso_kubeconfig_path: /var/ansible/.kube/config
```

### `inventory/group_vars/compute_hub.yml`

Add:
```yaml
# 1Password Connect — local k3s bare-metal; uses k3s_kubeconfig_path default
onepassword_connect_state: present

# ESO bootstrap
eso_bootstrap_state: present
```

compute-hub already has `eso_kubeconfig_path: "{{ k3s_kubeconfig_path }}"` and `eso_namespace: external-secrets` from the existing vars — no change needed for those.

### `inventory/group_vars/management-hub.yml`

- `onepassword_connect_state: present` — already set ✓
- Add `eso_bootstrap_state: present`
- Remove `argocd_state: present` (argocd retired, replaced by Flux)

---

## 5. Argocd Retirement

Remove `argocd_state: present` from `inventory/group_vars/management-hub.yml`. The argocd role code stays in the repo (git history) but nothing invokes it. No other group_vars or host_vars reference it.

---

## Summary of File Changes

| Action | File |
|--------|------|
| Modify | `roles/1password-connect/defaults/main.yml` — add `onepassword_connect_kubeconfig` |
| Modify | `roles/1password-connect/tasks/main.yml` — end_play→end_host, kubeconfig var, Darwin guard on Helm |
| Modify | `roles/eso-bootstrap/defaults/main.yml` — add OP token fetch vars |
| Modify | `roles/eso-bootstrap/tasks/main.yml` — prepend OP token fetch block |
| Modify | `playbooks/pull/olympus.yml` — add ddclient, 1password-connect, eso-bootstrap |
| Modify | `inventory/group_vars/ai-hub.yml` — add Connect + ESO opt-in vars with Colima kubeconfig paths |
| Modify | `inventory/group_vars/compute_hub.yml` — add Connect + ESO opt-in vars |
| Modify | `inventory/group_vars/management-hub.yml` — add eso_bootstrap_state, remove argocd_state |

---

## Constraints

- `inject_facts_as_vars = False` throughout — use `ansible_facts['os_family']`
- `end_host` not `end_play` on all self-gates in roles used in olympus.yml
- No `when:` guard on ddclient — role self-exits cleanly
- eso_connect_token fetch is skipped when token provided via vault (push mode compat)
- argocd role code not deleted — only var removed
- compute-hub: 1password-connect Helm runs on primary node only (all 3 nodes will attempt, Helm upgrade --install is idempotent — no harm but slightly wasteful; acceptable for now)
