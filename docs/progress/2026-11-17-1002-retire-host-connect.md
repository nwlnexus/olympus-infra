# Progress: nwlnexus/olympus-sdk#1002 Retire the in-cluster 1Password Connect and remove its credentials file from fleet hosts

- **Issue:** `https://github.com/nwlnexus/olympus-sdk/issues/1002`
- **Branch / worktree:** phase 1 `fix/1002-remove-host-connect-token` (merged); phase 2 `fix/1002-retire-in-cluster-connect` in `~/projects/personal/.worktrees/olympus-infra-1002-p2`
- **Session:** `personal-olympus-sdk-1002` on `ai-agent-host`; registry id `31e5a772-0188-4c10-97bd-616cf246ac9e`
- **Started:** 2026-11-17 · **Turn cap:** 60
- **PRs:** phase 1 https://github.com/nwlnexus/olympus-infra/pull/151 merged a1e816e; phase 2: not yet

## Goal

```text
No 1password-credentials.json and no op-connect-token on any fleet host; no onepassword-connect Deployment in the cluster; ESO ExternalSecrets still SecretSynced. Checks: per host `sudo -n test -e /etc/olympus/op-connect-token` and `sudo -n test -e /etc/olympus/1password-credentials.json` -> exit 1 on onode-030c31, onode-0312ce, onode-0314ac, naraka-01, data-hub; `kubectl --context compute-hub get deploy -A | grep onepassword-connect` -> no output; `kubectl --context compute-hub get externalsecrets -A` -> every READY True / STATUS SecretSynced. Progress file current until removal. Or stop after 60 turns.
```

## Done-when checks

| # | Check (command) | Expected result | Last result | Commit |
| --- | --- | --- | --- | --- |
| 1 | `ssh <host> 'sudo -n test -e /etc/olympus/op-connect-token'` (4 Linux hosts) | exit 1 | PASS: gone on all 4 at 17:51Z (removed by hand after #151 merged) | a1e816e |
| 2 | `ssh <host> 'sudo -n test -e /etc/olympus/1password-credentials.json'` (5 hosts) | exit 1 | FAIL: present on all 5 (before) | - |
| 3 | `kubectl --context compute-hub get deploy -n 1password onepassword-connect` | NotFound | FAIL: 1/1 Running, 169d (before) | - |
| 4 | `kubectl --context compute-hub get externalsecrets -A` | all READY True | PASS: 28/28 True (before) | - |
| 5 | olympus-infra `validate` CI on each PR | success | PASS: #151 validate pass 7m12s | ffcbe0c |

## Plan

### Blast radius

Blast radius: no index (olympus-infra has no `.gitnexus/`; Ansible YAML). Manual: `git grep` across olympus-infra,
olympus-sdk, olympus-gitops, nix-darwin-hm for `op-connect-token|OP_CONNECT|1password-credentials|onepassword_connect`.

### Steps

| # | Step | Model | Tier | State |
| --- | --- | --- | --- | --- |
| 1 | Phase 1 PR: ansible-pull removes `/etc/olympus/op-connect-token`; delete `playbooks/place-connect-token.yml` | opus | main | done (#151, a1e816e) |
| 2 | After merge: ask coordinator re freeze; verify via pull or `sudo -n rm -f` by hand | opus | main | done by hand; post-hold pull check pending |
| 3 | Phase 2 proof (read-only): no consumer of in-cluster Connect; what seeds it | opus | main | done |
| 4 | Phase 2 PR: drop `1password-connect` + dead `external-secrets` roles, `onepassword_credentials_json` writer, cloudflared `connect` route; pull removes the creds file | opus | main | doing |
| 5 | Uninstall in-cluster Connect (helm release `connect`, ns `1password`) | opus | main | todo |
| 6 | Verify hosts + ESO; owner checklist on #1002; close or leave open | opus | main | todo |

## Evidence log

| When | Command | Exit | Key output line | Commit |
| --- | --- | --- | --- | --- |
| 2026-11-17 | `scratchpad/hoststat-1002.sh` (stat, names/modes only) | 0 | `onode-030c31 /etc/olympus/op-connect-token ansible:root 600 2026-06-02`; same on 0312ce, 0314ac, naraka-01; data-hub `op-connect-token ABSENT`; `1password-credentials.json` on all 5 | - |
| 2026-11-17 | same script | 0 | `timers: ansible-pull=inactive enabled=enabled updater=inactive` on all 4 Linux hosts (hold for #995) | - |
| 2026-11-17 | `kubectl get deploy -n 1password onepassword-connect -o jsonpath={.metadata.annotations}` | 0 | `"meta.helm.sh/release-name":"connect","meta.helm.sh/release-namespace":"1password"` (Helm, not Flux) | - |
| 2026-11-17 | `kubectl get clustersecretstore` | 0 | `onepassword-connect https://connect.nwlnexus.net Valid` | - |
| 2026-11-17 | `mise exec ansible-core@2.20.1 -- ansible-playbook -i localhost, --syntax-check playbooks/pull/olympus.yml` | 0 | `playbook: playbooks/pull/olympus.yml` | - |
| 2026-11-17 | `gh pr checks 151 -R nwlnexus/olympus-infra` | 0 | `validate pass 7m12s` | ffcbe0c |
| 2026-11-17 | sha256 prefix of `/etc/olympus/1password-credentials.json` on 5 hosts vs `op document get olympus-credentials-file` + newline | 0 | all 5 hosts `7787a9d873c57fe1` size 1088; document + `\n` `7787a9d873c57fe1` (document 1087 bytes) | - |
| 2026-11-17 | `gh pr view 151 -R nwlnexus/olympus-infra --json state,mergeCommit` | 0 | `MERGED a1e816e29f0a 2026-11-17T17:50:58Z` | a1e816e |
| 2026-11-17 | coordinator message | - | hold still ON (timers inactive, all hosts 0.62.0); remove by hand, no timer touched | - |
| 2026-11-17 | ssh each Linux host: `sudo -n test -e`; `sudo -n rm -f /etc/olympus/op-connect-token`; `sudo -n test -e` | 0 | `17:51:39Z onode-030c31 before=present after=gone timers: pull=inactive updater=inactive`; same for onode-0312ce, onode-0314ac (17:51:40Z), naraka-01 (17:51:41Z) | a1e816e |
| 2026-11-17 | `git -C olympus-gitops grep -E "kind: (PushSecret\|SecretStore\|ClusterSecretStore)" origin/main` | 0 | one definition `clusters/olympus/external-secrets-config/cluster-secret-store.yaml:2` (connectHost Fly); no PushSecret, no SecretStore | - |
| 2026-11-17 | `kubectl get networkpolicy -n 1password`; ingress / IngressRoute grep | 0 | `No resources found in 1password namespace.`; no connect/1password ingress | - |
| 2026-11-17 | `kubectl logs -n 1password deploy/onepassword-connect -c connect-api` (all retained, from 2026-11-16T20:27Z) message counts | 0 | only `GET /health` (7701) and `GET /heartbeat` (2567); 0 `/v1/` requests | - |
| 2026-11-17 | `ansible-playbook --syntax-check` on every `playbooks/**/*.yml`; `tests/k3s-join-server/render.yml` | 0 | no FAIL; `localhost : ok=30 changed=8 unreachable=0 failed=0` | - |

## Decisions

- 2026-11-17: In-cluster Connect is the Helm release `connect` installed by olympus-infra `roles/1password-connect`
  from `/etc/olympus/1password-credentials.json` (secret `op-credentials`), not by olympus-gitops. Removal is an
  olympus-infra change plus a one-time `helm uninstall`; no olympus-gitops PR needed.
- 2026-11-17: The host credentials file is the Fly Connect's server identity: same bytes as `Dev/olympus-credentials-file` (plus a newline), which `onepassword-connect/Justfile` pushes to Fly as `OP_SESSION`. So revoking that Connect server would break ESO and CI; the owner step is an optional rotation, not a revoke.
- 2026-11-17: Two PRs: phase 1 (Connect token) first, as the owner asked; phase 2 (credentials file + role) after.

## Blocked-on

- ansible-pull timers held on the 4 Linux hosts (#995 canary). Do not start pulls or re-enable timers. The coordinator says when the hold lifts; then check one timer-driven pull per host (run.log PLAY RECAP failed=0).

## Next

1. Open phase 2 PR, CI, claim-verifier, remove this file, ready + automerge.
2. After merge: `helm uninstall connect -n 1password` and delete ns `1password` on the primary over ssh (or owner step if denied); `kubectl get externalsecrets -A`.
3. data-hub (pull not held): check its next pull removed `1password-credentials.json`; Linux hosts after the hold lifts, or by hand.
