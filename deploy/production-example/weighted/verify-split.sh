#!/usr/bin/env bash
# Sends N requests through the proxy and checks the colour split matches the weights you expect.
#
#   ./verify-split.sh env.prod "blue=120,green=90"          # expected weights (what the znode holds)
#   ./verify-split.sh env.prod "blue=120,green=90" 1000 6    # N requests, tolerance in percentage points
#
# It reads cluster=<upstream> from the proxy's access log (only method, path and status are logged,
# never query strings), so it needs no ZooKeeper access. Run it AFTER the watcher has applied the weights.
set -u
ENV_FILE=${1:?usage: verify-split.sh <env-file> "blue=120,green=90" [N] [tolerance-pct-points]}
EXPECT=${2:?expected weights}
N=${3:-500}
TOL=${4:-8}
set -a; . "$ENV_FILE"; set +a
P="solr-mcp-${CLUSTER:?}"
IMG=${PROBE_IMAGE:-nginx:1.27-alpine}
prx=$(docker ps -q --filter "label=com.docker.compose.project=$P" --filter "label=com.docker.compose.service=readonly-proxy")
[ -n "$prx" ] || { echo "FAIL  proxy is not running"; exit 1; }

start=$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)
docker run --rm --network "${P}_link" "$IMG" sh -c \
  'i=0; while [ $i -lt '"$N"' ]; do wget -q -T 5 -O /dev/null "http://readonly-proxy:8984/solr/admin/collections?action=LIST" || exit 1; i=$((i+1)); done' \
  || { echo "FAIL  requests failed"; exit 1; }

logs=$(docker logs --since "$start" "$prx" 2>&1 | grep -E ' cluster=solr_[a-z0-9_]+ ' )
total=$(printf '%s\n' "$logs" | grep -c .)
[ "$total" -ge $((N * 9 / 10)) ] || { echo "FAIL  expected ~$N logged requests, saw $total"; exit 1; }

fail=0
sum=0; for kv in ${EXPECT//,/ }; do sum=$((sum + ${kv#*=})); done
declare -A seen
for c in $(printf '%s\n' "$logs" | sed -E 's/.* cluster=solr_([a-z0-9_]+) .*/\1/' | sort -u); do seen[$c]=1; done
for kv in ${EXPECT//,/ }; do seen[${kv%%=*}]=${seen[${kv%%=*}]:-}; done
for c in "${!seen[@]}"; do
  w=0; for kv in ${EXPECT//,/ }; do [ "${kv%%=*}" = "$c" ] && w=${kv#*=}; done
  want=$(awk -v w="$w" -v s="$sum" 'BEGIN{printf "%.1f", 100*w/s}')
  got=$(printf '%s\n' "$logs" | grep -c " cluster=solr_$c " | awk -v t="$total" '{printf "%.1f", 100*$1/t}')
  if awk -v a="$got" -v b="$want" -v t="$TOL" 'BEGIN{d=a-b; if(d<0)d=-d; exit !(d<=t)}'; then
    echo "ok    $c: ${got}% (expected ${want}% +/- ${TOL})"
  else echo "FAIL  $c: ${got}% (expected ${want}% +/- ${TOL})"; fail=1; fi
done
[ $fail = 0 ] && echo "SPLIT OK ($CLUSTER, $total requests)" || { echo "SPLIT MISMATCH ($CLUSTER)"; exit 1; }
