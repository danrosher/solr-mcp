#!/usr/bin/env bash
# Stop the MCP container reaching the Solr nodes directly. Run as root on the host, once per
# cluster, AFTER Docker is running (it needs Docker's DOCKER-USER chain).
#
#   sudo ./apply.sh ../env.blue            # add the rules (safe to repeat)
#   sudo ./apply.sh ../env.blue --status   # show them
#   sudo ./apply.sh ../env.blue --remove   # delete them
#       ./apply.sh ../env.blue --dry-run   # print what would run; needs no root
#
# What it does: for every node in SOLR_NODES and port in SOLR_PORTS it rejects traffic whose
# SOURCE is the `egress` subnet (the MCP's only way off the host) and whose destination is that
# node. The proxy leaves from the `upstream` subnet, so it is not matched and still works.
#
# Traffic from containers to other hosts is FORWARDed, so it passes through DOCKER-USER, which
# Docker never flushes. Rules do not survive a reboot: use solr-mcp-firewall@.service.
set -euo pipefail

ENV_FILE=${1:?usage: apply.sh <env-file> [--dry-run|--status|--remove]}
MODE=${2:-apply}
[ -r "$ENV_FILE" ] || { echo "apply.sh: cannot read $ENV_FILE" >&2; exit 2; }
case "$MODE" in apply|--dry-run|--status|--remove) ;; *) echo "apply.sh: unknown mode $MODE" >&2; exit 2 ;; esac

# The env file is KEY=VALUE (quotes allowed), the same file docker compose reads.
set -a; . "$ENV_FILE"; set +a
: "${CLUSTER:?CLUSTER missing in $ENV_FILE}" "${EGRESS_SUBNET:?EGRESS_SUBNET missing}"
: "${SOLR_NODES:?SOLR_NODES missing}" "${SOLR_PORTS:?SOLR_PORTS missing}"
TAG="solr-mcp-${CLUSTER}:no-direct-solr"

run() { if [ "$MODE" = --dry-run ]; then echo "+ $*"; else "$@"; fi; }

if [ "$MODE" != --dry-run ]; then
  [ "$(id -u)" = 0 ] || { echo "apply.sh: run as root (or use --dry-run)" >&2; exit 1; }
  iptables -S DOCKER-USER >/dev/null 2>&1 || {
    echo "apply.sh: no DOCKER-USER chain. Is Docker running? Is it using the nftables backend?" >&2
    echo "          (then the rules must be written with nft instead; see the README)" >&2
    exit 1; }
  # Refuse to guess: the subnet in the env file must be the one Docker really created.
  net="solr-mcp-${CLUSTER}_egress"
  if actual=$(docker network inspect "$net" --format '{{(index .IPAM.Config 0).Subnet}}' 2>/dev/null); then
    [ "$actual" = "$EGRESS_SUBNET" ] || {
      echo "apply.sh: $net has subnet $actual but $ENV_FILE says $EGRESS_SUBNET" >&2; exit 1; }
  else
    echo "apply.sh: note: network $net does not exist yet; start the stack first to check the subnet" >&2
  fi
fi

# Pairs to block: every SOLR_NODES x SOLR_PORTS, plus any "host:port" in the optional EXTRA_BLOCK
# (used by ../../weighted to keep the MCP off ZooKeeper). EXTRA_BLOCK entries must be IPv4.
pairs=()
for node in $SOLR_NODES; do for port in $SOLR_PORTS; do pairs+=("$node $port"); done; done
for hp in ${EXTRA_BLOCK:-}; do
  [[ "$hp" =~ ^[0-9.]+:[0-9]+$ ]] || { echo "apply.sh: EXTRA_BLOCK entry '$hp' is not ipv4:port" >&2; exit 2; }
  pairs+=("${hp%%:*} ${hp##*:}")
done

for pair in "${pairs[@]}"; do
  read -r node port <<<"$pair"
  rule=(-s "$EGRESS_SUBNET" -d "$node/32" -p tcp --dport "$port"
        -m comment --comment "$TAG" -j REJECT --reject-with tcp-reset)
  case "$MODE" in
    --status) iptables -C DOCKER-USER "${rule[@]}" 2>/dev/null && echo "present  $node:$port" || echo "MISSING  $node:$port" ;;
    --remove) while iptables -C DOCKER-USER "${rule[@]}" 2>/dev/null; do run iptables -D DOCKER-USER "${rule[@]}"; done ;;
    apply|--dry-run)
      if [ "$MODE" = --dry-run ]; then run iptables -I DOCKER-USER "${rule[@]}"
      else iptables -C DOCKER-USER "${rule[@]}" 2>/dev/null || run iptables -I DOCKER-USER "${rule[@]}"; fi ;;
    *) echo "apply.sh: unknown mode $MODE" >&2; exit 2 ;;
  esac
done
[ "$MODE" = apply ] && echo "ok: $CLUSTER: egress $EGRESS_SUBNET can no longer reach: $SOLR_NODES (ports: $SOLR_PORTS) ${EXTRA_BLOCK:+and: $EXTRA_BLOCK}"
exit 0
