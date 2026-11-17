# Progress: nwlnexus/olympus-sdk#1000 Fleet hosts lose 1Password write access (owner decision 2026-11-17)

- **Issue:** `https://github.com/nwlnexus/olympus-sdk/issues/1000`
- **Branch / worktree:** `fix/1000-hosts-read-only-1password` in `~/projects/personal/.worktrees/olympus-infra-1000` (olympus-infra)
- **Session:** `personal-olympus-sdk-1000` on `ai-agent-host`; registry id `259c2d06-07c9-49e3-bbbb-70c1d8f10f15`
- **Started:** 2026-11-17 16:10 UTC · **Turn cap:** 60
- **Draft PR:** https://github.com/nwlnexus/olympus-infra/pull/149 (docs: https://github.com/nwlnexus/olympus-sdk/pull/1001)

## Goal

```text
/goal No role that runs on a fleet host writes to 1Password (every op item|document create|edit in olympus-infra roles/ runs on the controller via delegate_to: localhost behind an owner-run flag); the break-glass export and the cloudflared item sync are owner-run push playbooks that pass ansible-playbook --syntax-check and olympus-infra CI; the legacy token copy is removed on the onodes after the next pull; owner checklist done; a harmless write with a fleet host's token fails with a permission error; #413 links #1000. Checks: git grep -n -E "'(create|edit)'|document (create|edit)" roles/ -> every hit delegate_to: localhost; syntax-check all playbooks -> syntax_fail=0; gh pr checks -> validate pass. Progress file current until removal. Or stop after 60 turns.
```

## Done-when checks

| # | Check (command) | Expected result | Last result | Commit |
| --- | --- | --- | --- | --- |
| 1 | `git grep -n -E "document (create\|edit)\|'item', '(create\|edit)'\|op item (create\|edit)\|^\s+- (create\|edit)$" -- roles/` and read each hit | hits only in cloudflare-access, cloudflare-r2, cloudflare-workers-ai-token (used only by `hosts: localhost` push playbooks) and in cloudflared-k8s/k3s tasks that carry `delegate_to: localhost` behind `cloudflared_op_write` / `k3s_kubeconfig_export`; the argocd and flux roles are gone | PASS (Evidence 16:50) | this branch |
| 2 | `bash <scratchpad>/syntax.sh .` (CI loop, ansible-core 2.21.5) | `playbooks=20 syntax_fail=0` | PASS | this branch |
| 3 | `gh pr checks <pr> --repo nwlnexus/olympus-infra` | `validate` pass | not run | |
| 4 | `ssh <onode> 'sudo -n test -e /opt/ansible-pull/.op-service-account-token; echo $?'` on the 3 onodes after merge + pull | `1` | not run (after merge) | |
| 5 | Owner checklist in the issue | all ticked | waiting on owner | |
| 6 | Write probe on onode-0314ac (issue body) | permission error, no item | waiting on owner steps 1-4 | |
| 7 | `gh issue view 413 --repo nwlnexus/olympus-sdk --comments` | a comment links #1000 | PASS (issuecomment-6953679899) | - |

## Plan

Blast radius: no index (olympus-infra has no GitNexus index on purpose, olympus-sdk#836).

Hosts affected by the role changes: the ansible-pull role (legacy file removal) on every Linux pull host; the
atlas default only matters when atlas is unregistered; cloudflared-k8s and the k3s export are skip-tagged or
push-only today, so no pull on a host changes behaviour except the legacy file removal.

| # | Step | Model | Tier | State |
| --- | --- | --- | --- | --- |
| 1 | Inventory (read-only) and issue #1000 under #424 | opus | main | done |
| 2 | cloudflared-k8s: host reads only, controller upsert behind `cloudflared_op_write`; `playbooks/push/cloudflared-op-sync.yml` | opus | main | done |
| 3 | k3s export: Jinja patch, controller write, gated `k3s_kubeconfig_export`; `playbooks/push/export-kubeconfig.yml` | opus | main | done |
| 4 | `playbooks/push/place-op-token.yml`; ansible-pull removes the legacy copy; atlas fallback dropped; comments | opus | main | done |
| 4b | Remove the dead `argocd` and `flux` roles (host-side 1Password writers, no playbook uses them) | opus | main | done |
| 5 | Offline tests with a fake `op` (scratchpad), syntax-check | opus | main | done |
| 6 | PR, verifier, automerge, post-merge pull check on the onodes | opus + sonnet verifier | main/subagent | todo |
| 7 | #413 comment; olympus-sdk doc line (INFRASTRUCTURE_SETUP.md) | opus | main | todo |
| 8 | After owner steps: write probe, pull check | opus | main | blocked (owner) |

## Evidence log

| When | Command | Exit | Key output line | Commit |
| --- | --- | --- | --- | --- |
| 16:00 | `stat` of 1Password files on 5 hosts (names/modes only) | 0 | `onode-030c31 FILE /opt/ansible-pull/.op-service-account-token ansible:ansible 600` (same on 0312ce, 0314ac; absent on naraka-01, data-hub) | - |
| 16:00 | `grep -E '-U .*olympus-infra' /opt/ansible-pull/ansible-pull-run` on onode-030c31 | 0 | `--skip-tags common,qnap-csi-bootstrap,1password-connect,cloudflared-k8s,eso-bootstrap` | - |
| 16:05 | `op item list --vault Dev` (titles, dates only) | 0 | `compute-hub-kubeconfig DOCUMENT 2026-06-01T04:33:28Z`; `compute-hub-cloudflared PASSWORD 2026-06-02T04:54:07Z` | - |
| 16:06 | `openssl x509 -enddate` client-admin.crt on onode-030c31 | 0 | `notAfter=Apr  9 15:02:12 2027 GMT` | - |
| 16:07 | `kubectl --context compute-hub auth can-i '*' '*'` on ai-agent-host | 0 | `no` (user ai-agent-host, group olympus:agents-view) | - |
| 16:01 | `op whoami` with a host token on the hosts | denied | classifier `[Unauthorized Access]` (denials.jsonl 2026-11-17T16:01:12Z) | - |
| 16:35 | fake-op test, kubeconfig export, no document | 0 | `ARGS: document create - --title=compute-hub-kubeconfig --vault=Dev --file-name=compute-hub-kubeconfig.yaml`; stdin `server: https://compute-hub.example.net:6443`, `current-context: compute-hub` | this branch |
| 16:35 | fake-op test, kubeconfig export, document exists | 0 | `ARGS: document edit compute-hub-kubeconfig - --vault=Dev` | this branch |
| 16:38 | fake-op test, cloudflared pull mode: match / missing / other tunnel | 0 | only `item get` called; `WARNING: 1Password Dev/compute-hub-cloudflared is missing ...`, `... is for tunnel tid-OLD ...` | this branch |
| 16:38 | fake-op test, cloudflared write mode: present / missing | 0 | `ARGS: item edit compute-hub-cloudflared ...` / `ARGS: item create --category=password ...` | this branch |
| 16:39 | real `op item get compute-hub-cloudflared --fields label=tunnel-id --format=json` piped to `jq keys` | 0 | `{"keys":["id","label","reference","type","value"],...}` (value not printed) | - |
| 16:40 | legacy-removal condition test | 0 | `both remove=True`, `tokenmissing remove=False`, `skipped remove=False` | this branch |
| 16:42 | `bash syntax.sh .` | 0 | `playbooks=20 syntax_fail=0` | this branch |
| 16:48 | `git grep` for `argocd`/`flux` role use in olympus-infra playbooks, inventory, tests | 0 | only `playbooks/pull/management-hub.yml:8:# (argocd role removed ...)`; the flux vars in compute_hub.yml had no reader. Removed both roles (host-side `op item/document create/edit` under /opt/homebrew, ai-hub era) | this branch |
| 17:05 | claim-verifier (sonnet) on checks 1, 2, 7, fake-op tests, place-op-token | - | `VERDICT: PASS` (merge scope; Done-when 3-6 not claimed) | e26fbee |
| 16:50 | Done-when 1 grep after removal, then `bash syntax.sh .` | 0 | 14 hits, all in the controller-only roles or delegated tasks (see check 1); `playbooks=20 syntax_fail=0` | this branch |

## Decisions

- 2026-11-17: Export the break-glass kubeconfig from an owner workstation, not ai-agent-host. Why: ai-agent-host has view-only cluster access (olympus-sdk#935), not the admin kubeconfig. The export needs root on the primary, and the agent host must not handle the admin kubeconfig.
- 2026-11-17: Keep Dev write on ai-agent-host's own service account. Why: `cloudflare-access` writes `Dev/memory-access-tokens` (#969, 2026-11-17), a concrete user. It must be a different account from the fleet's.
- 2026-11-17: The read-only fleet token is a new service account whose token goes into the existing item `Dev/olympus-edge-service-account`. Why: 1Password service-account permissions are fixed at creation, and keeping the item name means no reference changes.
- 2026-11-17: No olympus-gitops change. Why: the cluster only reads (ESO via Connect, no PushSecret).
- 2026-11-17: Remove the `argocd` and `flux` roles. Why: they write to 1Password from the host and no olympus-infra playbook uses them (Hermes classify is disabled on every host, `/etc/olympus/hermes-disabled`). The only reference left is olympus-sdk's legacy `infra/push-playbooks/management-bootstrap.yml`, which targets the retired management-hub.
- 2026-11-17: The in-cluster `onepassword-connect` and the extra Connect files on hosts are a follow-up. Why: they are read paths, not write paths.

## Blocked-on

- Owner steps 1-4 (new read-only SA, token into the item, place-op-token, delete the old SA) before Done-when 5 and 6.
- The write probe with a host token was refused by the classifier (`[Unauthorized Access]`) for `op whoami`; the probe is likely the owner's.

## Next

1. Commit, push, open the PR in olympus-infra, run the claim-verifier, add `automerge`.
2. After merge: check the legacy file is gone on the 3 onodes after their next pull; comment on #413 and #1000.
