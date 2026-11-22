#!/usr/bin/env bash
# Launches the Solr MCP server (STDIO) pointed at the read-only proxy.
# stdout is the MCP protocol stream, so this script must never print to it.
set -eu
here=$(cd "$(dirname "$0")" && pwd)

jar=$(ls "$here"/../../build/libs/solr-mcp-*.jar 2>/dev/null | grep -v -e plain -e sources -e javadoc | head -1 || true)
[ -n "$jar" ] || { echo "run-mcp.sh: no jar found. Run ./gradlew bootJar (needs JDK 25)." >&2; exit 1; }

# The jar is built for Java 25. Use $JAVA, then $JAVA_HOME, then PATH, then look for a
# JDK 25 in the usual places, and refuse anything older with a readable message.
major() { "$1" -version 2>&1 | sed -n '1s/.*version "\([0-9]*\).*/\1/p'; }
candidates=()
[ -n "${JAVA:-}" ] && candidates+=("$JAVA")
[ -n "${JAVA_HOME:-}" ] && candidates+=("$JAVA_HOME/bin/java")
candidates+=("$(command -v java || true)")
for d in "$HOME"/.sdkman/candidates/java/25* /usr/lib/jvm/*25* /opt/homebrew/opt/openjdk@25 /Library/Java/JavaVirtualMachines/*25*/Contents/Home; do
  [ -x "$d/bin/java" ] && candidates+=("$d/bin/java")
done

java_bin=""
for c in "${candidates[@]}"; do
  [ -n "$c" ] && [ -x "$c" ] || continue
  m=$(major "$c" || true)
  if [ "${m:-0}" -ge 25 ] 2>/dev/null; then java_bin=$c; break; fi
done
[ -n "$java_bin" ] || {
  echo "run-mcp.sh: needs Java 25+, found: $(java -version 2>&1 | head -1)." >&2
  echo "Install JDK 25 or set JAVA=/path/to/jdk25/bin/java." >&2
  exit 1
}

# Hide every write tool from the tool list (HiddenToolsConfiguration). Override with
# SOLR_MCP_READ_ONLY=false to see them (the proxy still refuses the writes).
export SOLR_MCP_READ_ONLY=${SOLR_MCP_READ_ONLY:-true}
export SOLR_URL=${SOLR_URL:-http://localhost:${PROXY_PORT:-8984}/solr/}
exec "$java_bin" -jar "$jar"
