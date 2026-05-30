# Plex Media Server — NAS Mount, Ingress, and DNS Design

**Date:** 2026-05-30
**Status:** Approved

---

## Overview

Set up `styx` as a Plex Media Server with media sourced from the QNAP NAS MEDIA share (1.19 TB) over NFS. Expose the Plex UI externally via Traefik on `management-hub` at `media.nwlnexus.io`, with local clients resolved directly to `management-hub`'s LAN IP via a Unifi DNS policy (no hairpin NAT). External DNS kept current by `ddclient` via a DNS-only Cloudflare A record (no Cloudflare proxy so media streams to the real public IP).

---

## Architecture

```
External clients
  │
  ▼ media.nwlnexus.io  (Cloudflare DNS-only A record → public IP)
  │ ddclient on management-hub keeps this current
  │
  ▼ Public IP → Unifi UDM SE (port-forwards 443 → management-hub LAN IP)
  │
  ▼ management-hub Traefik (IngressRoute, TLS via cert-manager/Let's Encrypt)
  │
Local clients
  │
  ▼ media.nwlnexus.io  (Unifi DNS policy → management-hub LAN IP, TTL 300s)
  │ Managed via Unifi API from management-hub pull playbook
  │ Same Traefik path, no hairpin NAT
  │
  ▼ styx:32400 via Tailscale IP 100.72.84.56
  │ (Tailscale direct-connects on same LAN — physically stays on-network)
  │
  ▼ /mnt/media  (NFS mount → QNAP 192.168.251.2:/MEDIA)
```

**Port forward to add manually on Unifi:** 443 → management-hub LAN IP (may already exist).

---

## Components

### 1. `nas-media-mount` role (new, olympus-infra)

Mounts the QNAP MEDIA share on styx via NFS using systemd units.

**What it does:**
- Fetches NAS host from `op://Dev/nas-media-share/host` using the established `op read` + service account token pattern (token at `/etc/olympus/op-service-account-token`)
- Installs `nfs-common`
- Drops two systemd units:
  - `/etc/systemd/system/mnt-media.mount` — mounts `{nas_host}:/MEDIA` → `/mnt/media`, options `nfsvers=4,hard,_netdev,rsize=1048576,wsize=1048576,timeo=600,retrans=2`
  - `/etc/systemd/system/mnt-media.automount` — wraps the mount unit; systemd retries on next access after network blips rather than leaving a dead mount

**Defaults:**
```yaml
nas_media_mount_state: present
nas_media_mount_point: /mnt/media
nas_media_mount_share: /MEDIA
nas_media_op_token_file: /etc/olympus/op-service-account-token
nas_media_op_nas_host_ref: "op://Dev/nas-media-share/host"
```

**styx host_vars additions:**
```yaml
nas_media_mount_state: present
```

---

### 2. `plex` role (new, olympus-infra)

Installs and manages the native `plexmediaserver` Debian package on styx.

**What it does:**
1. Adds Plex GPG key and apt repository (`https://downloads.plex.tv/repo/deb`)
2. Installs `plexmediaserver`
3. Creates `/tmp/plexmedia` owned `plex:plex` mode `0755`
4. Drops `/etc/tmpfiles.d/plexmedia.conf` so the transcoding directory is recreated on every boot (`/tmp` is tmpfs, wiped on reboot)
5. Enables and starts `plexmediaserver` service
6. Adds UFW rule: allow `32400/tcp` from `100.64.0.0/10` (Tailscale CGNAT range) — management-hub reaches styx via Tailscale direct connection, physically on-LAN

**Defaults:**
```yaml
plex_state: present
plex_transcoding_dir: /tmp/plexmedia
plex_ufw_tailscale_src: "100.64.0.0/10"
```

**styx host_vars additions:**
```yaml
plex_state: present
```

**Post-install manual step:** Once the pull runs, open `http://styx-lan-ip:32400/web` locally (or via SSH tunnel) to complete the Plex setup wizard. Set the Transcoding directory to `/tmp/plexmedia` and add `/mnt/media` as a library source in the Plex UI.

---

### 3. `unifi-dns` role (new, olympus-infra)

Idempotently manages a Unifi DNS Policy so local clients resolve `media.nwlnexus.io` to management-hub's LAN IP without leaving the network.

**What it does:**
1. Fetches Unifi API key (`op://Dev/unifi-api/credential`) and UDM host (`op://Dev/unifi-api/host`) from 1Password
2. `GET /v1/sites` → extracts `siteId` where `name == "default"`
3. `GET /v1/sites/{siteId}/dns/policies` → searches for `domain == "media.nwlnexus.io"`
4. If not found → `POST /v1/sites/{siteId}/dns/policies` (create)
5. If found and `ipv4Address` differs → `PUT /v1/sites/{siteId}/dns/policies/{id}` (update)
6. If found and matches → no-op (idempotent)

The `ipv4Address` is resolved at run time from `ansible_facts['default_ipv4']['address']` (management-hub's current LAN IP). Runs on every pull so it self-heals if the IP changes.

**API details:**
- Auth header: `X-API-KEY: {api_key}`
- Base URL: `https://{udm_host}/proxy/network/v2/api`
- Policy body:
  ```json
  {
    "type": "A_RECORD",
    "enabled": true,
    "domain": "media.nwlnexus.io",
    "ipv4Address": "<management-hub-lan-ip>",
    "ttlSeconds": 300
  }
  ```

**Defaults:**
```yaml
unifi_dns_state: present
unifi_dns_op_token_file: /etc/olympus/op-service-account-token
unifi_dns_op_credential_ref: "op://Dev/unifi-api/credential"
unifi_dns_op_host_ref: "op://Dev/unifi-api/host"
unifi_dns_site_name: default
unifi_dns_policies: []
# Each entry: { domain, type, ttlSeconds }
# ipv4Address is always resolved from ansible_facts at run time
```

**management-hub group_vars addition:**
```yaml
unifi_dns_state: present
unifi_dns_policies:
  - domain: media.nwlnexus.io
    type: A_RECORD
    ttlSeconds: 300
```

---

### 4. `ddclient` role extension + management-hub config

The existing `ddclient` role supports a single zone per config block and `ddclient_extra_fqdns` only for internal-IP records in that same zone. `media.nwlnexus.io` is in a different zone (`nwlnexus.io` vs the default `nwlnexus.net`) and needs a public IP (ipify) record. The role requires a small extension:

**Extension:** Add `ddclient_extra_public_records: []` — a list of `{ fqdn, zone }` entries. The template gains a second protocol block per unique extra zone, using the same DNS-only Cloudflare token, sourcing from ipify.

**Template addition (ddclient.conf.j2):**
```jinja2
{% for record in ddclient_extra_public_records %}
# Extra public record: {{ record.fqdn }}
protocol=cloudflare
zone={{ record.zone }}
ttl={{ ddclient_ttl }}
login=token
password='{{ _ddclient_cf_token }}'
use=web, web=https://api.ipify.org/
{{ record.fqdn }}

{% endfor %}
```

**management-hub group_vars addition:**
```yaml
ddclient_extra_public_records:
  - fqdn: media.nwlnexus.io
    zone: nwlnexus.io
```

---

### 5. Playbook changes (olympus-infra)

**`playbooks/pull/styx.yml`** — add roles:
```yaml
roles:
  - role: baseline
  - role: nas-media-mount      # new
  - role: plex                 # new
  - role: hermes-classify-include
```

**`playbooks/pull/management-hub.yml`** — add role:
```yaml
roles:
  - role: baseline
  - role: unifi-dns            # new
  - role: 1password-connect
  - role: hermes-classify-include
```

---

### 6. olympus-gitops — `apps/media/` (new namespace)

Four manifests in `apps/media/`:

**`namespace.yaml`**
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: media
```

**`plex-external-service.yaml`** — selector-less Service + Endpoints pointing at styx's Tailscale IP (direct LAN connection via WireGuard, no DERP relay since both hosts are on same network):
```yaml
apiVersion: v1
kind: Service
metadata:
  name: plex-styx
  namespace: media
spec:
  ports:
    - port: 32400
      targetPort: 32400
---
apiVersion: v1
kind: Endpoints
metadata:
  name: plex-styx
  namespace: media
subsets:
  - addresses:
      - ip: 100.72.84.56    # styx Tailscale IP
    ports:
      - port: 32400
```

**`plex-certificate.yaml`**
```yaml
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
    name: letsencrypt         # existing ClusterIssuer
    kind: ClusterIssuer
```

**`plex-ingressroute.yaml`**
```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: plex
  namespace: media
spec:
  entryPoints:
    - websecure
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
---
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: plex-real-ip
  namespace: media
spec:
  headers:
    customRequestHeaders:
      X-Forwarded-For: ""      # let Traefik populate from real client IP
      X-Real-Ip: ""
```

*(ClusterIssuer name and entryPoint name to be confirmed against existing olympus-gitops conventions)*

---

## 1Password Items

All items already exist and are populated:

| Reference | Purpose |
|---|---|
| `op://Dev/nas-media-share/host` | QNAP NAS LAN IP/hostname |
| `op://Dev/unifi-api/credential` | Unifi API key |
| `op://Dev/unifi-api/host` | UDM SE LAN IP |

---

## Sequence of Work

1. `nas-media-mount` role + styx host_vars + styx pull playbook
2. `plex` role + styx host_vars
3. Trigger styx ansible-pull → verify mount and service
4. Manual: complete Plex setup wizard, set transcoding dir, add `/mnt/media` library
5. `unifi-dns` role + management-hub group_vars + management-hub pull playbook
6. ddclient config update on management-hub
7. Trigger management-hub ansible-pull → verify DNS policy + ddclient record
8. olympus-gitops `apps/media/` manifests → Flux reconciles
9. Verify `media.nwlnexus.io` resolves and streams correctly from external + local clients

---

## Open Items

- Confirm ClusterIssuer name and `websecure` entryPoint name in olympus-gitops before writing manifests
- Port forward 443 → management-hub on Unifi (manual, if not already present)
- Plex setup wizard must be completed manually after first pull run: set transcoding dir to `/tmp/plexmedia`, add `/mnt/media` as library source
