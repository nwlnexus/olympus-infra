# Claude Code Instructions — olympus-infra

> Full context in `AGENTS.md`. This file covers Claude Code-specific operations.

> Push playbooks and inventories live in `../olympus-sdk/infra/`. Load secrets with `direnv allow`
> in that repo before running push commands.

## Running Playbooks

Push playbooks (from olympus-sdk):

```bash
# From olympus-sdk directory
ansible-playbook -i infra/inventories/management-hub.yml \
  -e @infra/group_vars/all.yml \
  infra/push-playbooks/management-bootstrap.yml \
  --cfg infra/management-hub-push.cfg

# Dry-run first
ansible-playbook ... --check --diff
```

Pull playbooks (ansible-pull, runs on hosts automatically):

```bash
# Manually trigger on a host
ssh management-hub 'sudo ansible-pull -U https://github.com/nwlnexus/olympus-infra.git \
  playbooks/pull/management-hub.yml'
```

## Key Locations

| What | Where |
|---|---|
| Roles | `roles/<name>/tasks/main.yml` |
| Role defaults | `roles/<name>/defaults/main.yml` |
| Group variables (push) | `../olympus-sdk/infra/inventories/group_vars/` |
| Pull inventory vars | `inventory/group_vars/` |
| Pull playbooks | `playbooks/pull/` |

## Rules

- Roles must be idempotent — running twice produces no changes on the second run
- Pull playbooks must complete in < 30s — health checks only, no slow installs
- Use `<role>_state: present|absent` pattern for toggling roles on/off
- Test with `--check --diff` before applying to production hosts
- This repo is public — never commit secrets, tokens, or private IPs
