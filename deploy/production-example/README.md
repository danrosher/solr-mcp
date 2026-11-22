# Production example: Solr MCP + read-only proxy on VMs

Solr runs as compose on VMs with **no authentication** and existing clients must keep working.
This puts a read-only allowlist proxy next to Solr and a locked-down MCP server on a separate VM.

```
Claude users ──HTTPS──► your TLS ingress ──► solr-mcp  (HTTP mode, OAuth2)      MCP VM
                                                │  SOLR_URL=http://solr-vm:8984
                                                ▼  (firewall: 8984 only)
                                        readonly-proxy ──► Solr :8983            Solr VM(s)
                                                              ▲
                                              existing clients (unchanged, open)
```

| File | Where it runs | What it is |
|---|---|---|
| `solr-host.compose.yaml` | Solr VM | the read-only proxy (nginx), published on `:8984` |
| `mcp-host.compose.yaml` | MCP VM | the MCP server, HTTP mode, read-only, OAuth2 |
| `verify.sh` | MCP VM | proves the isolation holds |
| `local-test/` | a laptop | joins the demo stack and turns OAuth2 off, for protocol testing only |

## Choosing a layout

| Layout | Use when | Guide |
|---|---|---|
| **One host** runs MCP and proxy, a host firewall rule keeps the MCP off Solr | you have one host for this, several Solr servers, and blue/green clusters | [`single-host/`](single-host/README.md) |
| **Two hosts**: proxy beside Solr, MCP elsewhere, Solr's firewall does the enforcing | you can dedicate a host to the proxy, and Solr's firewall can see real source IPs | this file |

The rest of this file describes the two-host layout. Its image-build, IdP and user-onboarding steps apply to both.

## Read this first: the project's deployment model

The project documents the server as **single-tenant: one instance per user, with that user's own
Solr credentials**, and calls a shared instance *unsupported*
([`docs/security/deployment-model.md`](../../docs/security/deployment-model.md)). This example
deliberately shares one instance. That is only reasonable because:

- Solr has no per-user permissions to preserve, so there is no identity being shared;
- the proxy makes every caller read-only, and `timeAllowed` bounds every query;
- OAuth2 decides **who may use it**, not **what they see**: every authenticated user can read every
  collection the proxy can reach. If some collections must stay private, tighten the collection-name
  patterns in `../readonly-proxy/nginx.conf`.

If that is not acceptable, use the project's intended model instead: each user runs their own
stdio instance against the shared proxy (see "Alternative" below). It needs no ingress or IdP, but
note the stdio hang under parallel tool calls described under "Known issues".

## 1. Build the image from your fork

`SOLR_MCP_READ_ONLY` only exists in the fork (`HiddenToolsConfiguration`), so do not pull an
upstream image.

```bash
JAVA_HOME=/path/to/jdk25 ./gradlew jibDockerBuild          # local image solr-mcp:<version>
docker tag solr-mcp:latest registry.example.com/solr-mcp:1.0.0-yourtag
docker push registry.example.com/solr-mcp:1.0.0-yourtag
# or build and push in one step:  ./gradlew jib --image=registry.example.com/solr-mcp:1.0.0-yourtag
```

## 2. Solr VM

1. Copy `../readonly-proxy/upstream.example.conf`, list your Solr nodes (one `server` line each), and export
   `UPSTREAM_CONF=<your copy>`. The
   proxy round-robins and retries another node on failure. Also set `$solr_time_allowed` (default
   5000 ms; keep it below your inter-shard timeout).
2. If Solr is another compose project on this host, uncomment the `solr` network in
   `solr-host.compose.yaml` and set `SOLR_NETWORK`, so the node names resolve.
3. Start it: `docker compose -f deploy/production-example/solr-host.compose.yaml up -d`
4. **Firewall (the enforcement):** the MCP VM may reach `8984` and must not reach `8983`.
   Existing clients keep `8983` exactly as today.

### Firewall: do not trust `ufw` alone

Docker publishes ports by editing iptables directly, so **`ufw` rules do not apply to published
container ports**. Use a cloud security group or the `DOCKER-USER` chain, which Docker leaves alone:

```bash
MCP_IP=10.0.0.50
sudo iptables -I DOCKER-USER -s $MCP_IP -p tcp --dport 8983 -j DROP      # MCP VM cannot reach Solr
# 8984 stays reachable. Persist the rule (iptables-persistent / your config management).
```

A cloud security group on the Solr VM is simpler and not subject to this problem: allow `8984` from the
MCP VM, and do not allow `8983` from it.

## 3. MCP VM

```bash
export MCP_IMAGE=registry.example.com/solr-mcp:1.0.0-yourtag
export SOLR_URL=http://solr-vm:8984/solr/             # the PROXY port, never 8983
export OAUTH2_ISSUER_URI=https://idp.example.com/realms/solr
docker compose -f deploy/production-example/mcp-host.compose.yaml up -d
```

- The server must reach `OAUTH2_ISSUER_URI` at startup, or it will not start.
- It listens on `127.0.0.1:8080`. Put your TLS reverse proxy in front, or set `MCP_BIND` to a private
  interface.
- Your IdP must issue tokens whose `aud` equals the **public URL** clients use. Read the value the
  server expects from `curl -s http://localhost:8080/.well-known/oauth-protected-resource`. The
  per-IdP steps are in [`docs/security/http.md`](../../docs/security/http.md).
- Never set `HTTP_SECURITY_ENABLED=false` here.
- Point `OTEL_*_URL` at a collector, or expect a connection-refused error in the logs on every flush.

## 4. Verify (from the MCP VM)

```bash
deploy/production-example/verify.sh http://solr-vm:8984 http://solr-vm:8983 http://localhost:8080
```

All six checks should pass. Check 3 (direct Solr unreachable) matters most.

Users then connect with, for example:

```bash
claude mcp add --transport http solr https://solr-mcp.example.com/mcp
```

## Alternative: one stdio instance per user (the project's intended model)

```bash
docker run -i --rm -e SOLR_URL=http://solr-vm:8984/solr/ -e SOLR_MCP_READ_ONLY=true \
    registry.example.com/solr-mcp:1.0.0-yourtag
```

No ingress, IdP or central server. The proxy still enforces read-only. Users need Docker and network
access to `8984`.

## What was tested, and what was not

Tested locally (Jib image built from this fork, run against the demo stack):

- the image starts, passes its healthcheck, and serves HTTP;
- `tools/list` over HTTP shows 6 tools; a hidden write tool returns "Tool not found";
- 10 parallel `get-collection-stats` calls over HTTP all succeeded, followed by a normal search;
- with security on, an unauthenticated and a bogus-token tool call both return "Access Denied" and no data;
- `verify.sh` passes its checks, and fails correctly when Solr is reachable or the MCP is unauthenticated;
- the proxy's allow/deny suite and `timeAllowed` enforcement (`../readonly-proxy/test.sh`).

**Not tested**, and needing a check in your environment:

- the real firewall and `DOCKER-USER` rules (this needs two VMs);
- OAuth2 against your actual IdP, including the `aud` claim. Only the unauthenticated gate was tested;
- multi-node Solr behaviour, and proxy failover on a real cluster;
- the MCP container's hardening (`read_only`, `cap_drop`, non-root user) beyond it starting and passing its
  healthcheck. The proxy's own hardening was tested: it runs, is healthy, and passes the full suite.

## Known issues

- **stdio hangs on parallel tool calls.** The MCP SDK's stdio transport can drop a response when two
  calls finish together, and then stops answering. HTTP mode did not show it. This is why the
  central HTTP deployment is the default here.
- **Partial results are silent.** When `timeAllowed` cuts a query short, Solr flags
  `partialResults`, but the MCP's `search` result does not expose it. Claude sees fewer documents and
  no warning.
- **Tool names are visible to anyone.** The MCP handshake and `tools/list` are anonymous by design;
  only tool *calls* require a token.
