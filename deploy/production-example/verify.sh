#!/usr/bin/env bash
# Run FROM THE MCP VM after deploying. Proves the isolation actually holds.
#
#   ./verify.sh <proxy-url> <direct-solr-url> [mcp-url]
#   ./verify.sh http://solr-vm:8984 http://solr-vm:8983 http://localhost:8080
#
# The important check is #3: the MCP host must NOT be able to reach Solr directly.
# Without it the proxy is advisory only.
set -u
PROXY=${1:?usage: verify.sh <proxy-url> <direct-solr-url> [mcp-url]}
DIRECT=${2:?usage: verify.sh <proxy-url> <direct-solr-url> [mcp-url]}
MCP=${3:-}
fail=0
ok()   { echo "ok    $*"; }
bad()  { echo "FAIL  $*"; fail=1; }

code=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "$PROXY/solr/admin/collections?action=LIST")
[ "$code" = 200 ] && ok "1. proxy answers a read (LIST -> 200)" || bad "1. proxy read returned $code (want 200)"

code=$(curl -s -o /dev/null -m 10 -w '%{http_code}' -XPOST -H 'Content-Type: application/json' "$PROXY/solr/admin/collections?action=CREATE&name=zz_verify" -d '[]')
[ "$code" = 403 ] && ok "2. proxy refuses a write (-> 403)" || bad "2. proxy write returned $code (want 403)"

code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$DIRECT/solr/admin/info/system")
if [ "$code" = 000 ]; then ok "3. direct Solr is NOT reachable from this host (the isolation holds)"
else bad "3. direct Solr answered HTTP $code from this host: the MCP can bypass the proxy. Fix the firewall."; fi

if [ -n "$MCP" ]; then
  code=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "$MCP/actuator/health")
  [ "$code" = 200 ] && ok "4. MCP server healthy" || bad "4. MCP health returned $code"

  H=(-H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream')
  body=$(curl -s -m 10 -X POST "$MCP/mcp" "${H[@]}" -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"search","arguments":{"collection":"x","query":"*:*"}}}')
  if echo "$body" | grep -q "Access Denied" && ! echo "$body" | grep -q numFound; then ok "5. an unauthenticated tool call is denied"
  else bad "5. unauthenticated tool call was NOT denied: ${body:0:120}"; fi

  tools=$(curl -s -m 10 -X POST "$MCP/mcp" "${H[@]}" -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}')
  if echo "$tools" | grep -qE '"name" *: *"(index-|add-field|create-)'; then bad "6. write tools are still listed (is SOLR_MCP_READ_ONLY=true set?)"
  else ok "6. no write tools are listed"; fi
fi

[ $fail = 0 ] && echo "ALL PASSED" || { echo "FAILURES"; exit 1; }
