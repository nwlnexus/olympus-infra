#!/usr/bin/env python3
"""End-to-end offline plan test for roles/cloudflare-access.

Runs the real role (tests/cloudflare-access/plan.yml) against a small stateful fake of the Cloudflare API
on 127.0.0.1 and records every request (method, path, raw JSON body) and every `op` invocation (the role's
op command is replaced by a shell that only appends its arguments to a file). No network, no token, no
1Password: every id, AUD and "secret" below is a placeholder made up by the fake.

  python3 tests/cloudflare-access/plan_test.py            # check (CI)
  python3 tests/cloudflare-access/plan_test.py --record F --roles-path DIR
                                                          # write the memory-only fixture from the role in DIR

The fixture fixtures/memory-origin-main.json holds the requests the role made for the memory application
before it managed several applications (recorded from that version of the role). The check runs the same
scenarios with only the memory entry in cloudflare_access_applications and requires the very same requests,
byte for byte, then plans the default list (memory + k8s-mcp + cluster-mcp) and checks the second and third applications, and the MCP
server and portal lists (olympus-sdk#929) from the state the single-portal configuration left.
"""

import argparse
import copy
import json
import os
import subprocess
import sys
import tempfile
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
FIXTURE = os.path.join(HERE, "fixtures", "memory-origin-main.json")
ACCT = "0000000000000000000000000000000a"
OTHER_RULE = {"hostname": "other.nwlnexus.net", "service": "http://other.other:80"}
CATCH_ALL = {"service": "https://traefik.traefik.svc.cluster.local:443", "originRequest": {"noTLSVerify": True}}

INITIAL_STATE = {
    "service_tokens": [],
    "policies": [
        {"id": "pol-moneta", "name": "moneta-allow", "decision": "allow",
         "include": [{"everyone": {}}], "exclude": [], "require": []},
    ],
    "apps": [{"id": "app-moneta", "aud": "aud-moneta", "name": "moneta", "type": "self_hosted",
              "domain": "moneta.example.invalid"}],
    "tunnels": [{"id": "tun-1", "name": "compute-hub"}],
    "tunnel_config": {"ingress": [OTHER_RULE, CATCH_ALL], "warp-routing": {"enabled": False}},
    "zones": [{"id": "zone-1", "name": "nwlnexus.io"}],
    "dns": [],
    "mcp_servers": [],
    "mcp_portals": [],
}


class FakeCloudflare:
    """Just enough of the API the role uses. Ids are derived from names, so they do not depend on order."""

    def __init__(self):
        self.state = copy.deepcopy(INITIAL_STATE)
        self.log = []

    def handle(self, method, raw_path, body_raw):
        url = urllib.parse.urlsplit(raw_path)
        path = url.path
        prefix = "/client/v4"
        assert path.startswith(prefix), path
        path = path[len(prefix):]
        query = dict(urllib.parse.parse_qsl(url.query))
        body = json.loads(body_raw) if body_raw else None
        status, result = self.route(method, path.strip("/").split("/"), query, body)
        self.log.append({"method": method, "path": raw_path[len(prefix):], "body": body_raw, "status": status})
        return status, {"success": status == 200, "errors": [], "messages": [], "result": result}

    def route(self, method, p, q, body):
        s = self.state
        if p[:2] == ["accounts", ACCT]:
            r = p[2:]
            if r == ["access", "service_tokens"] and method == "GET":
                return 200, [{k: v for k, v in t.items() if k != "client_secret"} for t in s["service_tokens"]]
            if r == ["access", "service_tokens"] and method == "POST":
                tok = {"id": "tok-" + body["name"], "name": body["name"], "client_id": "cid-" + body["name"] + ".access",
                       "client_secret": "fake-secret-" + body["name"], "duration": body.get("duration"),
                       "expires_at": "2027-11-11T00:00:00Z"}
                s["service_tokens"].append(tok)
                return 200, tok
            if len(r) == 4 and r[:2] == ["access", "service_tokens"] and r[3] in ("refresh", "rotate"):
                tok = next(t for t in s["service_tokens"] if t["id"] == r[2])
                return 200, dict(tok, client_secret="fake-rotated-" + tok["name"]) if r[3] == "rotate" else tok
            if r == ["access", "policies"] and method == "GET":
                return 200, s["policies"]
            if r == ["access", "policies"] and method == "POST":
                pol = dict(body, id="pol-" + body["name"])
                s["policies"].append(pol)
                return 200, pol
            if len(r) == 3 and r[:2] == ["access", "policies"] and method == "PUT":
                s["policies"] = [dict(body, id=r[2]) if x["id"] == r[2] else x for x in s["policies"]]
                return 200, dict(body, id=r[2])
            if r == ["access", "apps"] and method == "GET":
                d = q.get("domain")
                return 200, [a for a in s["apps"] if d is None or a.get("domain") in (d, d + "/*")]
            if r == ["access", "apps"] and method == "POST":
                app = dict(body, id="app-" + body["name"], aud="aud-" + body["name"])
                s["apps"].append(app)
                return 200, app
            if len(r) == 3 and r[:2] == ["access", "apps"] and method == "PUT":
                cur = next(a for a in s["apps"] if a["id"] == r[2])
                new = dict(body, id=r[2], aud=cur["aud"])
                s["apps"] = [new if a["id"] == r[2] else a for a in s["apps"]]
                return 200, new
            if r == ["access", "organizations"] and method == "GET":
                return 200, {"auth_domain": "example-team.cloudflareaccess.com", "name": "example-team"}
            if r == ["cfd_tunnel"] and method == "GET":
                return 200, [t for t in s["tunnels"] if t["name"] == q.get("name")]
            if len(r) == 3 and r[0] == "cfd_tunnel" and r[2] == "configurations":
                if method == "PUT":
                    s["tunnel_config"] = body["config"]
                return 200, {"tunnel_id": r[1], "version": 1, "config": s["tunnel_config"]}
            if r[:4] == ["access", "ai-controls", "mcp", "servers"] or r[:4] == ["access", "ai-controls", "mcp", "portals"]:
                key = "mcp_servers" if r[3] == "servers" else "mcp_portals"
                if len(r) == 4 and method == "GET":
                    return 200, s[key]
                if len(r) == 4 and method == "POST":
                    s[key].append(body)
                    return 200, body
                if len(r) == 5 and method == "PUT":
                    new = dict(body, id=r[4])
                    s[key] = [new if x["id"] == r[4] else x for x in s[key]]
                    return 200, new
        if p == ["zones"] and method == "GET":
            return 200, [z for z in s["zones"] if z["name"] == q.get("name")]
        if len(p) == 3 and p[0] == "zones" and p[2] == "dns_records":
            if method == "GET":
                return 200, [d for d in s["dns"] if d["name"] == q.get("name")]
            if method == "POST":
                rec = dict(body, id="dns-" + body["name"])
                s["dns"].append(rec)
                return 200, rec
        return 404, None


def serve(fake):
    class Handler(BaseHTTPRequestHandler):
        def _do(self):
            n = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(n).decode() if n else None
            status, payload = fake.handle(self.command, self.path, raw)
            out = json.dumps(payload).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(out)))
            self.end_headers()
            self.wfile.write(out)

        do_GET = do_POST = do_PUT = do_DELETE = do_PATCH = _do

        def log_message(self, *args):
            pass

    httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    return httpd


def run_play(port, extra, roles_path, check=False, expect_fail=False):
    """One ansible-playbook run of plan.yml; returns (stdout, op lines)."""
    with tempfile.NamedTemporaryFile("r", suffix=".op", delete=False) as oplog:
        op_path = oplog.name
    env = dict(os.environ, CFA_FAKE_API="http://127.0.0.1:%d/client/v4" % port, CFA_OP_LOG=op_path,
               ANSIBLE_CONFIG=os.path.join(REPO, "ansible.cfg"), ANSIBLE_ROLES_PATH=roles_path,
               ANSIBLE_NOCOLOR="1", ANSIBLE_FORCE_COLOR="0")
    cmd = ["ansible-playbook", "-i", "localhost,", os.path.join(HERE, "plan.yml"), "-e", json.dumps(extra)]
    if check:
        cmd.append("--check")
    proc = subprocess.run(cmd, env=env, cwd=REPO, capture_output=True, text=True)
    with open(op_path) as f:
        ops = f.read().splitlines()
    os.unlink(op_path)
    if expect_fail:
        if proc.returncode == 0:
            raise SystemExit("ansible-playbook was expected to fail (%s)" % " ".join(cmd))
        return proc.stdout, ops
    if proc.returncode != 0:
        sys.stdout.write(proc.stdout + proc.stderr)
        raise SystemExit("ansible-playbook failed (%s)" % " ".join(cmd))
    return proc.stdout, ops


# Each scenario: a fresh fake, then these runs in order (state carries over between runs).
SCENARIOS = {
    "portal-on": [
        {"name": "check-fresh", "check": True, "extra": {}},
        {"name": "apply-fresh", "extra": {}},
        {"name": "apply-again", "extra": {}},
        {"name": "refresh-one-token", "extra": {"cloudflare_access_refresh_hosts": ["NWL-MBM2"]}},
    ],
    "portal-off": [
        {"name": "apply-fresh", "extra": {}},
        {"name": "apply-again", "extra": {}},
        {"name": "tunnel-off", "extra": {"cloudflare_access_tunnel_enabled": False}},
    ],
}
# The configuration before several applications and portals: the memory application, the memory MCP server and
# the owner portal holding only memory (olympus-sdk#923).
MEMORY_ONLY_MCP = {
    "cloudflare_access_mcp_servers": "{{ [cloudflare_access_mcp_memory_server] }}",
    "cloudflare_access_mcp_portals":
        "{{ [cloudflare_access_mcp_owner_portal | combine({'servers': [{'server_id': 'memory'}]})] }}",
}
MEMORY_ONLY = dict({"cloudflare_access_applications": "{{ [cloudflare_access_memory_app] }}"}, **MEMORY_ONLY_MCP)


def run_scenario(name, roles_path, base_extra, runs=None):
    fake = FakeCloudflare()
    httpd = serve(fake)
    out = {}
    try:
        for run in runs or SCENARIOS[name]:
            start = len(fake.log)
            extra = dict(base_extra, cloudflare_access_mcp_portal_enabled=(name == "portal-on"), **run["extra"])
            stdout, ops = run_play(httpd.server_address[1], extra, roles_path, run.get("check", False),
                                   run.get("expect_fail", False))
            out[run["name"]] = {"requests": fake.log[start:], "op": ops, "stdout": stdout}
    finally:
        httpd.shutdown()
    return out, fake.state


FAILURES = []


def check(cond, msg, detail=None):
    print(("ok:   " if cond else "FAIL: ") + msg)
    if not cond:
        FAILURES.append(msg)
        if detail is not None:
            print("      " + json.dumps(detail, indent=1)[:4000].replace("\n", "\n      "))


def writes(reqs):
    return [r for r in reqs if r["method"] != "GET"]


def bodies(reqs, method, path_end):
    return [json.loads(r["body"]) for r in reqs if r["method"] == method and r["path"].split("?")[0].endswith(path_end)]


def test_memory_unchanged(roles_path):
    with open(FIXTURE) as f:
        fixture = json.load(f)
    for name in SCENARIOS:
        got, _ = run_scenario(name, roles_path, MEMORY_ONLY)
        for run in SCENARIOS[name]:
            want, have = fixture[name][run["name"]], got[run["name"]]
            check(have["requests"] == want["requests"],
                  "memory_unchanged[%s/%s]: same %d API requests (method, path, raw body) as before"
                  % (name, run["name"], len(want["requests"])),
                  {"want": want["requests"], "have": have["requests"]})
            check(have["op"] == want["op"], "memory_unchanged[%s/%s]: same %d op invocations"
                  % (name, run["name"], len(want["op"])), {"want": want["op"], "have": have["op"]})
            check(all(r["status"] == 200 for r in have["requests"]),
                  "memory_unchanged[%s/%s]: every request is one the fake knows" % (name, run["name"]))


def test_two_applications(roles_path):
    with open(FIXTURE) as f:
        fixture = json.load(f)
    # The application list as before #929 (one MCP server and portal); the MCP lists are test_mcp_lists'.
    got, state = run_scenario("portal-on", roles_path, MEMORY_ONLY_MCP)
    fresh, again = got["apply-fresh"]["requests"], got["apply-again"]["requests"]
    mem = fixture["portal-on"]["apply-fresh"]["requests"]
    k8s_rule = {"hostname": "k8s-mcp.nwlnexus.io", "service": "http://k8s-mcp.atlas-system.svc.cluster.local:80"}
    mem_rule = {"hostname": "memory.nwlnexus.io", "service": "http://memory-gateway.memory.svc.cluster.local:80"}

    # (a) with both applications, every memory request is still made, in order, unchanged; only the one
    # tunnel configuration write differs, by the k8s-mcp rule right after memory's.
    tunnel_put = [r for r in mem if r["method"] == "PUT" and r["path"].endswith("/configurations")]
    mem_rest = [r for r in mem if r not in tunnel_put]
    it = iter(fresh)
    check(all(any(r == x for x in it) for r in mem_rest),
          "two_apps_memory_requests_kept: the %d other memory requests appear unchanged and in order" % len(mem_rest))
    new_put = bodies(fresh, "PUT", "/configurations")
    old_cfg = json.loads(tunnel_put[0]["body"])["config"]
    want_cfg = dict(old_cfg, ingress=old_cfg["ingress"][:1] + [k8s_rule] + old_cfg["ingress"][1:])
    check(new_put == [{"config": want_cfg}], "two_apps_tunnel_single_write: one PUT, k8s-mcp rule after memory's",
          new_put)

    # (b) the k8s-mcp application.
    pols = bodies(fresh, "POST", "/access/policies")
    k8s_pols = [p for p in pols if p["name"].startswith("k8s-mcp-")]
    check(k8s_pols == [{"name": "k8s-mcp-allow-owner", "decision": "allow",
                        "include": [{"email": {"email": "owner@example.invalid"}}], "exclude": [], "require": []}],
          "k8s_mcp_policies: exactly one reusable policy, k8s-mcp-allow-owner (Allow, owner)", k8s_pols)
    apps = [a for a in bodies(fresh, "POST", "/access/apps") if a.get("domain") == "k8s-mcp.nwlnexus.io"]
    check(len(apps) == 1, "k8s_mcp_app: one Access application created for k8s-mcp.nwlnexus.io", apps)
    if apps:
        a = apps[0]
        dcr = a["oauth_configuration"]["dynamic_client_registration"]
        check(a["name"] == "k8s-mcp" and a["type"] == "self_hosted"
              and a["destinations"] == [{"type": "public", "uri": "k8s-mcp.nwlnexus.io"}]
              and a["policies"] == [{"id": "pol-k8s-mcp-allow-owner", "precedence": 1}]
              and a["oauth_configuration"]["enabled"] and dcr["enabled"]
              and dcr["allowed_uris"] == []
              and dcr["allow_any_on_localhost"] is False and dcr["allow_any_on_loopback"] is False,
              "k8s_mcp_app_body: self-hosted, bare host, allow-owner only, Managed OAuth, no direct claude.ai "
              "(no redirect URIs without the portal callbacks)", a)
    dns = [d for d in bodies(fresh, "POST", "/dns_records") if d["name"] == "k8s-mcp.nwlnexus.io"]
    check(len(dns) == 1 and dns[0]["type"] == "CNAME" and dns[0]["content"] == "tun-1.cfargotunnel.com"
          and dns[0]["proxied"] is True, "k8s_mcp_dns: one proxied CNAME to the tunnel", dns)

    # (b2) the cluster-mcp application (olympus-sdk#921): origin worker, so an Access application and its
    # allow-owner policy, but neither a tunnel rule nor a DNS record (the Worker's custom domain owns it).
    cpols = [p for p in pols if p["name"].startswith("cluster-mcp-")]
    check(cpols == [{"name": "cluster-mcp-allow-owner", "decision": "allow",
                     "include": [{"email": {"email": "owner@example.invalid"}}], "exclude": [], "require": []}],
          "cluster_mcp_policies: exactly one reusable policy, cluster-mcp-allow-owner (Allow, owner)", cpols)
    capps = [a for a in bodies(fresh, "POST", "/access/apps") if a.get("domain") == "cluster-mcp.nwlnexus.io"]
    check(len(capps) == 1, "cluster_mcp_app: one Access application created for cluster-mcp.nwlnexus.io", capps)
    if capps:
        a = capps[0]
        dcr = a["oauth_configuration"]["dynamic_client_registration"]
        check(a["name"] == "cluster-mcp" and a["type"] == "self_hosted"
              and a["destinations"] == [{"type": "public", "uri": "cluster-mcp.nwlnexus.io"}]
              and a["policies"] == [{"id": "pol-cluster-mcp-allow-owner", "precedence": 1}]
              and a["oauth_configuration"]["enabled"] and dcr["enabled"]
              and dcr["allowed_uris"] == []
              and dcr["allow_any_on_localhost"] is False and dcr["allow_any_on_loopback"] is False,
              "cluster_mcp_app_body: self-hosted, bare host, allow-owner only, Managed OAuth, no direct claude.ai "
              "(no redirect URIs without the portal callbacks)", a)
    check(not any("cluster-mcp" in (r["body"] or "") for r in fresh if "/dns_records" in r["path"]),
          "cluster_mcp_no_dns: no DNS request for cluster-mcp.nwlnexus.io (origin worker)")
    check(not any("cluster-mcp" in json.dumps(r) for r in new_put),
          "cluster_mcp_no_tunnel_rule: no tunnel rule for cluster-mcp.nwlnexus.io (origin worker)", new_put)
    check(not any(r.get("hostname") == "cluster-mcp.nwlnexus.io" for r in state["tunnel_config"]["ingress"]),
          "cluster_mcp_tunnel_state: the tunnel configuration holds no cluster-mcp rule",
          state["tunnel_config"]["ingress"])

    # (e) an application with an empty service-token list gets no token objects at all.
    toks = [r for r in fresh if "/service_tokens" in r["path"] and "k8s-mcp" in (r["body"] or "")]
    check(toks == [] and not any("k8s-mcp" in o for o in got["apply-fresh"]["op"])
          and not any(p["name"] == "k8s-mcp-service-auth" for p in pols),
          "empty_service_tokens: no token, no 1Password write and no service-auth policy for k8s-mcp")

    # (c) both rules before the catch-all, in list order, and a second run writes nothing.
    check(state["tunnel_config"]["ingress"] == [mem_rule, k8s_rule, OTHER_RULE, CATCH_ALL],
          "tunnel_order: memory, k8s-mcp, the other rules, catch-all last", state["tunnel_config"]["ingress"])
    check(writes(again) == [], "idempotent: the second run makes no write for either application", writes(again))

    # (d) the portal flag still merges the memory callback URIs and leaves k8s-mcp's alone.
    mem_app = [a for a in bodies(fresh, "POST", "/access/apps") if a.get("domain") == "memory.nwlnexus.io"]
    check(mem_app and mem_app[0]["oauth_configuration"]["dynamic_client_registration"]["allowed_uris"] == [
        "https://claude.ai/*",
        "https://dash.cloudflare.com/%s/one/access-controls/ai-controls/mcp-server/oauth-callback/memory" % ACCT,
        "https://mcp.nwlnexus.io/servers-callback"], "portal_callbacks_memory: portal on merges both callbacks")
    portals = bodies(fresh, "POST", "/mcp/portals")
    check(len(portals) == 1 and [s["server_id"] for s in portals[0]["servers"]] == ["memory"],
          "portal_unchanged: the portal still holds the memory server only", portals)

    # The values the backends need, labelled per application.
    out = got["apply-again"]["stdout"]
    check('k8s-mcp: ACCESS_TEAM_DOMAIN: \\"https://example-team.cloudflareaccess.com\\"' in out
          and 'k8s-mcp: ACCESS_AUD: \\"aud-k8s-mcp\\"' in out
          and 'cluster-mcp: CF_ACCESS_TEAM_DOMAIN: \\"https://example-team.cloudflareaccess.com\\"' in out
          and 'cluster-mcp: CLUSTER_MCP_ACCESS_AUD: \\"aud-cluster-mcp\\"' in out
          and 'memory: MEMORY_ACCESS_AUD: \\"aud-memory\\"' in out,
          "backend_values: team domain and AUD printed per application", out[-3000:])


K8S_TOOLS = ["events_list", "namespaces_list", "nodes_top", "pods_get", "pods_list", "pods_list_in_namespace",
             "pods_log", "pods_top", "resources_get", "resources_list"]
CLUSTER_TOOLS = ["flux_status", "list", "status"]
MEMORY_TOOLS = ["append", "digest", "forget", "recall", "status"]
K8S_CALLBACKS = {"cloudflare_access_k8s_mcp_portal_callback_uris": [
    "https://dash.cloudflare.com/%s/one/access-controls/ai-controls/mcp-server/oauth-callback/k8s" % ACCT,
    "https://mcp-hosts.nwlnexus.io/servers-callback",
    "https://mcp.nwlnexus.io/servers-callback"]}
CLUSTER_CALLBACKS = {"cloudflare_access_cluster_mcp_portal_callback_uris": [
    "https://dash.cloudflare.com/%s/one/access-controls/ai-controls/mcp-server/oauth-callback/cluster" % ACCT,
    "https://mcp-hosts.nwlnexus.io/servers-callback",
    "https://mcp.nwlnexus.io/servers-callback"]}
CALLBACKS = dict(K8S_CALLBACKS, **CLUSTER_CALLBACKS)


def sync_tools(server_id, names):
    """What authenticating a server in the dashboard does: its tools appear on the server object."""
    def hook(state):
        for srv in state["mcp_servers"]:
            if srv["id"] == server_id:
                srv["tools"] = [{"name": n} for n in names]
    return hook


def write_paths(reqs):
    return [(r["method"], r["path"].split("?")[0].replace("/accounts/" + ACCT, "")) for r in writes(reqs)]


def test_mcp_lists(roles_path):
    """olympus-sdk#929, #921: servers [memory, k8s, cluster], portals [owner: all three, hosts: k8s + cluster]."""
    runs = [
        # The state as it is live: built by the configuration before #929, memory authenticated and curated.
        {"name": "old-apply", "extra": MEMORY_ONLY_MCP},
        {"name": "old-curate", "extra": MEMORY_ONLY_MCP, "before": sync_tools("memory", MEMORY_TOOLS)},
        {"name": "old-again", "extra": MEMORY_ONLY_MCP},
        # Without the playbook's k8s callbacks the plan warns that k8s could not authenticate.
        {"name": "hint-check", "extra": {}, "check": True},
        # The first runs with the lists (and the playbook's k8s callbacks).
        {"name": "new-check", "extra": CALLBACKS, "check": True},
        {"name": "new-apply", "extra": CALLBACKS},
        {"name": "new-again", "extra": CALLBACKS},
        # The owner authenticates k8s; nothing of it is turned off, so the re-run writes nothing.
        {"name": "k8s-synced", "extra": CALLBACKS, "before": sync_tools("k8s", K8S_TOOLS)},
        # The same for cluster (olympus-sdk#921): its tools are all on, so the re-run writes nothing either.
        {"name": "cluster-synced", "extra": CALLBACKS, "before": sync_tools("cluster", CLUSTER_TOOLS)},
        # Per-server curation in one portal only: pods_log off in hosts, still on in owner.
        {"name": "hosts-curated", "extra": dict(CALLBACKS, cloudflare_access_mcp_portals=(
            "{{ [cloudflare_access_mcp_owner_portal, cloudflare_access_mcp_hosts_portal | combine("
            "{'servers': [{'server_id': 'k8s', 'disabled_tools': ['pods_log']}]})] }}"))},
    ]
    fake = FakeCloudflare()
    httpd = serve(fake)
    got = {}
    try:
        for run in runs:
            if run.get("before"):
                run["before"](fake.state)
            start = len(fake.log)
            extra = dict(run["extra"], cloudflare_access_mcp_portal_enabled=True)
            stdout, ops = run_play(httpd.server_address[1], extra, roles_path, run.get("check", False))
            got[run["name"]] = {"requests": fake.log[start:], "stdout": stdout, "state": copy.deepcopy(fake.state)}
    finally:
        httpd.shutdown()

    check(writes(got["old-again"]["requests"]) == [], "mcp_old_state_settled: the old configuration is idempotent",
          write_paths(got["old-again"]["requests"]))
    old_portal = next(p for p in got["old-again"]["state"]["mcp_portals"] if p["id"] == "owner")

    hint = got["hint-check"]["stdout"]
    check("WARNING: " in hint and "oauth-callback/k8s" in hint and "mcp-hosts.nwlnexus.io/servers-callback" in hint
          and "WARNING: " not in got["new-check"]["stdout"],
          "mcp_callback_hint: missing k8s-mcp portal callbacks are reported; none once the playbook's are set",
          hint[-2000:])

    # The --check plan of the first run with the lists.
    out = got["new-check"]["stdout"]
    want_lines = [
        "memory-allow-owner (allow, 1 include rule(s)): unchanged",
        "MCP server memory -> https://memory.nwlnexus.io/mcp: unchanged",
        "Access app mcp-server-memory (mcp): unchanged",
        "MCP server k8s -> https://k8s-mcp.nwlnexus.io/mcp: create",
        "Access app mcp-server-k8s (mcp): create",
        "MCP server cluster -> https://cluster-mcp.nwlnexus.io/mcp: create",
        "Access app mcp-server-cluster (mcp): create",
        "MCP portal owner on mcp.nwlnexus.io (servers: memory, k8s, cluster): update (servers)",
        "Tool curation owner/memory (off: forget): applied, 5 synced tool(s)",
        "Tool curation owner/k8s (off: nothing): pending, 0 synced tool(s)",
        "Tool curation owner/cluster (off: nothing): pending, 0 synced tool(s)",
        "Access app mcp-portal-owner (mcp_portal): unchanged",
        "MCP portal hosts on mcp-hosts.nwlnexus.io (servers: k8s, cluster): create",
        "Tool curation hosts/k8s (off: nothing): pending, 0 synced tool(s)",
        "Tool curation hosts/cluster (off: nothing): pending, 0 synced tool(s)",
        "Access app mcp-portal-hosts (mcp_portal): create",
        "DNS mcp.nwlnexus.io CNAME gateway.agents.cloudflare.com (proxied): unchanged",
        "DNS mcp-hosts.nwlnexus.io CNAME gateway.agents.cloudflare.com (proxied): create",
        "memory: unchanged",
        "k8s-mcp: update (oauth_configuration)",
        "cluster-mcp: update (oauth_configuration)",
    ]
    missing = [l for l in want_lines if l not in out]
    check(missing == [] and writes(got["new-check"]["requests"]) == [],
          "mcp_check_plan: --check writes nothing and plans exactly the expected changes", missing or out[-3000:])

    # The first apply: only the k8s, cluster and hosts objects, both added to owner, the k8s-mcp and cluster-mcp
    # DCR URIs (the cluster-mcp application itself exists from the old run: origin worker, no tunnel, no DNS).
    new = got["new-apply"]["requests"]
    check(write_paths(new) == [
        ("PUT", "/access/apps/app-k8s-mcp"),
        ("PUT", "/access/apps/app-cluster-mcp"),
        ("POST", "/access/ai-controls/mcp/servers"),
        ("POST", "/access/apps"),
        ("POST", "/access/ai-controls/mcp/servers"),
        ("POST", "/access/apps"),
        ("PUT", "/access/ai-controls/mcp/portals/owner"),
        ("POST", "/access/ai-controls/mcp/portals"),
        ("POST", "/access/apps"),
        ("POST", "/zones/zone-1/dns_records")],
        "mcp_existing_state_unchanged: memory server, its app, owner app, policies and owner DNS get no write",
        write_paths(new))
    k8s_app = bodies(new, "PUT", "/access/apps/app-k8s-mcp")
    check(k8s_app and k8s_app[0]["oauth_configuration"]["dynamic_client_registration"]["allowed_uris"]
          == K8S_CALLBACKS["cloudflare_access_k8s_mcp_portal_callback_uris"]
          and k8s_app[0]["oauth_configuration"]["dynamic_client_registration"]["allow_any_on_localhost"] is False
          and k8s_app[0]["oauth_configuration"]["dynamic_client_registration"]["allow_any_on_loopback"] is False,
          "mcp_k8s_backend_dcr: the k8s-mcp application allows exactly the three portal callbacks "
          "(no claude.ai, no localhost or loopback)", k8s_app)
    cluster_app = bodies(new, "PUT", "/access/apps/app-cluster-mcp")
    check(cluster_app and cluster_app[0]["oauth_configuration"]["dynamic_client_registration"]["allowed_uris"]
          == CLUSTER_CALLBACKS["cloudflare_access_cluster_mcp_portal_callback_uris"]
          and cluster_app[0]["oauth_configuration"]["dynamic_client_registration"]["allow_any_on_localhost"] is False
          and cluster_app[0]["oauth_configuration"]["dynamic_client_registration"]["allow_any_on_loopback"] is False,
          "mcp_cluster_backend_dcr: the cluster-mcp application allows exactly the three portal callbacks "
          "(no claude.ai, no localhost or loopback)", cluster_app)
    check(bodies(new, "POST", "/mcp/servers") == [
        {"id": "k8s", "name": "k8s", "hostname": "https://k8s-mcp.nwlnexus.io/mcp", "auth_type": "oauth"},
        {"id": "cluster", "name": "cluster", "hostname": "https://cluster-mcp.nwlnexus.io/mcp",
         "auth_type": "oauth"}],
        "mcp_k8s_cluster_servers: servers k8s and cluster, OAuth, each backend's /mcp")
    apps = bodies(new, "POST", "/access/apps")
    check([a["name"] for a in apps] == ["mcp-server-k8s", "mcp-server-cluster", "mcp-portal-hosts"]
          and apps[0]["destinations"] == [{"type": "via_mcp_server_portal", "mcp_server_id": "k8s"}]
          and apps[0]["policies"] == [{"id": "pol-memory-allow-owner", "precedence": 1}]
          and apps[1]["destinations"] == [{"type": "via_mcp_server_portal", "mcp_server_id": "cluster"}]
          and apps[1]["policies"] == [{"id": "pol-memory-allow-owner", "precedence": 1}]
          and apps[2]["type"] == "mcp_portal" and apps[2]["domain"] == "mcp-hosts.nwlnexus.io"
          and apps[2]["policies"] == [{"id": "pol-memory-allow-owner", "precedence": 1}]
          and apps[2]["oauth_configuration"]["dynamic_client_registration"] == {
              "enabled": True, "allowed_uris": [], "allow_any_on_localhost": True, "allow_any_on_loopback": True},
          "mcp_new_apps: mcp apps for k8s and cluster and mcp_portal app for hosts, owner policy, Claude Code DCR only",
          apps)
    owner = bodies(new, "PUT", "/mcp/portals/owner")
    check(owner == [dict({k: v for k, v in old_portal.items() if k != "id"},
                         servers=old_portal["servers"] + [
                             {"server_id": "k8s", "on_behalf": True, "default_disabled": False},
                             {"server_id": "cluster", "on_behalf": True, "default_disabled": False}])],
          "mcp_owner_full_body: the owner PUT is the old body with k8s and cluster appended (memory curation as it was)",
          {"old": old_portal, "put": owner})
    check(old_portal["servers"][0].get("updated_tools") == [
        {"name": n, "enabled": n != "forget"} for n in MEMORY_TOOLS],
        "mcp_owner_memory_curation: memory keeps every tool on except forget", old_portal)
    hosts = bodies(new, "POST", "/mcp/portals")
    check(hosts == [{"id": "hosts", "name": "hosts", "hostname": "mcp-hosts.nwlnexus.io", "code_mode": "off",
                     "servers": [{"server_id": "k8s", "on_behalf": True, "default_disabled": False},
                                 {"server_id": "cluster", "on_behalf": True, "default_disabled": False}]}],
          "mcp_hosts_portal: hosts portal, Code Mode off, k8s and cluster (no memory)", hosts)
    dns = bodies(new, "POST", "/dns_records")
    check(dns and dns[0]["name"] == "mcp-hosts.nwlnexus.io" and dns[0]["content"] == "gateway.agents.cloudflare.com"
          and dns[0]["proxied"] is True, "mcp_hosts_dns: proxied CNAME to the portal gateway", dns)

    check(writes(got["new-again"]["requests"]) == [], "mcp_idempotent: the second run with the lists writes nothing",
          write_paths(got["new-again"]["requests"]))
    check(writes(got["k8s-synced"]["requests"]) == []
          and "Tool curation owner/k8s (off: nothing): applied" in got["k8s-synced"]["stdout"]
          and "Tool curation hosts/k8s (off: nothing): applied" in got["k8s-synced"]["stdout"],
          "mcp_shared_server_synced: k8s with nothing turned off needs no curation write in either portal",
          write_paths(got["k8s-synced"]["requests"]))
    check(writes(got["cluster-synced"]["requests"]) == []
          and "Tool curation owner/cluster (off: nothing): applied" in got["cluster-synced"]["stdout"]
          and "Tool curation hosts/cluster (off: nothing): applied" in got["cluster-synced"]["stdout"],
          "mcp_cluster_server_synced: cluster with nothing turned off needs no curation write in either portal",
          write_paths(got["cluster-synced"]["requests"]))
    cur = got["hosts-curated"]["requests"]
    hosts_put = bodies(cur, "PUT", "/mcp/portals/hosts")
    check(write_paths(cur) == [("PUT", "/access/ai-controls/mcp/portals/hosts")] and hosts_put
          and hosts_put[0]["servers"][0]["updated_tools"] == [{"name": n, "enabled": n != "pods_log"} for n in K8S_TOOLS],
          "mcp_per_server_curation: pods_log off in hosts only; owner (k8s all on, memory forget off) untouched",
          {"writes": write_paths(cur), "put": hosts_put})


def test_mcp_refusals(roles_path):
    """The role refuses an unguarded server id and a foreign DNS record on a portal host, before any write."""
    bad_id = {"cloudflare_access_mcp_servers": "{{ [cloudflare_access_mcp_memory_server, "
                                               "cloudflare_access_mcp_k8s_server | combine({'id': 'kube'})] }}",
              "cloudflare_access_mcp_portals": "{{ [cloudflare_access_mcp_owner_portal | combine("
                                               "{'servers': [{'server_id': 'memory'}, {'server_id': 'kube'}]})] }}"}
    got, _ = run_scenario("portal-on", roles_path, bad_id, [{"name": "fail", "extra": {}, "expect_fail": True}])
    check(writes(got["fail"]["requests"]) == [] and "the personal/work guard judges" in got["fail"]["stdout"],
          "mcp_unguarded_id_refused: a server id outside the guard's ids fails before any write")

    fake = FakeCloudflare()
    fake.state["dns"].append({"id": "dns-x", "name": "mcp-hosts.nwlnexus.io", "type": "A", "content": "192.0.2.1",
                              "proxied": False})
    httpd = serve(fake)
    try:
        stdout, _ = run_play(httpd.server_address[1], {"cloudflare_access_mcp_portal_enabled": True}, roles_path,
                             expect_fail=True)
    finally:
        httpd.shutdown()
    dns_writes = [r for r in writes(fake.log) if "/dns_records" in r["path"]
                  and "mcp-hosts" in (r["body"] or "") or r["path"].endswith("dns-x")]
    check(dns_writes == [] and "mcp-hosts.nwlnexus.io already has" in stdout,
          "mcp_foreign_dns_refused: an existing A record on the hosts portal host is never overwritten", dns_writes)


def test_per_app_session(roles_path):
    own = {"session_duration": "1h", "oauth_access_token_lifetime": "5m", "oauth_grant_session_duration": "24h"}
    apps = {"cloudflare_access_applications":
            "{{ [cloudflare_access_memory_app, cloudflare_access_k8s_mcp_app | combine(%s)] }}" % json.dumps(own)}
    got, _ = run_scenario("portal-off", roles_path, apps, [{"name": "apply", "extra": {}}])
    by_domain = {a.get("domain"): a for a in bodies(got["apply"]["requests"], "POST", "/access/apps")}
    k, m = by_domain.get("k8s-mcp.nwlnexus.io", {}), by_domain.get("memory.nwlnexus.io", {})
    check(k.get("session_duration") == "1h" and k.get("oauth_configuration", {}).get("grant")
          == {"access_token_lifetime": "5m", "session_duration": "24h"},
          "per_app_session_own: an entry with its own lifetimes gets them in the app body", k)
    check(m.get("session_duration") == "24h" and m.get("oauth_configuration", {}).get("grant")
          == {"access_token_lifetime": "15m", "session_duration": "336h"},
          "per_app_session_shared: an entry without them gets the shared lifetimes", m)
    got, _ = run_scenario("portal-on", roles_path, {}, [{"name": "apply", "extra": {}}])
    k = [a for a in bodies(got["apply"]["requests"], "POST", "/access/apps") if a.get("domain") == "k8s-mcp.nwlnexus.io"]
    check(k and k[0]["session_duration"] == "24h"
          and k[0]["oauth_configuration"]["grant"] == {"access_token_lifetime": "15m", "session_duration": "336h"},
          "per_app_session_default: k8s-mcp uses memory's lifetimes by default", k)


def test_portal_needs_memory(roles_path):
    only_k8s = {"cloudflare_access_applications": "{{ [cloudflare_access_k8s_mcp_app] }}"}
    got, _ = run_scenario("portal-on", roles_path, only_k8s, [{"name": "fail", "extra": {}, "expect_fail": True}])
    run = got["fail"]
    check(writes(run["requests"]) == [] and run["op"] == []
          and "the memory application the portal uses" in run["stdout"],
          "portal_needs_memory: portal on without memory fails before any write (%d request(s) made)"
          % len(run["requests"]), {"requests": run["requests"], "stdout": run["stdout"][-2000:]})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--record", help="write the memory-only fixture to this file")
    ap.add_argument("--roles-path", default=os.path.join(REPO, "roles"))
    args = ap.parse_args()
    if args.record:
        fixture = {}
        for name in SCENARIOS:
            got, _ = run_scenario(name, args.roles_path, MEMORY_ONLY)
            fixture[name] = {k: {"requests": v["requests"], "op": v["op"]} for k, v in got.items()}
        with open(args.record, "w") as f:
            json.dump(fixture, f, indent=1, sort_keys=True)
            f.write("\n")
        print("recorded", args.record)
        return
    test_memory_unchanged(args.roles_path)
    test_two_applications(args.roles_path)
    test_per_app_session(args.roles_path)
    test_portal_needs_memory(args.roles_path)
    test_mcp_lists(args.roles_path)
    test_mcp_refusals(args.roles_path)
    if FAILURES:
        raise SystemExit("%d check(s) failed" % len(FAILURES))
    print("all checks passed")


if __name__ == "__main__":
    main()
