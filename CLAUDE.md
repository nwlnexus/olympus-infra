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

<!-- gitnexus:start -->
# GitNexus — Code Intelligence

This project is indexed by GitNexus as **olympus-infra**. Use the GitNexus MCP tools to understand code, assess impact, and navigate safely.

> Index stale? Run `node .gitnexus/run.cjs analyze` from the project root — it auto-selects an available runner. No `.gitnexus/run.cjs` yet? `npx gitnexus analyze` (npm 11 crash → `npm i -g gitnexus`; #1939).

## Always Do

- **MUST run impact analysis before editing any symbol.** Before modifying a function, class, or method, run `impact({target: "symbolName", direction: "upstream"})` and report the blast radius (direct callers, affected processes, risk level) to the user.
- **MUST run `detect_changes()` before committing** to verify your changes only affect expected symbols and execution flows. For regression review, compare against the default branch: `detect_changes({scope: "compare", base_ref: "main"})`.
- **MUST warn the user** if impact analysis returns HIGH or CRITICAL risk before proceeding with edits.
- When exploring unfamiliar code, use `query({search_query: "concept"})` to find execution flows instead of grepping. It returns process-grouped results ranked by relevance.
- When you need full context on a specific symbol — callers, callees, which execution flows it participates in — use `context({name: "symbolName"})`.
- For security review, `explain({target: "fileOrSymbol"})` lists taint findings (source→sink flows; needs `analyze --pdg`).

## Never Do

- NEVER edit a function, class, or method without first running `impact` on it.
- NEVER ignore HIGH or CRITICAL risk warnings from impact analysis.
- NEVER rename symbols with find-and-replace — use `rename` which understands the call graph.
- NEVER commit changes without running `detect_changes()` to check affected scope.

## Resources

| Resource | Use for |
|----------|---------|
| `gitnexus://repo/olympus-infra/context` | Codebase overview, check index freshness |
| `gitnexus://repo/olympus-infra/clusters` | All functional areas |
| `gitnexus://repo/olympus-infra/processes` | All execution flows |
| `gitnexus://repo/olympus-infra/process/{name}` | Step-by-step execution trace |

<!-- gitnexus:end -->
