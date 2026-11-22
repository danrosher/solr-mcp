# Read-only proxy for Solr

Solr has no read-only mode, and its authorization rules can only *grant* access,
so a user cannot be denied writes while anonymous clients keep them. This
directory puts an nginx allowlist between the MCP server and Solr instead.
Existing Solr clients and Solr itself are unchanged.

```
existing clients ─────────────────────────────► Solr (unchanged)
MCP server ──► nginx read-only allowlist ─────► Solr
```

Point the MCP server at the proxy: `SOLR_URL=http://<proxy>:8984/solr/`.

## What is allowed (all GET)

| Path | Used by |
|---|---|
| `/solr/{c}/select` | `search`, `get-collection-stats`, `check-health` |
| `/solr/{c}/schema` | `get-schema` |
| `/solr/{c}/admin/luke` | `get-collection-stats` |
| `/solr/{c}/admin/ping` (no `action`) | `check-health` |
| `/solr/admin/metrics` | `get-collection-stats` |
| `/solr/admin/collections?action=LIST` / `LISTALIASES` | `list-collections`, `list-aliases` |

Every `/select` also gets `timeAllowed=5000` (change `$solr_time_allowed` in `nginx.conf`). It is placed
first because Solr uses the first value of a repeated parameter, so a client cannot raise it. A query
that hits the limit returns partial results with `responseHeader.partialResults=true`, which the MCP's
`search` tool does not currently surface.

Everything else is a JSON 403. That blocks `index-*`, `add-fields`,
`add-field-types`, `create-collection`, `create-alias` and `delete-alias`.
On `/select`, `stream.*`, `shards`, `shards.qt`, `qt` and percent-encoded
parameter names are refused as well.

The list was checked against the server's real traffic (all six read tools and
the write tools, via the proxy access log), not just the source. Re-check it
after upgrading the MCP server or Solr, since new tools can add endpoints.

## Try it locally

```bash
docker compose -f compose.yaml -f deploy/readonly-proxy/compose.yaml \
  up -d solr zoo solr-readonly-proxy
deploy/readonly-proxy/test.sh            # 30 allow/deny checks against http://localhost:8984
SOLR_URL=http://localhost:8984/solr/ java -jar build/libs/solr-mcp-*.jar
```

`test.sh [proxy-url] [collection]` expects the `films` collection from
`init-solr.sh` by default.

## Production

1. Copy `upstream.example.conf` per cluster and list every Solr node (one `server` line each), and mount it at
   `/etc/nginx/solr/upstream.conf` (`nginx.conf` includes it). The
   proxy round-robins across them and retries another node when one fails (GET only, so retries
   are safe). Health is passive: a dead node costs one slow request (the 2s connect timeout) and
   is then skipped for `fail_timeout` (10s) before being retried. Hostnames resolve once at
   startup, so reload nginx if a node's address changes. The proxy itself is a single container;
   run two behind a VIP if you need it to survive a restart. Note `/admin/metrics` is node-level,
   so the cache and handler stats from `get-collection-stats` come from whichever node answers.
   Failover was tested here with a dead node next to a live one; multi-node behaviour on a real
   cluster has not been.
2. **Make the proxy the only route from the MCP server to Solr** (network
   policy, security group or firewall). Without this the control is advisory.
   From the MCP host, confirm that a direct request to Solr is refused.
3. Run one proxy and one MCP instance per Solr cluster.
4. Run `test.sh` against your own Solr, with a collection name that exists there.

## Limits

- This stops writes and admin changes. It does not stop reads of every
  collection the proxy can reach; restrict collections by tightening the
  `[A-Za-z0-9_.-]+` patterns to an explicit list.
- The MCP still advertises its write tools; they fail with a 403 message. A
  code-level read-only mode that hides them does not exist yet.
- The allowlist assumes Solr's remote streaming is off (the default).
