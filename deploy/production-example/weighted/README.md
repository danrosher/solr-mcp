# Weighted blue/green: traffic split read from ZooKeeper

One Linux host per environment (`test`, `prod`) runs the MCP server, the read-only proxy and a small
ZooKeeper watcher, all as containers. Each environment has its **own** ZooKeeper and traffic znode.
The znode holds weights, e.g. `blue=120` / `green=90`, and the proxy sends 120/210 = 57.14% of
requests to the blue cluster and the rest to green.

```
users ─► TLS ingress ─► solr-mcp ──link──► readonly-proxy ──upstream──► blue nodes   (57.14%)
 (solr-test / solr-prod)  (egress: IdP)        ▲  split_clients                └─────► green nodes  (42.86%)
                                               │ upstream.conf (shared volume)
                                          zk-watcher ◄── this environment's ZooKeeper  (znode: traffic.properties)
```

Users never see colours: they register one MCP per environment (`solr-test`, `solr-prod`). A weight
change is a ZooKeeper write; nothing is redeployed or reconfigured.

Everything not described here (network design, firewall, TLS, IdP, hardening) is exactly as in
[`../single-host/README.md`](../single-host/README.md); read that first. This directory reuses its
`firewall/apply.sh` and `verify.sh` unchanged, and the one shared allowlist
`../../readonly-proxy/nginx.conf`.

## How it works

| Piece | Job |
|---|---|
| `zk-watcher` | Watches `ZK_PATH` on `ZK_HOSTS`. On every change it parses the weights, renders `upstream.conf` and writes it atomically to a shared volume. Joins the `upstream` network only, so the MCP cannot reach ZooKeeper. |
| `readonly-proxy` | The unchanged allowlist, started by `proxy-entrypoint.sh`, which points it at the colour the split picked. A loop notices a rewritten `upstream.conf`, runs `nginx -t`, and only then reloads (graceful). Reload lag is about 2 s. |
| `solr-mcp` | Unchanged. Still `SOLR_URL=http://readonly-proxy:8984/solr/`. |

The split is `split_clients $request_id`: each request independently picks a colour at the stated
percentage, then round-robins over that colour's nodes. Weights are exact in expectation, whatever the
node counts.

### Rules the watcher follows

- **The znode carries weights only.** Node addresses come from `conf/<env>-colours.conf`, so a bad or
  malicious znode value cannot point the proxy at an arbitrary host.
- **Value format:** `colour=integer` entries separated by newlines or commas; `#` comments; keys that
  are not a known colour are ignored; a missing colour counts as 0. Both
  `blue=120\ngreen=90` and `blue=120,green=90` work.
- **A value that does not parse is ignored** (logged as `ERROR ignoring ...`); the last good config
  stays in force. So are an all-zero value and a deleted znode.
- **A colour at 0 gets no traffic and is never used as a fallback**: 0 means drained / not ready.
- **Fallback between colours:** if every node of a colour is down, its requests go to the other
  colours that have a weight above 0 (`backup` servers). The first requests after a failure try the
  dead node and are retried (up to 3 tries, 2 s connect timeout), then it is skipped for 10 s at a time.
- **Cold start:** the proxy will not start until the watcher has written a config. If ZooKeeper
  cannot be read and `DEFAULT_WEIGHTS` is unset, the stack stays down rather than guess. Set
  `DEFAULT_WEIGHTS=blue=1,green=1` to accept that guess. After the first config exists, a restart
  keeps using it if ZooKeeper is unreachable.
- **Restarts are independent.** Restarting the proxy or the watcher does not affect the other.

### Behaviour to know about

- **The split is per request, not per conversation.** If Claude pages through `search` results and
  the two colours hold different data, consecutive pages can come from different clusters. Fine if
  they are identical; a problem mid-migration.
- **If the only active colour is down there is no fallback** (the drained colour is deliberately not
  used), so requests fail with 502/504. Raise the other colour's weight above 0 to re-enable it.
- `nginx` resolves node names once, at start and reload. Use IPs, or names that never change.

## Set up (per environment)

```bash
cp env.prod.example env.prod          # once for prod, once for test (env.test.example)
$EDITOR env.prod                      # image, IdP, subnets, ZK_HOSTS, ZK_PATH, SOLR_NODES, EXTRA_BLOCK
$EDITOR conf/prod-colours.conf        # colour -> that cluster's nodes
docker compose -p solr-mcp-prod --env-file env.prod -f compose.yaml up -d --build

sudo ../single-host/firewall/apply.sh env.prod --dry-run
sudo ../single-host/firewall/apply.sh env.prod
../single-host/verify.sh env.prod     # expect ALL PASSED
./verify-split.sh env.prod "blue=120,green=90"
```

Pick subnets and `MCP_PORT` that do not collide between environments if they share a host (the
examples use 10.88.1x/8080 for prod and 10.88.2x/8081 for test). Preferably give each environment its
own host.

**Keep in sync:** `SOLR_NODES` in the env file must list **every node of every colour** (the firewall
blocks the MCP from all of them whichever colour is receiving traffic), matching
`conf/<env>-colours.conf`. `EXTRA_BLOCK` lists the ZooKeeper `ip:port` pairs, also blocked from the
MCP. (`EXTRA_BLOCK` is read by `firewall/apply.sh`; it is optional and does nothing when unset.)
After editing the colours file, `docker compose ... restart zk-watcher`.

## Operating it

```bash
# change the split (here with zkCli; use whatever you normally use)
zkCli.sh -server zk-prod-1:2181 set <ZK_PATH> $'blue=120\ngreen=90'
docker logs solr-mcp-prod-zk-watcher-1 --tail 3      # "applied {...}" or "ignoring ..."
docker logs solr-mcp-prod-readonly-proxy-1 --tail 3  # "upstream.conf changed, nginx reloaded"
./verify-split.sh env.prod "blue=120,green=90"       # measure it
```

The proxy logs one line per request (`cluster=solr_blue upstream=10.1.0.12:8983`; method, path and
status only, never query strings), which is what `verify-split.sh` counts.

| Symptom | Likely cause |
|---|---|
| Stack will not start; watcher `unhealthy` | ZooKeeper unreachable or znode missing, and no `DEFAULT_WEIGHTS`. Check the watcher's log. |
| `ignoring ... value` in watcher log | The znode value is invalid; the previous split is still live. Fix the znode. |
| `new upstream.conf FAILS 'nginx -t'` in proxy log | Should not happen with a generated file; the running config stays. Check the colours file. |
| 502/504 for some requests | A colour's nodes are down and no other colour has weight > 0. |
| Split off by a few points | Normal sampling noise: stdev is about 2 points at 600 requests. Use more requests. |

## What was tested, and what was not

Tested on a laptop with a real ZooKeeper 3.9 container, three stand-in Solr nodes (nginx returning
200) and the real proxy and watcher images, on the `upstream` network:

- `watcher/test_render.py`: 12 unit tests of parsing, percentages and rendering
  (`cd watcher && python3 -m unittest`);
- cold start without a znode (stack stays down), then znode created: watcher applies, proxy starts;
- 120/90 measured as 53.8/46.2 over 600 requests; 1:3 as 26.2/73.8; properties file with comments and
  an unknown key;
- live flips with no restart; `green=0` sends nothing to green; garbage and all-zero values are
  ignored and the last good split stays;
- blue wholly down: 100/100 requests still answered, by green; blue down and green drained: green is
  not used (502/504), as designed;
- restarting the proxy alone, and the watcher alone, with the other unaffected;
- a corrupted `upstream.conf` is rejected by `nginx -t`, the running config keeps serving, and
  restoring the file reloads normally;
- both compose files render; `apply.sh --dry-run` prints the Solr and ZooKeeper rules, and the
  single-host rules are unchanged.

**Not tested** (needs your environment):

- the firewall rules themselves, including the ZooKeeper `EXTRA_BLOCK` ones (never applied for real);
- the real ZooKeeper ensembles (multi-node, auth/ACLs: the watcher does no authentication, so the
  znode must be readable anonymously from the host, or the watcher needs auth added);
- the real `traffic.properties` content and path; the parser accepts `colour=int` lines, so check yours;
- the MCP container, IdP and TLS in this layout (the local test started only the proxy and watcher);
- real Solr nodes behind the proxy.
