#!/usr/bin/env bash
# k3s-health-gate.sh - health gate for the olympus k3s cluster upgrade.
#
# Implements the health gate in design section 6 of
# docs/superpowers/specs/2026-10-04-k3s-upgrade-1.35-design.md.
# Run it before each hop and after each server is upgraded.
#
# Usage:
#   scripts/k3s-health-gate.sh [-c <conf>] [-a <allowlist>]
#
#   -c  config file   (default: scripts/k3s-health-gate.conf, or $K3S_GATE_CONF)
#   -a  pod allowlist (default: scripts/k3s-health-gate.allowlist, or $K3S_GATE_ALLOWLIST)
#
# Runs from an operator workstation over SSH to the nodes listed in the config
# (passwordless sudo required). It is read-only: it never changes the cluster.
# Expected values (etcd member IDs and version, VolumeAttachment count, ...)
# come from the config, so a hop only edits the config.
#
# Output: one PASS/FAIL line per check (INFO lines are context only, indented
# lines are details). Exit status: 0 all checks passed, 1 at least one check
# failed, 2 usage or configuration error.
#
# Requires locally: bash 4+, ssh, jq, GNU date.
# Requires on the servers: sudo, curl, k3s. On the first agent: curl.

set -uo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
conf=${K3S_GATE_CONF:-$script_dir/k3s-health-gate.conf}
allowlist=${K3S_GATE_ALLOWLIST:-$script_dir/k3s-health-gate.allowlist}

usage() { sed -n '2,/^$/{s/^# \{0,1\}//;p}' "$0"; }

while getopts ':c:a:h' opt; do
  case $opt in
    c) conf=$OPTARG ;;
    a) allowlist=$OPTARG ;;
    h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

for bin in ssh jq date; do
  command -v "$bin" >/dev/null || { echo "missing required command: $bin" >&2; exit 2; }
done
[[ -r $conf ]] || { echo "config not readable: $conf" >&2; exit 2; }
[[ -r $allowlist ]] || { echo "allowlist not readable: $allowlist" >&2; exit 2; }
# shellcheck source=k3s-health-gate.conf
source "$conf"

for var in SERVERS AGENTS VIP_URL VIP_EXPECTED_HTTP VIP_LEASE_NAMESPACE VIP_LEASE_NAME \
  VIP_LEASE_MAX_AGE_SECONDS EXPECTED_ETCD_MEMBERS EXPECTED_ETCDSERVER RAFT_INDEX_MAX_SPREAD \
  EXPECTED_NODE_COUNT EXPECTED_VA_ATTACHED CSI_NAMESPACE CERT_MIN_DAYS \
  RECENT_RESTART_MINUTES POD_GRACE_MINUTES; do
  [[ -n ${!var:-} ]] || { echo "config $conf: $var is not set" >&2; exit 2; }
done
EXPECTED_ETCDCLUSTER=${EXPECTED_ETCDCLUSTER:-}
EXPECTED_SERVER_K3S_VERSION=${EXPECTED_SERVER_K3S_VERSION:-}
EXPECTED_AGENT_K3S_VERSION=${EXPECTED_AGENT_K3S_VERSION:-}

server_names=() server_targets=()
for entry in $SERVERS; do server_names+=("${entry%%=*}"); server_targets+=("${entry#*=}"); done
agent_names=() agent_targets=()
for entry in $AGENTS; do agent_names+=("${entry%%=*}"); agent_targets+=("${entry#*=}"); done

SSH_OPTS=(-n -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=5
  -o ServerAliveCountMax=3 -o LogLevel=ERROR)
rssh() { local target=$1; shift; ssh "${SSH_OPTS[@]}" "$target" "$@"; }

checks=0 fails=0
pass() { checks=$((checks + 1)); printf 'PASS  %-20s %s\n' "$1" "$2"; }
fail() { checks=$((checks + 1)); fails=$((fails + 1)); printf 'FAIL  %-20s %s\n' "$1" "$2"; }
info() { printf 'INFO  %-20s %s\n' "$1" "$2"; }
detail() { [[ -n $1 ]] && sed 's/^/        /' <<<"$1"; return 0; }
is_json() { jq -e 'type == "object"' >/dev/null 2>&1 <<<"$1"; }
oneline() { tr -d '\r' <<<"$1" | paste -sd' ' | cut -c1-200; }

now=$(date -u +%s)
info "gate" "$(date -u +%Y-%m-%dT%H:%M:%SZ) conf=$(basename "$conf") allowlist=$(basename "$allowlist")"

# --------------------------------------------------------------------------
# etcd, through k3s's HTTP gateway on 127.0.0.1:2382 on each server
# --------------------------------------------------------------------------
etcd_remote='E=/var/lib/rancher/k3s/server/tls/etcd
c() { sudo -n curl -sS --max-time 5 --cacert "$E/server-ca.crt" --cert "$E/server-client.crt" --key "$E/server-client.key" "$@" 2>&1 | tr -d "\n"; echo; }
c https://127.0.0.1:2382/version
c -X POST -d "{}" https://127.0.0.1:2382/v3/cluster/member/list
c -X POST -d "{}" https://127.0.0.1:2382/v3/maintenance/status
c -X POST -d "{\"action\":\"GET\"}" https://127.0.0.1:2382/v3/maintenance/alarm'

declare -A e_version e_members e_status e_alarm
etcd_ok=() etcd_bad=""
for i in "${!server_names[@]}"; do
  name=${server_names[$i]}
  mapfile -t out < <(rssh "${server_targets[$i]}" "$etcd_remote" 2>&1)
  good=1
  for j in 0 1 2 3; do
    if ! is_json "${out[$j]:-}" || jq -e 'has("error")' >/dev/null <<<"${out[$j]}"; then good=0; fi
  done
  if ((good)); then
    etcd_ok+=("$name")
    e_version[$name]=${out[0]} e_members[$name]=${out[1]} e_status[$name]=${out[2]} e_alarm[$name]=${out[3]}
  else
    etcd_bad+="$name: $(oneline "${out[*]:-no output}")"$'\n'
  fi
done
if [[ -z $etcd_bad ]]; then
  pass "etcd.gateway" "${#etcd_ok[@]}/${#server_names[@]} servers answered on 127.0.0.1:2382"
else
  fail "etcd.gateway" "$((${#server_names[@]} - ${#etcd_ok[@]}))/${#server_names[@]} servers did not answer on 127.0.0.1:2382"
  detail "${etcd_bad%$'\n'}"
fi

if ((${#etcd_ok[@]} > 0)); then
  # /version: etcdserver (and optionally etcdcluster)
  bad=0 txt=""
  for name in "${etcd_ok[@]}"; do
    srv=$(jq -r '.etcdserver // "?"' <<<"${e_version[$name]}")
    cl=$(jq -r '.etcdcluster // "?"' <<<"${e_version[$name]}")
    txt+="$name=$srv/$cl "
    # EXPECTED_ETCDSERVER may list several versions (space-separated) while a hop is in progress.
    [[ " $EXPECTED_ETCDSERVER " == *" $srv "* ]] || bad=1
    [[ -z $EXPECTED_ETCDCLUSTER || $cl == "$EXPECTED_ETCDCLUSTER" ]] || bad=1
  done
  want="etcdserver=$EXPECTED_ETCDSERVER${EXPECTED_ETCDCLUSTER:+ etcdcluster=$EXPECTED_ETCDCLUSTER}"
  if ((bad)); then fail "etcd.version" "want $want; got (server/cluster) ${txt% }"
  else pass "etcd.version" "$want (server/cluster: ${txt% })"; fi

  # member/list: same member IDs everywhere, no learners
  want_ids=$(jq -rn --arg s "$EXPECTED_ETCD_MEMBERS" '$s | split(" ") | map(select(. != "")) | sort | join(" ")')
  bad="" learners=""
  for name in "${etcd_ok[@]}"; do
    got=$(jq -r '[.members[].ID] | sort | join(" ")' <<<"${e_members[$name]}")
    [[ $got == "$want_ids" ]] || bad+="$name sees: $got"$'\n'
    l=$(jq -r '[.members[] | select(.isLearner == true) | .name] | join(",")' <<<"${e_members[$name]}")
    [[ -z $l ]] || learners+="$name sees learner(s): $l"$'\n'
  done
  first=${etcd_ok[0]}
  member_names=$(jq -r '[.members[] | "\(.name)=\(.ID)"] | join(" ")' <<<"${e_members[$first]}")
  if [[ -z $bad ]]; then pass "etcd.members" "all servers see the expected 3 IDs ($member_names)"
  else fail "etcd.members" "member IDs differ from expected ($want_ids)"; detail "${bad%$'\n'}"; fi
  if [[ -z $learners ]]; then pass "etcd.learners" "no member is a learner"
  else fail "etcd.learners" "learner members present"; detail "${learners%$'\n'}"; fi

  # maintenance/status: leader agreement, raftIndex spread, dbSize
  leaders=() idx_txt="" db_txt="" min="" max=""
  for name in "${etcd_ok[@]}"; do
    leaders+=("$(jq -r '.leader // "none"' <<<"${e_status[$name]}")")
    ri=$(jq -r '.raftIndex // "0"' <<<"${e_status[$name]}")
    idx_txt+="$name=$ri "
    [[ -z $min ]] || ((ri < min)) && min=$ri
    [[ -z $max ]] || ((ri > max)) && max=$ri
    db_txt+="$(jq -r --arg n "$name" '"\($n)=\((.dbSize | tonumber) / 1048576 | floor)MiB(inUse \((.dbSizeInUse // "0" | tonumber) / 1048576 | floor)MiB)"' <<<"${e_status[$name]}") "
  done
  uniq_leaders=$(printf '%s\n' "${leaders[@]}" | sort -u)
  if [[ $(wc -l <<<"$uniq_leaders") -eq 1 && " $want_ids " == *" $uniq_leaders "* ]]; then
    leader_name=$(jq -r --arg id "$uniq_leaders" '.members[] | select(.ID == $id) | .name' <<<"${e_members[$first]}")
    pass "etcd.leader" "all servers agree: $uniq_leaders ($leader_name)"
  else
    fail "etcd.leader" "servers disagree or leader unknown: $(paste -sd' ' <<<"$uniq_leaders")"
  fi
  spread=$((max - min))
  if ((spread < RAFT_INDEX_MAX_SPREAD)); then pass "etcd.raftIndex" "spread $spread < $RAFT_INDEX_MAX_SPREAD (${idx_txt% })"
  else fail "etcd.raftIndex" "spread $spread >= $RAFT_INDEX_MAX_SPREAD (${idx_txt% })"; fi
  info "etcd.dbSize" "${db_txt% }"

  # maintenance/alarm
  bad=""
  for name in "${etcd_ok[@]}"; do
    a=$(jq -r '[.alarms[]? | "\(.memberID):\(.alarm)"] | join(",")' <<<"${e_alarm[$name]}")
    [[ -z $a ]] || bad+="$name: $a"$'\n'
  done
  if [[ -z $bad ]]; then pass "etcd.alarms" "no alarms"
  else fail "etcd.alarms" "alarms raised"; detail "${bad%$'\n'}"; fi
fi

# --------------------------------------------------------------------------
# /readyz on each server (local apiserver); pick a kubectl host
# --------------------------------------------------------------------------
ktarget="" kname="" bad=""
for i in "${!server_names[@]}"; do
  r=$(rssh "${server_targets[$i]}" 'sudo -n k3s kubectl get --raw /readyz 2>&1' 2>&1)
  if [[ $r == ok ]]; then
    [[ -n $ktarget ]] || { ktarget=${server_targets[$i]}; kname=${server_names[$i]}; }
  else
    bad+="${server_names[$i]}: $(oneline "$r")"$'\n'
  fi
done
if [[ -z $bad ]]; then pass "apiserver.readyz" "ok on all ${#server_names[@]} servers"
else fail "apiserver.readyz" "not ok on some servers"; detail "${bad%$'\n'}"; fi

kc() { rssh "$ktarget" "sudo -n k3s kubectl $*"; }
kjson() { # kjson <var> <kubectl args...>: fetch JSON into <var>; return 1 if invalid
  local -n _out=$1; shift
  _out=$(kc "$@" -o json 2>&1)
  is_json "$_out"
}

# --------------------------------------------------------------------------
# Kubernetes checks (via the first server whose apiserver is ready)
# --------------------------------------------------------------------------
if [[ -z $ktarget ]]; then
  fail "kubectl" "no server apiserver is ready; Kubernetes checks skipped"
else
  info "kubectl" "queries run on $kname"

  # Nodes
  if kjson nodes get nodes; then
    total=$(jq '.items | length' <<<"$nodes")
    notready=$(jq -r '.items[] | select([.status.conditions[] | select(.type == "Ready" and .status == "True")] | length == 0) | .metadata.name' <<<"$nodes")
    ready=$(jq '[.items[] | select(.status.conditions[] | select(.type == "Ready" and .status == "True"))] | length' <<<"$nodes")
    if [[ $ready -eq $EXPECTED_NODE_COUNT && $total -eq $EXPECTED_NODE_COUNT ]]; then
      pass "nodes.ready" "$ready/$EXPECTED_NODE_COUNT Ready"
    else
      fail "nodes.ready" "$ready Ready of $total nodes (expected $EXPECTED_NODE_COUNT)${notready:+; not Ready: $(paste -sd' ' <<<"$notready")}"
    fi
    voters=$(jq -r '.items[] | select(.metadata.labels["node-role.kubernetes.io/control-plane"] == "true")
      | "\(.metadata.name)=\(([.status.conditions[] | select(.type == "EtcdIsVoter") | .status] + ["missing"])[0])"' <<<"$nodes")
    nvoters=$(grep -c '=True$' <<<"$voters")
    if [[ $nvoters -eq ${#server_names[@]} && $(wc -l <<<"$voters") -eq ${#server_names[@]} ]]; then
      pass "nodes.etcdVoter" "EtcdIsVoter=True on $nvoters/${#server_names[@]} servers"
    else
      fail "nodes.etcdVoter" "$(paste -sd' ' <<<"$voters")"
    fi
    cordoned=$(jq -r '.items[] | select(.spec.unschedulable == true) | .metadata.name' <<<"$nodes")
    if [[ -z $cordoned ]]; then pass "nodes.schedulable" "no node is cordoned"
    else fail "nodes.schedulable" "cordoned: $(paste -sd' ' <<<"$cordoned")"; fi
    versions=$(jq -r '[.items[] | "\(.metadata.name)=\(.status.nodeInfo.kubeletVersion)"] | join(" ")' <<<"$nodes")
    info "nodes.versions" "$versions"
    for role in server agent; do
      if [[ $role == server ]]; then want=$EXPECTED_SERVER_K3S_VERSION sel='== "true"'
      else want=$EXPECTED_AGENT_K3S_VERSION sel='!= "true"'; fi
      [[ -n $want ]] || continue
      # want may list several versions (space-separated) while a hop is in progress.
      off=$(jq -r --arg v "$want" ".items[] | select(.metadata.labels[\"node-role.kubernetes.io/control-plane\"] $sel)
        | select(.status.nodeInfo.kubeletVersion as \$k | (\$v | split(\" \") | index(\$k)) | not)
        | \"\(.metadata.name)=\(.status.nodeInfo.kubeletVersion)\"" <<<"$nodes")
      if [[ -z $off ]]; then pass "nodes.${role}Version" "all ${role}s on $want"
      else fail "nodes.${role}Version" "want $want; off-version: $(paste -sd' ' <<<"$off")"; fi
    done
  else
    fail "nodes" "kubectl get nodes failed: $(oneline "$nodes")"
    total=$EXPECTED_NODE_COUNT
  fi

  # Flux Kustomizations and HelmReleases
  for kind in kustomizations.kustomize.toolkit.fluxcd.io helmreleases.helm.toolkit.fluxcd.io; do
    short=${kind%%.*}
    if kjson fx get "$kind" -A; then
      n=$(jq '.items | length' <<<"$fx")
      bad=$(jq -r '.items[] | (([.status.conditions[]? | select(.type == "Ready")] + [{}])[0]) as $r
        | select($r.status != "True")
        | "\(.metadata.namespace)/\(.metadata.name): \($r.reason // "NoReadyCondition") \(($r.message // "") | .[0:150])"' <<<"$fx")
      susp=$(jq -r '[.items[] | select(.spec.suspend == true) | "\(.metadata.namespace)/\(.metadata.name)"] | join(" ")' <<<"$fx")
      if [[ -z $bad ]]; then pass "flux.$short" "$n/$n Ready"
      else fail "flux.$short" "$(grep -c . <<<"$bad")/$n not Ready"; detail "$bad"; fi
      [[ -z $susp ]] || info "flux.$short" "suspended: $susp"
    else
      fail "flux.$short" "kubectl get $kind failed: $(oneline "$fx")"
    fi
  done

  # QNAP CSI (Trident) pods
  if kjson csi get pods -n "$CSI_NAMESPACE"; then
    n=$(jq '.items | length' <<<"$csi")
    bad=$(jq -r '.items[] | select(.status.phase != "Succeeded")
      | select(.status.phase != "Running" or ([.status.containerStatuses[]? | select(.ready | not)] | length > 0))
      | "\(.metadata.name): \(.status.phase)"' <<<"$csi")
    ctrl=$(jq '[.items[] | select(.metadata.name | test("controller"))] | length' <<<"$csi")
    nodep=$(jq '[.items[] | select(.metadata.name | test("-node-"))] | length' <<<"$csi")
    if [[ -z $bad && $ctrl -ge 1 && $nodep -eq $total ]]; then
      pass "csi.pods" "$n/$n Ready in $CSI_NAMESPACE (controller=$ctrl, node=$nodep/$total)"
    else
      fail "csi.pods" "controller=$ctrl node=$nodep/$total; not Ready: $(grep -c . <<<"$bad")"
      detail "$bad"
    fi
  else
    fail "csi.pods" "kubectl get pods -n $CSI_NAMESPACE failed: $(oneline "$csi")"
  fi

  # VolumeAttachments
  if kjson va get volumeattachments; then
    att=$(jq '[.items[] | select(.status.attached == true)] | length' <<<"$va")
    notatt=$(jq -r '.items[] | select(.status.attached != true)
      | "\(.metadata.name) pv=\(.spec.source.persistentVolumeName) node=\(.spec.nodeName) \(.status.attachError.message // "")"' <<<"$va")
    # EXPECTED_VA_ATTACHED is a minimum: a lost attachment fails, while
    # transient extra ones (e.g. a codebase-brain run's work volume) are fine.
    if [[ $att -ge $EXPECTED_VA_ATTACHED && -z $notatt ]]; then
      pass "volumeAttachments" "$att attached (minimum $EXPECTED_VA_ATTACHED)"
    else
      fail "volumeAttachments" "$att attached (minimum $EXPECTED_VA_ATTACHED)"; detail "$notatt"
    fi
  else
    fail "volumeAttachments" "kubectl get volumeattachments failed: $(oneline "$va")"
  fi

  # kube-vip lease (remote clock, to avoid skew with this machine)
  lease_out=$(rssh "$ktarget" "date -u +%s; sudo -n k3s kubectl -n $VIP_LEASE_NAMESPACE get lease $VIP_LEASE_NAME -o json" 2>&1)
  remote_now=$(head -n1 <<<"$lease_out") lease=$(tail -n +2 <<<"$lease_out")
  if is_json "$lease" && [[ $remote_now =~ ^[0-9]+$ ]]; then
    holder=$(jq -r '.spec.holderIdentity // ""' <<<"$lease")
    age=$(jq -r --argjson now "$remote_now" '.spec.renewTime // empty | sub("\\.[0-9]+Z$"; "Z") | $now - fromdateiso8601' <<<"$lease")
    if [[ -n $holder && -n $age ]] && ((age <= VIP_LEASE_MAX_AGE_SECONDS)); then
      pass "vip.lease" "$VIP_LEASE_NAME held by $holder, renewed ${age}s ago"
    else
      fail "vip.lease" "$VIP_LEASE_NAME holder='${holder}' renewed ${age:-never}s ago (max ${VIP_LEASE_MAX_AGE_SECONDS}s)"
    fi
  else
    fail "vip.lease" "could not read lease $VIP_LEASE_NAMESPACE/$VIP_LEASE_NAME: $(oneline "$lease_out")"
  fi

  # Problem pods, diffed against the allow-list
  if kjson pods get pods -A; then
    problems=$(jq -r --argjson now "$now" --argjson recent "$((RECENT_RESTART_MINUTES * 60))" \
      --argjson grace "$((POD_GRACE_MINUTES * 60))" '
      def ts: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
      .items[]
      | . as $p
      | ($now - (.metadata.creationTimestamp | ts)) as $age
      | ([.status.initContainerStatuses[]?, .status.containerStatuses[]?]) as $cs
      | [ ($p | select(.status.phase == "Failed" or .status.phase == "Unknown") | .status.phase),
          ($p | select(.status.phase == "Pending" and $age > $grace) | "Pending"),
          ($cs[] | .state.waiting.reason // empty | select(test("BackOff|Err|Invalid"))),
          ($cs[] | select((.lastState.terminated.finishedAt // null) != null
                          and ($now - (.lastState.terminated.finishedAt | ts)) < $recent)
                 | "Restarted(\(.name),total=\(.restartCount))"),
          ($p | select(.status.phase == "Running" and $age > $grace
                  and ([.status.containerStatuses[]? | select(.ready | not)] | length > 0)) | "NotReady"),
          ($p | select(.metadata.deletionTimestamp != null and ($now - (.metadata.deletionTimestamp | ts)) > $grace)
              | "StuckTerminating") ]
      | unique | select(length > 0)
      | "\($p.metadata.namespace)/\($p.metadata.name) \(join(","))"' <<<"$pods")
    patterns=$(grep -Ev '^[[:space:]]*(#|$)' "$allowlist" || true)
    if [[ -n $patterns ]]; then
      unexpected=$(grep -Ev -f <(printf '%s\n' "$patterns") <<<"$problems" || true)
      allowed=$(grep -E -f <(printf '%s\n' "$patterns") <<<"$problems" || true)
    else
      unexpected=$problems allowed=""
    fi
    nall=$(jq '.items | length' <<<"$pods")
    if [[ -z $unexpected ]]; then pass "pods" "no unexpected problem pods ($nall pods checked)"
    else fail "pods" "$(grep -c . <<<"$unexpected") unexpected problem pod(s) ($nall pods checked)"; detail "$unexpected"; fi
    if [[ -n $allowed ]]; then
      summary=""
      while IFS= read -r pat; do
        c=$(grep -cE -- "$pat" <<<"$allowed" || true)
        ((c > 0)) && summary+="$pat x$c; "
      done <<<"$patterns"
      info "pods.allowlisted" "$(grep -c . <<<"$allowed") pod(s): ${summary%; }"
    fi
  else
    fail "pods" "kubectl get pods -A failed: $(oneline "$pods")"
  fi
fi

# --------------------------------------------------------------------------
# VIP from the first agent: anonymous auth is off, so 401 means the VIP works
# --------------------------------------------------------------------------
if ((${#agent_targets[@]} > 0)); then
  code=$(rssh "${agent_targets[0]}" "curl -sk -o /dev/null -w '%{http_code}' --max-time 5 '$VIP_URL'" 2>&1)
  if [[ $code == "$VIP_EXPECTED_HTTP" ]]; then pass "vip.readyz" "${agent_names[0]} -> $VIP_URL = HTTP $code"
  else fail "vip.readyz" "${agent_names[0]} -> $VIP_URL = $(oneline "$code") (want $VIP_EXPECTED_HTTP)"; fi
fi

# --------------------------------------------------------------------------
# Certificates on every node: nothing expiring within CERT_MIN_DAYS
# --------------------------------------------------------------------------
threshold_epoch=$(date -u -d "+$CERT_MIN_DAYS days" +%s)
threshold=$(date -u -d "@$threshold_epoch" +%Y-%m-%dT%H:%M:%SZ)
bad="" earliest=""
all_names=("${server_names[@]}" "${agent_names[@]}")
all_targets=("${server_targets[@]}" "${agent_targets[@]}")
for i in "${!all_names[@]}"; do
  name=${all_names[$i]} target=${all_targets[$i]}
  # The table layout differs between k3s minors (1.32: CERTIFICATE SUBJECT
  # STATUS EXPIRES with ISO dates; 1.35: FILENAME ... EXPIRES ... STATUS with
  # "Oct 04, 2027 01:39 UTC"), so locate columns by header name. Columns are
  # separated by two or more spaces.
  rows=$(rssh "$target" 'sudo -n k3s certificate check --output table 2>/dev/null' 2>&1 |
    awk -F' {2,}' '
      { sub(/ +$/, "") }
      /EXPIRES/ && /STATUS/ { for (i = 1; i <= NF; i++) col[$i] = i; n = NF; next }
      n && NF >= n && $1 !~ /^-+$/ { print $col["EXPIRES"] "|" $col["STATUS"] "|" $1 }')
  if [[ -z $rows ]]; then bad+="$name: no parsable output from 'k3s certificate check'"$'\n'; continue; fi
  min_epoch="" min_txt=""
  while IFS='|' read -r exp status file; do
    if ! e=$(date -u -d "$exp" +%s 2>/dev/null); then bad+="$name: $file unparsable expiry '$exp'"$'\n'; continue; fi
    if [[ -z $min_epoch ]] || ((e < min_epoch)); then min_epoch=$e min_txt=$(date -u -d "@$e" +%Y-%m-%d); fi
    if [[ $status != OK ]] || ((e < threshold_epoch)); then bad+="$name: $file $status expires $exp"$'\n'; fi
  done <<<"$rows"
  earliest+="$name=$min_txt "
done
if [[ -z $bad ]]; then pass "certificates" "nothing expires before $threshold (earliest: ${earliest% })"
else fail "certificates" "certificates expiring before $threshold or not OK"; detail "$(sort -u <<<"${bad%$'\n'}")"; fi

# --------------------------------------------------------------------------
if ((fails == 0)); then
  echo "RESULT: PASS ($checks checks)"
  exit 0
fi
echo "RESULT: FAIL ($fails of $checks checks failed)"
exit 1
