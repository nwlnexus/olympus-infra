# inference-server

llama.cpp `llama-server` on Ubuntu (systemd): one unit per model, a stall watchdog on a systemd
timer, a per-instance connection cap, and the amdgpu/TTM kernel parameters for the GEEKOM A9
(Ryzen AI Max+ 395 "Strix Halo", 128 GB unified memory). Linux twin of `roles/llama-server` (macOS,
data-hub): `inference_server_models` and `inference_server_instances` have the same shape as
`llama_server_models` / `llama_server_instances`, and `inventory/group_vars/inference_server.yml`
carries the same three instances on the same ports. `tests/inference-server` asserts the two
files stay identical.

Spec: olympus-sdk H8 (`docs/superpowers/specs/2026-10-26-agent-harness-knowledge-and-hosts-design.md`),
issue nwlnexus/olympus-sdk#568 (HW10). The A9 is a tailnet host managed by olympus-infra, not a k3s node.

## What it manages

| Piece | Where |
|---|---|
| llama.cpp build (pinned) | `/opt/olympus/llama.cpp/<tag>-<backend>/`, symlink `current` |
| GGUF models (pinned, sha256 + size) | `/opt/olympus/models/gguf/` |
| Service account `llama` (groups `video`, `render`) | system user, home `/var/cache/inference-server` |
| Instance wrapper + unit | `/usr/local/bin/inference-server-serve-<name>`, `inference-server-<name>.service` |
| Connection caps | `/etc/olympus/inference-server-limits.nft`, `inference-server-limits.service` (nftables table `olympus_inference`) |
| Watchdog | `/usr/local/bin/inference-server-watchdog`, `inference-server-watchdog.{service,timer}` |
| Kernel parameters | `/etc/default/grub.d/90-olympus-inference-server.cfg` (+ `update-grub`; never reboots) |

Tags: `inference_server_prepare` (asserts, packages, llama.cpp, models: fetches everything, touches no unit),
`inference_server_kernel` (GRUB drop-in and reboot notice), `inference-server` (the whole role, as in the pull playbook).
`inference_server_state: absent` (the default) removes units, wrappers, caps and watchdog and keeps models, builds and the GRUB drop-in.

## Vulkan or ROCm: the install choice

Default: **Vulkan**, official release binary `llama-b11795-bin-ubuntu-vulkan-x64.tar.gz` from ggml-org/llama.cpp
(sha256 `addbcd7c...8e6497`, 34,945,552 B). Variant: **ROCm**, `llama-b11795-bin-ubuntu-rocm-10.0-x64.tar.gz`
(sha256 `5fe808a9...3eb02a`, 249,832,180 B), selected with `-e inference_server_backend=rocm`.

Why prebuilt rather than a source build: ggml-org publishes both Ubuntu x64 builds for every tag; the ROCm one is built
with `GPU_TARGETS` including `gfx1151` (Strix Halo; `.github/workflows/release.yml` at b11795). A sha256-pinned download is
reproducible and takes seconds, while a source build needs a compiler, the Vulkan SDK or ROCm devel packages and ~20 minutes
of CPU, and the result is no different. The binaries have `RUNPATH=$ORIGIN`, so they run from the unpacked directory.

Version pin: tag `b11795` (2026-10-21; `llama-server --version` prints `0.7.0-dev (build 11795)`). Release tags are `bNNNN`;
the GitHub release named `v0.7.0` carries no assets. Bump `inference_server_llama_tag` and both builds' `sha256`/`size`
(GitHub shows the asset digest) together; the role moves `current` and restarts the instances.
The data-hub runs the Homebrew 0.7.0 bottle, so check the instance flags against `llama-server --help` on the host after the
first start (`inference_server_drop_flags` removes a flag the build does not know).

Host prerequisites:

- Vulkan: Ubuntu packages `libvulkan1`, `mesa-vulkan-drivers` (Mesa RADV), `vulkan-tools` (installed by the role).
- ROCm: not installed by the role. The tarball links `libamdhip64.so.7`, `libhipblas.so.3`, `librocblas.so.5` from the host
  (ROCm 7.x from AMD's apt repository under `inference_server_rocm_path`, default `/opt/rocm`); the role asserts they exist and
  puts `<path>/lib` on `LD_LIBRARY_PATH` in the wrappers. Strix Halo needs a recent kernel and ROCm; AMD lists the minimums in
  the page cited below. Choose between the two on the #530 spike numbers.

## Concurrency cap, queue and timeouts

llama-server has no queue limit of its own: `-np` sets the slots, further requests wait in an unbounded deferred queue, and its
HTTP pool can grow by up to 1024 threads (`tools/server/server-http.cpp` at b11795). So the cap is enforced by the kernel:
`inference-server-limits.service` loads an nftables rule per instance port that resets (TCP RST) a new connection once more than
`slots (-np) + queue + headroom` are open (queue default 4, per-instance `queue:` overrides; headroom 2 for watchdog probes and
scrapes). Clients such as LiteLLM then see an immediate error instead of stacking behind a long generation. The cap is
**off by default** (`inference_server_connection_limit_enabled: false`): it counts open TCP connections, not in-flight requests, so
idle keep-alive connections count against it and it can reset healthy traffic. Measure the real connection pattern from LiteLLM first,
then enable it with `inference_server_connection_limit_enabled: true`. The rules sit in their own table at hook priority -10, so ufw/nftables rules elsewhere are untouched.

Per-request timeouts are the `--timeout N` read/write seconds of each instance (900 s chat, 120 s embed, as on data-hub:
memory worker 300 s < LiteLLM 600 s < llama-server 900 s). The watchdog bounds probes with `inference_server_watchdog_probe_timeout`.

## Watchdog

`inference-server-watchdog.timer` (3 min after boot, then every 60 s) runs the oneshot service as root. Same logic as the macOS one:
`/health` 503 (loading) is fine for the 600 s cooldown; a busy chat instance must advance `llamacpp:n_decode_total` between runs
(`llamacpp:requests_processing` > 0; falls back to `/slots` `is_processing`/`n_decoded`); an idle one must answer a 4-token completion;
the embedder must return `embed_dim` values. Three failed checks or three stalled minutes, at most once per cooldown, run
`systemctl restart --no-block inference-server-<name>.service`. Logs go to the journal:

```sh
journalctl -t inference-server-watchdog -f          # WARN / HOLD / RESTART lines
journalctl -t inference-server-watchdog -p err      # RESTART <name> reason=...  (the alert hook)
```

Alert rules (HW10/#568, outside this repo) should match the journal line `RESTART <name> reason=`.

## Kernel parameters: up to 96 GB GPU-addressable memory

On Strix Halo the GPU uses system RAM through the TTM/GTT pool; the BIOS "dedicated VRAM" carve-out should stay small (0.5 GB
in AMD's guidance) and the shared limit is raised instead. The role writes a GRUB drop-in that appends
(derived from `inference_server_gpu_memory_gib: 96`, 4 KiB pages):

```text
ttm.pages_limit=25165824 ttm.page_pool_size=25165824      # 96 GiB = 25165824 x 4096 B
```

| Parameter | Value | Meaning |
|---|---|---|
| `ttm.pages_limit` | 25165824 | maximum pages the GPU can map (96 GiB of the 128 GiB) |
| `ttm.page_pool_size` | 25165824 | TTM page pool, set equal to the limit (as in the references below) |
| `amdgpu.gttsize` | not set (optional `inference_server_amdgpu_gttsize_mib: 98304`) | legacy MiB knob; deprecated in favour of `ttm.pages_limit` on current kernels (Ubuntu 26.04 ships 7.0), so off by default |

Headroom: 32 GiB stays for the OS, page cache and the CPU side. Reference points: the Lychee-Technology recipe uses 25,600,000
pages (~100 GB) on 128 GB as "stable"; a Level1Techs user used 27,648,000 (~108 GB); AMD's `amd-ttm --set 100` example writes
26,214,400 pages (100 GB). 96 GiB is the issue's target and is below all of them.

Not set by default: `amd_iommu=off` (some guides add it for a little speed; it trades away isolation, so it is a deliberate
owner decision, not a default).

Sources:

- AMD ROCm docs, "AMD Strix Halo system optimization": TTM `pages_limit` in `/sys/module/ttm/parameters/pages_limit`, counted in pages, example `amd-ttm --set 100` = 26214400 pages (100.00 GB), saved to `/etc/modprobe.d/ttm.conf`, reboot needed; keep the BIOS VRAM reservation small; minimum kernels (Ubuntu 24.04 HWE 6.17.0-19.19, OEM 6.14.0-1018, otherwise 6.18.4): <https://rocm.docs.amd.com/en/latest/how-to/system-optimization/strixhalo.html>
- Lychee-Technology/llama-cpp-for-strix-halo: `ttm.page_pool_size=25600000 ttm.pages_limit=25600000` for 128 GB, 4 KiB pages: <https://github.com/Lychee-Technology/llama-cpp-for-strix-halo>
- Framework community, "iGPU VRAM - How much can be assigned?": `amdgpu.gttsize` deprecated, assign via TTM, options in 4 KiB pages: <https://community.frame.work/t/igpu-vram-how-much-can-be-assigned/73081>
- Level1Techs, "ROCm can only use half of the unified memory on my Strix Halo": `ttm.pages_limit=27648000 ttm.page_pool_size=27648000` on 128 GB: <https://forum.level1techs.com/t/rocm-can-only-use-half-of-the-unified-memory-on-my-strix-halo/253152>

The role never reboots. When the parameters are missing from `/proc/cmdline` it prints a `REBOOT REQUIRED` notice and writes
`/var/run/reboot-required`. After the reboot:

```sh
cat /proc/cmdline | tr ' ' '\n' | grep ttm      # both parameters present
cat /sys/module/ttm/parameters/pages_limit      # 25165824
```

Fallback if the limit does not take on the running kernel: set `inference_server_amdgpu_gttsize_mib: 98304`, or move the
values to `/etc/modprobe.d/ttm.conf` (`options ttm pages_limit=25165824` and `page_pool_size`, then `update-initramfs -u`), as AMD's page describes.

## Sandboxing

Units run as `llama` with `NoNewPrivileges`, `ProtectSystem=strict`, `ProtectHome`, `PrivateTmp`, no capabilities, a
restricted surface (`RestrictAddressFamilies`, `RestrictNamespaces`, `LockPersonality`, `SystemCallArchitectures=native`) and
`DevicePolicy=closed` allowing only `char-drm` (`/dev/dri/*`), `/dev/kfd` and the basic nodes. Deliberately absent because they
break GPU access: `PrivateDevices`, `MemoryDenyWriteExecute` (drivers JIT shaders), `ProtectKernelTunables` (ROCm uses `/sys/class/kfd`).
The sandbox is checked by render tests only; on the first real start run `systemd-analyze security inference-server-qwen36-27b.service`
and watch for a GPU initialisation failure in `journalctl -u inference-server-qwen36-27b`. If one appears, the likely culprits are
`RestrictAddressFamilies` (AF_NETLINK for device enumeration) and `DeviceAllow`; loosen that single line in the unit template.

## Runbook: after the owner flashes Ubuntu 26.04

Nothing in the repo targets the box until step 3. Steps 1-2 are on the A9, 3-8 are PR and operator steps.

1. **Base OS and tailnet.** Install Ubuntu 26.04, create the `ansible` service user (key-only; the `bootstrap-user` role / push
   playbooks do this for the other Linux hosts), then join the tailnet with the `tailscale` role only: run
   `playbooks/push/bootstrap-host.yml --tags tailscale` (it comes from the separate PR `feat/567-new-onodes`; merge that first). The role
   exchanges the 1Password OAuth client for a short-lived, tagged (`tag:inference`), pre-authorized key, and `tag:inference` must already
   be in the olympus-tailnet policy. Never run `tailscale up` by hand (an untagged or wrongly tagged node is not covered by the ACLs).
   Note the tailnet address (`tailscale ip -4`). Check the kernel: `uname -r` is at least the minimum AMD lists (see above).
2. **BIOS (precondition, before step 1).** Set the UMA frame buffer to the minimum (0.5 GB, per AMD) so the OS sees about 120+ GB
   (`free -g` at least 120); the TTM parameters provide the GPU memory.
3. **Fill in the inventory** (one PR to this repo; the host name and address are the only values to add):
   - `inventory/inference-server.yml`: replace `hosts: {}` with the host (`ansible_host: 127.0.0.1`, `ansible_connection: local`).
   - `inventory/olympus.yml`, group `inference_server`: add `a9-mega` with `ansible_host: 192.168.253.15` (LAN address, push runs).
   - `inventory/group_vars/inference_server.yml`: set `inference_server_tailscale_ip` (marked `TODO`) and flip `inference_server_state` to `present`
     (a later PR, once the tailnet address is known; `ansible_pull_limit` and `tailscale_hostname` are already `a9-mega`). Merge only after `validate` is green.
4. **Prepare: the prepare tag** (installs packages, downloads llama.cpp and ~24.5 GB of GGUF, no unit touched). On the A9 as the
   `ansible` user, the same way the scheduled pull runs (the `always`-tagged pre-tasks need `/etc/olympus/op-service-account-token`
   and a Hermes token or `hermes-disabled` flag, as on every host; `baseline` and `ansible-pull` install the schedule on the first full run):
   `ansible-pull -U https://github.com/nwlnexus/olympus-infra.git -i inventory/inference-server.yml -l <a9-host-name> playbooks/pull/olympus.yml --tags inference_server_prepare`.
   Then once more with `-e inference_server_verify_checksums=true` to check every sha256.
5. **Kernel parameters.** Run the same command with `--tags inference_server_kernel` (or the full role). The play prints `REBOOT REQUIRED`.
   **Reboot the host yourself** (the role never does), then verify `/sys/module/ttm/parameters/pages_limit` is `25165824`.
6. **Start.** Run the full role (`--tags inference-server`, or let the next scheduled pull do it): it installs the wrappers, units, caps and the watchdog, starts the three
   instances, waits for `/health` 200 on each (a 27B model takes a minute or more to load) and runs the probes for the instances it started.
7. **Verify the probes** (from the A9 or any tailnet host; `<ip>` is the tailnet address):

   ```sh
   for p in 8081 8082 8083; do curl -s -o /dev/null -w "$p %{http_code}\n" http://<ip>:$p/health; done      # 200 each
   curl -s http://<ip>:8081/v1/chat/completions -H 'Content-Type: application/json' \
     -d '{"model":"qwen3.6-27b","messages":[{"role":"user","content":"ok"}],"max_tokens":4}'                  # "choices"
   curl -s http://<ip>:8083/v1/embeddings -H 'Content-Type: application/json' \
     -d '{"model":"nomic-embed-text","input":"ok"}' | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["data"][0]["embedding"]))'   # 768
   curl -s http://<ip>:8081/metrics | grep -E 'requests_processing|n_decode_total'
   systemctl list-timers inference-server-watchdog.timer; journalctl -t inference-server-watchdog -n 20
   vulkaninfo --summary | grep -i -E 'deviceName|driverName'    # RADV, gfx1151 (Vulkan backend)
   ```

   Also confirm the model fits: the llama-server load log (`journalctl -u inference-server-qwen36-27b`) reports the GPU/offloaded
   layers; `-ngl 999` must offload all of them. To exercise the watchdog, `kill -STOP` an instance and expect a `RESTART` within ~4 minutes.
8. **Spike and switch.** Run the #530 spike on this host (Vulkan first, then `-e inference_server_backend=rocm` if ROCm 7.x is installed)
   and record the engine in #530 / #568. Switching backend moves `current` and restarts the instances.

### Feeding HW11 (LiteLLM backend list, nwlnexus/olympus-sdk#569)

LiteLLM runs in the cluster and treats the A9 as the primary backend (A9 -> data-hub MLX -> Workers AI). Per instance it needs
`api_base: http://<a9-tailnet-ip>:<port>/v1` and the model alias reported by `--alias`, sent as `openai/<alias>`:

| LiteLLM alias | backend model | A9 instance | port |
|---|---|---|---|
| `memory-extract`, `coder-heavy` | `openai/qwen3.6-27b` (`extra_body.chat_template_kwargs.enable_thinking: false`) | `qwen36-27b` | 8081 |
| `coder-light` | `openai/qwen2.5-7b-instruct` | `qwen25-7b` | 8082 |
| `memory-embed` | `openai/nomic-embed-text` (768-dim) | `nomic-embed` | 8083 |

The same shape as `litellm_llama_*_instance` on data-hub (`roles/litellm`), so HW11 adds the A9 `api_base` per alias in front of
data-hub's. Set LiteLLM's per-deployment parallelism to the instance's `-np` and keep its timeout (520 s) below llama-server's 900 s;
a connection reset from the cap above is the "backend is full" signal to fail over on. The tailnet address and host name are filled
in by the owner (step 3) and live in the private olympus-sdk / gitops configuration, not in this public repo.
