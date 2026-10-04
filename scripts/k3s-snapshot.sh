#!/usr/bin/env bash
# k3s-snapshot.sh - take an etcd snapshot and copy it off-cluster to styx.
#
# Usage:
#   scripts/k3s-snapshot.sh <name>        e.g. scripts/k3s-snapshot.sh pre-v1.32.13
#
# 1. Runs `k3s etcd-snapshot save --name <name>` on the snapshot server.
# 2. Picks the newest /var/lib/rancher/k3s/server/db/snapshots/<name>-* file
#    (k3s appends -<node>-<unix-time>).
# 3. Ensures the destination directory on styx exists, owned by the SSH user.
# 4. Streams the file through this machine to styx (the snapshot is root-only
#    on the server; nothing is written locally), then verifies size and sha256.
# 5. Prints the styx path.
#
# Overridable through the environment:
#   K3S_SNAPSHOT_HOST  default ansible@100.97.218.87   (onode-030c31)
#   K3S_SNAPSHOT_DIR   default /var/lib/rancher/k3s/server/db/snapshots
#   STYX_HOST          default ansible@100.72.84.56    (styx)
#   STYX_DIR           default /mnt/styx-data/k3s-snapshots
#
# Exit status: 0 copied and verified, 1 failure, 2 usage error.

set -euo pipefail

usage() { sed -n '2,/^$/{s/^# \{0,1\}//;p}' "$0"; }

[[ ${1:-} == -h || ${1:-} == --help ]] && { usage; exit 0; }
[[ $# -eq 1 ]] || { usage >&2; exit 2; }
name=$1
[[ $name =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo "invalid snapshot name: $name" >&2; exit 2; }

snap_host=${K3S_SNAPSHOT_HOST:-ansible@100.97.218.87}
snap_dir=${K3S_SNAPSHOT_DIR:-/var/lib/rancher/k3s/server/db/snapshots}
styx_host=${STYX_HOST:-ansible@100.72.84.56}
styx_dir=${STYX_DIR:-/mnt/styx-data/k3s-snapshots}

ssh_opts=(-o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=10 -o LogLevel=ERROR)
die() { echo "ERROR: $*" >&2; exit 1; }

echo "==> k3s etcd-snapshot save --name $name on $snap_host"
ssh -n "${ssh_opts[@]}" "$snap_host" "sudo -n k3s etcd-snapshot save --name '$name'" 2>&1 | sed 's/^/    /'

# Newest file for this name. k3s may compress (.zip) when configured, so match
# any suffix.
src=$(ssh -n "${ssh_opts[@]}" "$snap_host" \
  "sudo -n find '$snap_dir' -maxdepth 1 -type f -name '$name-*' -printf '%T@ %p\n' | sort -n | tail -n1 | cut -d' ' -f2-")
[[ -n $src ]] || die "no snapshot file matching $snap_dir/$name-* on $snap_host"
read -r src_size src_sum < <(ssh -n "${ssh_opts[@]}" "$snap_host" \
  "sudo -n stat -c %s '$src' | tr '\n' ' '; sudo -n sha256sum '$src' | cut -d' ' -f1")
echo "    source: $src ($src_size bytes)"

base=$(basename "$src")
dest="$styx_dir/$base"

echo "==> ensuring $styx_dir on $styx_host"
ssh -n "${ssh_opts[@]}" "$styx_host" \
  "sudo -n install -d -o \"\$(id -un)\" -g \"\$(id -gn)\" -m 0750 '$styx_dir'"

echo "==> copying to $styx_host:$dest"
ssh -n "${ssh_opts[@]}" "$snap_host" "sudo -n cat '$src'" |
  ssh "${ssh_opts[@]}" "$styx_host" "umask 077; cat > '$dest.partial' && mv '$dest.partial' '$dest'"

read -r dst_size dst_sum < <(ssh -n "${ssh_opts[@]}" "$styx_host" \
  "stat -c %s '$dest' | tr '\n' ' '; sha256sum '$dest' | cut -d' ' -f1")

[[ $dst_size == "$src_size" ]] || die "size mismatch: source $src_size, styx $dst_size"
[[ $dst_sum == "$src_sum" ]] || die "sha256 mismatch between source and styx copy"

echo "==> verified: $dst_size bytes, sha256 $dst_sum"
echo "$styx_host:$dest"
