# Demo: Claude + Solr MCP through the read-only proxy

A small, self-contained catalogue to try the MCP server with Claude, with writes
blocked at the network layer.

```
Claude ──stdio──► Solr MCP server ──► nginx read-only proxy :8984 ──► Solr (not published)
                                                                       ▲
                          one-shot loader (direct, write access) ──────┘
```

| Collection | Unique key | Docs | Fields |
|---|---|---|---|
| `products` | `product_oid` | 20 | `title`, `description`, `brand`, `category` |
| `skus` | `sku_oid` | 119 | `product_oid` (link), `merchant_id`, `colour`, `size`, `price`, `currency`, `stock`, `in_stock` |

Solr is not published to the host. The only way in is the proxy, which is the point of
the demo. The loader runs inside the compose network and is the only thing that writes.

## Run it

```bash
# 1. Start Solr, load the data, start the proxy (first run pulls images; ~1 min)
docker compose -f deploy/demo/compose.yaml up -d
curl -s 'localhost:8984/solr/skus/select?q=*:*&rows=0'          # numFound: 119

# 2. Build the MCP server once (needs JDK 25)
./gradlew bootJar

# 3. Start Claude Code in this directory so it picks up .mcp.json and CLAUDE.md
cd deploy/demo && claude          # approve the "solr" server when asked
```

`run-mcp.sh` finds the jar in `build/libs/` and a JDK 25 (`$JAVA`, `$JAVA_HOME`, `PATH`, then
sdkman and the usual JVM directories). To use a specific one: `JAVA=/path/to/jdk25/bin/java claude`.
The proxy port is `PROXY_PORT` (default 8984).

**"Connection closed" / `CONNECTION_CLOSED` in Claude** means the launcher exited at startup, and
Claude hides its stderr. Run `deploy/demo/run-mcp.sh </dev/null` yourself to see the real
message (usually: no jar built, or Java older than 25).

## Things to ask

- *"What kinds of products are in the catalogue?"* - `list-collections`, `get-schema`, facets.
- *"Find waterproof jackets and tell me the cheapest in-stock SKU for each."* - searches
  `products`, then filters `skus` by `product_oid`. Claude joins the two collections itself.
- *"Which brand has the most out-of-stock SKUs?"* - needs both collections.
- *"Add a product P9999 called Test."* - should be refused with
  `Blocked by read-only proxy: ...`. Claude should report it and not retry.

`CLAUDE.md` in this directory tells Claude how the two collections relate and that the
connection is read-only. Delete it and rerun the cross-collection question to see how much
that guidance matters.

## Two layers

1. **Proxy (enforcement).** Writes are refused at the network layer whatever the client does.
2. **`SOLR_MCP_READ_ONLY=true` (tidiness).** `run-mcp.sh` sets this, and the server then never
   lists the nine write tools, in `/mcp`, in `tools/list`, or to any client. Calling one gives
   "Tool not found". It is implemented by `HiddenToolsConfiguration`, a new class that filters
   the tool list and is off unless configured. Set `SOLR_MCP_HIDDEN_TOOLS=a,b` to hide specific
   tools instead or as well. Update the list in that class if upstream adds write tools.

## Notes

- Solr version: `SOLR_IMAGE` (default `solr:9.6.1-slim`) is used for both the server and the
  loader, so they cannot drift apart. Mixing versions breaks collection creation, because the
  loader copies the `_default` schema from its own image. Example: `SOLR_IMAGE=solr:9.9.0-slim`.

- Reset: `docker compose -f deploy/demo/compose.yaml down -v`, then `up -d`.
- Change the data: edit and run `data/generate.py` (deterministic, no dependencies).
- `docker compose -f deploy/demo/compose.yaml logs readonly-proxy` shows every request the
  MCP made and which were refused.
- There is no join tool. Claude issues two queries and combines them, which is fine at this
  scale; large product-to-SKU fan-outs would need Solr-side joins or denormalising.
