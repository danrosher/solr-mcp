# Single host: MCP + read-only proxy, one stack per Solr cluster (blue / green)

One Linux host runs the MCP server **and** the read-only proxy. The MCP can reach Solr **only**
through the proxy. The proxy load-balances across the cluster's Solr servers. The whole stack is
repeated per cluster, so blue and green each get their own proxy, MCP and port.

```
                                       ONE HOST
 Claude users                 ┌──────────────────────────────────────────────────────────────┐
     │ HTTPS                  │  stack "blue"                                                │
     ▼                        │   solr-mcp ──link──► readonly-proxy ──upstream──► blue Solr  │
 your TLS ingress ──:8080──►  │      │ (internal)        (allowlist,              nodes 1..n │
  (separate host name         │      └──egress──► IdP    timeAllowed, LB)                    │
   per stack, or a flip)      │                                                              │
                              │  stack "green"   (same shape, own subnets and port :8081)    │
 ──────:8081──────────────►   │   solr-mcp ──link──► readonly-proxy ──upstream──► green Solr │
                              └──────────────────────────────────────────────────────────────┘
        host firewall (DOCKER-USER):  egress subnet  ──✗──►  Solr nodes :8983
```

Read [the parent README](../README.md) first for the project's single-tenant caveat. In short:
this shares one MCP among many users, which the project calls unsupported. It is only reasonable
because Solr has no per-user permissions and every caller is read-only.

## Why this layout

Solr has no authentication and existing clients must keep working, so Solr itself cannot be told to
refuse the MCP. The control has to sit on the path. On one host the difficulty is that containers
all leave through the host's single IP, so a remote firewall cannot tell the MCP from the proxy.
The fix is to make the two *different source subnets on the host* and filter there:

- **`link`** is an internal Docker network (no gateway). It is only for MCP to proxy.
- **`egress`** gives the MCP its way out, to your identity provider and OTLP collector. It has a fixed subnet.
- **`upstream`** gives the proxy its way out, to the Solr nodes. It has a different fixed subnet.

Because `link` is internal, it carries no default route. Each container therefore has exactly one
route off the host, which removes the usual ambiguity about which network a multi-homed container
exits by. A rule in Docker's `DOCKER-USER` chain then rejects *egress subnet to Solr node*. The
proxy leaves from the `upstream` subnet, so it is not matched.

## Prerequisites

- A Linux host with Docker (tested with Docker 29.9, the iptables firewall backend) and root access.
- The MCP image built from **your fork** (it needs `SOLR_MCP_READ_ONLY`); see "Build the image" in the
  parent README.
- Network access from the host to every Solr node on 8983, and to your identity provider.
- An identity provider that can issue tokens whose `aud` is the MCP's public URL.
- Docker using the **iptables** backend. With the nftables backend there is no `DOCKER-USER` chain;
  `apply.sh` will say so and refuse. The same rule is then written with `nft` (not provided here).

## 1. Plan addresses

Pick one `/24` per network per cluster. They must not overlap your LAN, the Solr nodes' network, other
Docker networks (`docker network ls`; Docker's default bridge uses 172.17.0.0/16 and compose often
172.18+), or each other.

| | blue | green |
|---|---|---|
| `LINK_SUBNET` | 10.88.10.0/24 | 10.88.20.0/24 |
| `EGRESS_SUBNET` | 10.88.11.0/24 | 10.88.21.0/24 |
| `UPSTREAM_SUBNET` | 10.88.12.0/24 | 10.88.22.0/24 |
| `MCP_PORT` (loopback) | 8080 | 8081 |
| Solr nodes | blue's IPs | green's IPs |

## 2. Put the files on the host

```bash
sudo mkdir -p /opt/solr-mcp && cd /opt/solr-mcp
# copy: compose.yaml, firewall/, verify.sh, conf/, and deploy/readonly-proxy/nginx.conf
# (compose.yaml mounts ../../readonly-proxy/nginx.conf, so keep the deploy/ tree layout, or edit that path)
cp env.blue.example env.blue;   cp env.green.example env.green
```

Edit `env.blue` and `env.green`: the image, the IdP issuer, the subnets, and the node lists. Then
edit `conf/blue-upstream.conf` and `conf/green-upstream.conf`: one `server` line per node of that
cluster.

> **Keep two lists in sync for each cluster:** the `server` lines in `conf/<cluster>-upstream.conf`
> (what the proxy may use) and `SOLR_NODES` in `env.<cluster>` (what the firewall blocks the MCP
> from). A node in the first but not the second works but is reachable directly by the MCP.

## 3. Start the stacks

```bash
docker compose -p solr-mcp-blue  --env-file env.blue  -f compose.yaml up -d
docker compose -p solr-mcp-green --env-file env.green -f compose.yaml up -d
docker ps        # four containers, all (healthy)
```

The MCP waits for its proxy to be healthy, and the proxy is healthy only once it can reach Solr. The
MCP will not start if `OAUTH2_ISSUER_URI` is unreachable.

## 4. Apply the firewall (this is the enforcement)

```bash
sudo firewall/apply.sh env.blue  --dry-run     # read what it will do
sudo firewall/apply.sh env.blue
sudo firewall/apply.sh env.green
sudo firewall/apply.sh env.blue --status       # "present" for every node
```

The script is safe to repeat, and checks that the subnet in the env file is the one Docker really
created. Rules do not survive a reboot, so persist them:

```bash
sudo cp firewall/solr-mcp-firewall@.service /etc/systemd/system/   # fix the /opt paths if you used others
sudo systemctl enable --now solr-mcp-firewall@blue solr-mcp-firewall@green
```

> `ufw` does not govern traffic that Docker forwards. Do not rely on it for this.

## 5. Verify

```bash
./verify.sh env.blue
./verify.sh env.green
```

It runs probes from throwaway containers attached to each network, so they carry the real source
subnets. A node must answer from `upstream` **and** be refused from `egress`; the first result is
what makes the second meaningful. It also checks each container's default route, that the proxy
answers reads and refuses writes, that the MCP is healthy, that an unauthenticated tool call is
denied, and that no write tools are listed. Expect `ALL PASSED`.

| If you see | It means |
|---|---|
| `IS REACHABLE from the MCP's network` | the firewall rule is missing or wrong subnet: run `apply.sh`, check `--status` |
| `is not reachable even from the proxy's network` | the node is down or not routable from this host; fix that first |
| `default route is not ...` | the networks are not as defined; check subnets and that `link` is `internal` |
| `unauthenticated tool call NOT denied` | OAuth2 is off or misconfigured: never run production with `HTTP_SECURITY_ENABLED=false` |

## 6. Expose it to users

The MCP listens on `127.0.0.1:8080` (blue) and `:8081` (green). Put your TLS reverse proxy in front.

- **Two names, both clusters always available:** `solr-blue.example.com` to 8080 and
  `solr-green.example.com` to 8081. Each is a separate MCP server to users, and each needs its own
  `aud` in the IdP (the audience is the public URL; read the exact value from
  `curl -s http://localhost:8080/.well-known/oauth-protected-resource`).
  ```bash
  claude mcp add --transport http solr-blue  https://solr-blue.example.com/mcp
  claude mcp add --transport http solr-green https://solr-green.example.com/mcp
  ```
- **One "live" name:** publish `solr.example.com` and point it at whichever stack is live. A cutover is
  an ingress change (8080 to 8081), the MCP does not change, and users do not reconfigure. The `aud`
  stays the same, but both stacks must accept it (set the same public URL's audience at your IdP).
  Both options leave you free to keep the idle cluster running or stop it.

## Operating it

**Add or remove a Solr node** (do both lists):
```bash
$EDITOR conf/blue-upstream.conf env.blue          # the server line, and SOLR_NODES
docker compose -p solr-mcp-blue --env-file env.blue -f compose.yaml exec readonly-proxy nginx -s reload
sudo firewall/apply.sh env.blue                   # adds rules for new nodes
sudo firewall/apply.sh env.blue --remove && sudo firewall/apply.sh env.blue   # if you removed one
./verify.sh env.blue
```

**Upgrade the MCP:** change `MCP_IMAGE` in the env file and re-run `compose up -d`. The proxy and firewall
are untouched.

**A Solr node dies:** the proxy notices on the next request, retries another node, and skips the dead one
for 10 seconds at a time. The first request after a failure is slow (2s connect timeout). No action is needed.

**Change the query time limit:** edit `$solr_time_allowed` in `nginx.conf` (default 5000 ms), then reload.
Queries past it return partial results; the MCP does not tell Claude (see the parent README).

**Change a subnet:** remove the rules first (`apply.sh ... --remove`), take the stack down, edit the env file,
bring it up, re-apply. A mismatch makes `apply.sh` refuse.

## Further hardening (not provided, untested)

The rule above blocks the MCP from the Solr nodes you list. A stricter policy is default-deny: reject
everything from the `egress` subnet except your IdP, collector and DNS. That also protects against a
Solr node you forgot to list. It needs the IdP's addresses, which often change, so it is left to you.
If Docker has IPv6 enabled, add equivalent `ip6tables` rules.

## What was tested, and what was not

Tested on a laptop with the demo Solr standing in for the cluster (`local-test/`):

- blue and green run side by side (different subnets and ports) and each lists 6 tools;
- each MCP's only default route is its `egress` network, and each proxy's is its `upstream` network;
- the MCP side reads through the proxy, and a write is refused with 403;
- `verify.sh` passes all checks except the unauthenticated-call one, which fails there on purpose
  because the local test turns OAuth2 off;
- `apply.sh --dry-run` prints the expected rules, refuses without root, rejects an unknown mode;
- both production compose files and env examples render cleanly.

**Not tested** (needs root and real Solr nodes):

- **the firewall rules themselves.** `apply.sh` was never run for real, and `verify.sh`'s "refused from
  the MCP" check passes locally only because the demo's networks are isolated from each other, so it
  proves nothing about iptables. Treat the first run on the real host as the test, and do not
  put it in front of users until `verify.sh` says every node is *reachable from the proxy and refused
  from the MCP*;
- the systemd unit (never started);
- real multi-node Solr and blue/green behaviour, IdP token validation, TLS ingress.
