#!/usr/bin/env bash
# Verifies the read-only allowlist. Usage: ./test.sh [proxy-base-url] [collection]
# Needs a running proxy in front of a Solr that has the collection (default: films
# from the repo's init-solr.sh).
set -u
P=${1:-http://localhost:8984}
C=${2:-films}
fail=0

check() { # expected-status description curl-args...
  local want=$1 desc=$2; shift 2
  local got
  got=$(curl -s -o /dev/null -w '%{http_code}' "$@")
  if [ "$got" = "$want" ]; then echo "ok    $got  $desc"
  else echo "FAIL  $got (want $want)  $desc"; fail=1; fi
}

check_body() { # description grep-pattern curl-args...   (passes when the response body matches)
  local desc=$1 pat=$2; shift 2
  if curl -s "$@" | grep -q -- "$pat"; then echo "ok    body  $desc"
  else echo "FAIL  body  $desc (expected /$pat/)"; fail=1; fi
}

echo "== allowed (read) =="
check 200 "search"                 "$P/solr/$C/select?q=*:*&rows=1"
check 200 "search, encoded value"  "$P/solr/$C/select?q=%2A%3A%2A&rows=1"
check 200 "schema"                 "$P/solr/$C/schema"
check 200 "luke"                   "$P/solr/$C/admin/luke?show=index&numTerms=0"
check 200 "ping"                   "$P/solr/$C/admin/ping"
check 200 "metrics"                "$P/solr/admin/metrics?group=core&wt=json"
check 200 "list collections"       "$P/solr/admin/collections?action=LIST"
check 200 "list aliases"           "$P/solr/admin/collections?action=LISTALIASES"

echo "== time limit on every query (first value wins in Solr) =="
check_body "default timeAllowed=5000 applied"        '"timeAllowed":"5000"'           "$P/solr/$C/select?q=*:*&rows=0&echoParams=all&wt=json"
check_body "client timeAllowed cannot go first"       '"timeAllowed":\["5000","600000"\]' "$P/solr/$C/select?q=*:*&rows=0&timeAllowed=600000&echoParams=all&wt=json"
check 403 "timeAllowed hidden by encoded name"        "$P/solr/$C/select?q=*:*&%74imeAllowed=600000"

echo "== blocked (write / unlisted) =="
check 403 "update (POST)"          -XPOST -H 'Content-Type: application/json' "$P/solr/$C/update?commit=true" -d '[]'
check 403 "update (GET)"           "$P/solr/$C/update?stream.body=%3Cdelete%3E%3Cquery%3E*:*%3C/query%3E%3C/delete%3E&commit=true"
check 403 "schema write (POST)"    -XPOST -H 'Content-Type: application/json' "$P/solr/$C/schema" -d '{"add-field":{"name":"x","type":"string"}}'
check 403 "create collection"      "$P/solr/admin/collections?action=CREATE&name=zz&numShards=1"
check 403 "delete collection"      "$P/solr/admin/collections?action=DELETE&name=$C"
check 403 "create alias"           "$P/solr/admin/collections?action=CREATEALIAS&name=a&collections=$C"
check 403 "delete alias"           "$P/solr/admin/collections?action=DELETEALIAS&name=a"
check 403 "double action"          "$P/solr/admin/collections?action=LIST&action=DELETE&name=$C"
check 403 "lowercase action"       "$P/solr/admin/collections?action=list"
check 403 "ping disable"           "$P/solr/$C/admin/ping?action=disable"
check 403 "select stream.url"      "$P/solr/$C/select?q=*:*&stream.url=http://example.com/"
check 403 "select qt=/update"      "$P/solr/$C/select?q=*:*&qt=/update"
check 403 "select encoded qt"      "$P/solr/$C/select?q=*:*&%71t=/update"
check 403 "select shards"          "$P/solr/$C/select?q=*:*&shards=evil:8983/solr/x"
check 403 "core admin"             "$P/solr/admin/cores?action=UNLOAD&core=$C"
check 403 "config API"             "$P/solr/$C/config"
check 403 "POST select"            -XPOST -d 'q=*:*' "$P/solr/$C/select"
check 403 "path traversal"         --path-as-is "$P/solr/$C/select/../update?commit=true"
check 403 "v2 API"                 "$P/api/collections"

[ $fail = 0 ] && echo "ALL PASSED" || { echo "FAILURES"; exit 1; }
