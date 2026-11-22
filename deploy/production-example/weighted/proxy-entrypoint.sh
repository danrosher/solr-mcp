#!/bin/sh
# Starts nginx with the SAME read-only allowlist as every other layout (../../readonly-proxy/nginx.conf),
# but sends each request to the upstream the weighted split picked ($solr_cluster, defined in the
# generated /etc/nginx/solr/upstream.conf) instead of the single `solr_upstream`.
# The allowlist is edited by sed at start so there is still exactly one copy of it.
#
# It also reloads itself: a background loop notices when zk-watcher rewrites upstream.conf, checks
# the new file with `nginx -t`, and only then reloads (graceful; in-flight requests finish). A file
# that fails the check is logged and ignored, so the running config stays in force. This keeps the
# watcher independent of this container: either can restart without the other.
set -eu
SRC=/src/nginx.conf
DST=/etc/nginx/conf.d/default.conf
UP=/etc/nginx/solr/upstream.conf
sed -e 's#http://solr_upstream#http://$solr_cluster#' \
    -e '/^  listen 8984;/a\  access_log /dev/stdout solr;' "$SRC" > "$DST"
# Refuse to start if the rewrite did not happen: otherwise nginx would fail on a missing upstream,
# or worse, silently ignore the split.
grep -q 'http://\$solr_cluster' "$DST" || { echo "entrypoint: proxy_pass rewrite failed" >&2; exit 1; }
if grep -q 'http://solr_upstream' "$DST"; then echo "entrypoint: unrewritten proxy_pass left" >&2; exit 1; fi
grep -q 'access_log /dev/stdout solr;' "$DST" || { echo "entrypoint: access_log insert failed" >&2; exit 1; }
[ -s "$UP" ] || { echo "entrypoint: $UP is missing: zk-watcher has not written it" >&2; exit 1; }

(
  last=$(md5sum "$UP")
  while sleep 2; do
    cur=$(md5sum "$UP" 2>/dev/null) || continue
    [ "$cur" != "$last" ] || continue
    if nginx -t >/dev/null 2>&1; then
      if nginx -s reload 2>/dev/null; then echo "entrypoint: upstream.conf changed, nginx reloaded"; last=$cur; fi
    else
      echo "entrypoint: new upstream.conf FAILS 'nginx -t'; keeping the running config" >&2; last=$cur
    fi
  done
) &
exec nginx -g 'daemon off;'
