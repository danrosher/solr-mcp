#!/usr/bin/env bash
# Runs once inside the compose network and talks to Solr DIRECTLY (it needs write
# access). The MCP server never gets this path: it only sees the read-only proxy.
set -euo pipefail
SOLR=http://solr:8983/solr
ZK=zoo:2181
BASE=/opt/solr/server/solr/configsets/_default/conf

existing=$(curl -sf "$SOLR/admin/collections?action=LIST&wt=json")

make_collection() { # name uniqueKey
  local name=$1 key=$2
  if echo "$existing" | grep -q "\"$name\""; then echo "== $name exists, skipping"; return; fi
  echo "== creating $name (uniqueKey=$key)"
  local dir=/tmp/conf-$name
  rm -rf "$dir"; cp -r "$BASE" "$dir"
  # _default hardwires `id` as the unique key; swap it for the real one.
  sed -i "s#<field name=\"id\" type=\"string\"#<field name=\"$key\" type=\"string\"#; s#<uniqueKey>id</uniqueKey>#<uniqueKey>$key</uniqueKey>#" "$dir/managed-schema.xml"
  /opt/solr/bin/solr zk upconfig -n "$name" -d "$dir" -z "$ZK" >/dev/null
  curl -sf "$SOLR/admin/collections?action=CREATE&name=$name&collection.configName=$name&numShards=1&replicationFactor=1&wt=json" >/dev/null
}

add_fields() { # collection json-array-of-field-defs
  local body="{\"add-field\":$2}"
  curl -sf -H 'Content-Type: application/json' "$SOLR/$1/schema" -d "$body" >/dev/null
}

load() { curl -sf -H 'Content-Type: application/json' "$SOLR/$1/update?commit=true" --data-binary "@$2" >/dev/null; echo "   loaded $2 into $1"; }

make_collection products product_oid
add_fields products '[
 {"name":"title","type":"text_general","stored":true},
 {"name":"brand","type":"string","stored":true},
 {"name":"category","type":"string","stored":true},
 {"name":"description","type":"text_general","stored":true}]'
load products /data/products.json

make_collection skus sku_oid
add_fields skus '[
 {"name":"product_oid","type":"string","stored":true},
 {"name":"merchant_id","type":"string","stored":true},
 {"name":"colour","type":"string","stored":true},
 {"name":"size","type":"string","stored":true},
 {"name":"price","type":"pdouble","stored":true},
 {"name":"currency","type":"string","stored":true},
 {"name":"stock","type":"pint","stored":true},
 {"name":"in_stock","type":"boolean","stored":true}]'
load skus /data/skus.json
echo "== demo data ready"
