#!/usr/bin/env bash
# Proves, on the one host, that the MCP can reach Solr ONLY through the proxy.
#
#   ./verify.sh env.blue          (run after `compose up` AND firewall/apply.sh)
#
# The key trick: probes run in throwaway containers attached to ONE of the stack's networks,
# so they carry exactly the source subnet the real MCP / proxy use:
#   * from the upstream network (the proxy's side)  a Solr node MUST answer     -> proves the node is up
#   * from the egress network   (the MCP's side)    the same node MUST NOT      -> proves the firewall rule
# A "blocked" result only counts because the upstream probe proved the node is reachable.
set -u
ENV_FILE=${1:?usage: verify.sh <env-file>}
[ -r "$ENV_FILE" ] || { echo "cannot read $ENV_FILE" >&2; exit 2; }
set -a; . "$ENV_FILE"; set +a
: "${CLUSTER:?}" "${SOLR_NODES:?}" "${SOLR_PORTS:?}" "${MCP_PORT:?}"
P="solr-mcp-$CLUSTER"
UPSTREAM_NET=${UPSTREAM_NET_NAME:-${P}_upstream}
IMG=${PROBE_IMAGE:-nginx:1.27-alpine}          # any image with busybox wget
fail=0
ok()  { echo "ok    $*"; }
bad() { echo "FAIL  $*"; fail=1; }
probe() { docker run --rm --network "$1" "$IMG" wget -q -T 5 -O /dev/null "$2" >/dev/null 2>&1; }
hexip() { local IFS=.; read -r a b c d <<<"$1"; printf '%02X%02X%02X%02X' "$d" "$c" "$b" "$a"; }
default_gw() { docker exec "$1" sh -c 'cat /proc/net/route' 2>/dev/null | awk '$2=="00000000"{print $3; exit}'; }

echo "== $CLUSTER: containers"
for svc in solr-mcp readonly-proxy; do
  c=$(docker ps -q --filter "label=com.docker.compose.project=$P" --filter "label=com.docker.compose.service=$svc")
  [ -n "$c" ] || { bad "$svc is not running"; continue; }
  h=$(docker inspect -f '{{.State.Health.Status}}' "$c")
  [ "$h" = healthy ] && ok "$svc healthy" || bad "$svc health is '$h'"
done

echo "== $CLUSTER: each container leaves the host by its OWN network"
mcp=$(docker ps -q --filter "label=com.docker.compose.project=$P" --filter "label=com.docker.compose.service=solr-mcp")
prx=$(docker ps -q --filter "label=com.docker.compose.project=$P" --filter "label=com.docker.compose.service=readonly-proxy")
egw=$(docker network inspect "${P}_egress" --format '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null)
ugw=$(docker network inspect "$UPSTREAM_NET" --format '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null)
[ -n "$mcp" ] && [ "$(default_gw "$mcp")" = "$(hexip "$egw")" ] && ok "MCP default route is via egress ($egw)" || bad "MCP default route is not the egress gateway ($egw)"
[ -n "$prx" ] && [ "$(default_gw "$prx")" = "$(hexip "$ugw")" ] && ok "proxy default route is via upstream ($ugw)" || bad "proxy default route is not the upstream gateway ($ugw)"

echo "== $CLUSTER: the MCP's path to Solr is the proxy, and the proxy is read-only"
out=$(docker run --rm --network "${P}_link" "$IMG" wget -q -T 5 -O - "http://readonly-proxy:8984/solr/admin/collections?action=LIST" 2>&1)
echo "$out" | grep -q '"collections"' && ok "MCP side -> proxy: read answered" || bad "MCP side -> proxy: no read answer ($out)"
out=$(docker run --rm --network "${P}_link" "$IMG" wget -q -T 5 -O - --post-data='[]' "http://readonly-proxy:8984/solr/admin/collections?action=CREATE&name=zz" 2>&1)
echo "$out" | grep -q 403 && ok "MCP side -> proxy: write refused (403)" || bad "MCP side -> proxy: write NOT refused ($out)"

echo "== $CLUSTER: direct Solr, from the proxy's network vs the MCP's network"
for node in $SOLR_NODES; do for port in $SOLR_PORTS; do
  url="http://$node:$port/solr/admin/info/system"
  if ! probe "$UPSTREAM_NET" "$url"; then bad "$node:$port is not reachable even from the proxy's network; cannot prove anything about it"; continue; fi
  if probe "${P}_egress" "$url"; then bad "$node:$port IS REACHABLE from the MCP's network: run firewall/apply.sh"
  else ok "$node:$port reachable from the proxy, refused from the MCP"; fi
done; done

echo "== $CLUSTER: the MCP server itself"
base="http://${MCP_BIND:-127.0.0.1}:$MCP_PORT"; H=(-H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream')
[ "$(curl -s -o /dev/null -m 10 -w '%{http_code}' "$base/actuator/health")" = 200 ] && ok "health 200" || bad "health is not 200"
body=$(curl -s -m 10 -X POST "$base/mcp" "${H[@]}" -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"search","arguments":{"collection":"x","query":"*:*"}}}')
if echo "$body" | grep -q "Access Denied" && ! echo "$body" | grep -q numFound; then ok "unauthenticated tool call denied"; else bad "unauthenticated tool call NOT denied: ${body:0:100}"; fi
tools=$(curl -s -m 10 -X POST "$base/mcp" "${H[@]}" -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}')
echo "$tools" | grep -qE '"name" *: *"(index-|add-field|create-)' && bad "write tools are listed" || ok "no write tools listed"

[ $fail = 0 ] && echo "ALL PASSED ($CLUSTER)" || { echo "FAILURES ($CLUSTER)"; exit 1; }
