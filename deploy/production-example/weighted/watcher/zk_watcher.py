"""Watch a ZooKeeper znode of traffic weights and keep the proxy's upstream config in step.

  ZK_HOSTS       host:2181,host:2181         this environment's ZooKeeper ensemble
  ZK_PATH        /path/to/traffic.properties znode holding e.g.  blue=120 / green=90
  COLOURS_FILE   colour -> Solr nodes map (local, trusted; see render.py)
  OUT_FILE       where the proxy reads its generated config from (a volume shared with it)
  DEFAULT_WEIGHTS  optional, e.g. "blue=1,green=1": used ONLY on a cold start (no OUT_FILE yet)
                   when ZooKeeper cannot be read. Unset = stay unhealthy until ZooKeeper answers.

Rules: a value that does not parse is logged and IGNORED (last good config stays). A deleted znode
is ignored too. The proxy container notices the rewritten file
and reloads itself (see proxy-entrypoint.sh), so the watcher needs no access to nginx at all.
"""
import logging
import os
import sys
import threading

from kazoo.client import KazooClient

import render

log = logging.getLogger("zk-watcher")
lock = threading.Lock()
state = {"last": None}


def env(name, default=None):
    v = os.environ.get(name, default)
    if v is None:
        sys.exit(f"{name} is required")
    return v


def write_atomic(path, text):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write(text)
    os.replace(tmp, path)


def apply(text, colours, out_file, source):
    """Parse + render + write. Returns True if applied. Never raises on bad input."""
    with lock:
        try:
            weights = render.parse_weights(text, colours)
            conf = render.render(colours, weights)
        except render.ConfigError as e:
            log.error("ignoring %s value, keeping the last good config: %s", source, e)
            return False
        if conf == state["last"]:
            log.info("%s: no change (%s)", source, weights)
            return True
        write_atomic(out_file, conf)
        state["last"] = conf
        log.info("%s: applied %s (the proxy reloads itself within ~2s)", source, weights)
        return True


def main():
    logging.basicConfig(level=logging.INFO, stream=sys.stdout, format="%(asctime)s %(levelname)s %(message)s")
    hosts, path = env("ZK_HOSTS"), env("ZK_PATH")
    out_file = env("OUT_FILE", "/render/upstream.conf")
    with open(env("COLOURS_FILE")) as f:
        try:
            colours = render.parse_colours(f.read())
        except render.ConfigError as e:
            sys.exit(f"bad colours file: {e}")
    log.info("colours: %s", {c: len(n) for c, n in colours.items()})

    if os.path.exists(out_file):
        with open(out_file) as f:
            state["last"] = f.read()
        log.info("found existing %s: it stays in force until ZooKeeper says otherwise", out_file)
    elif os.environ.get("DEFAULT_WEIGHTS"):
        apply(os.environ["DEFAULT_WEIGHTS"], colours, out_file, "DEFAULT_WEIGHTS (cold start)")

    zk = KazooClient(hosts=hosts, timeout=10, read_only=False)
    zk.add_listener(lambda s: log.info("zookeeper state: %s", s))
    zk.start(timeout=1_000_000)          # kazoo keeps retrying; the process is supervised by compose

    @zk.DataWatch(path)
    def on_change(data, stat):
        if data is None:
            log.warning("znode %s does not exist; keeping the last good config", path)
            return
        apply(data.decode("utf-8", "replace"), colours, out_file, f"zk:{path} v{stat.version}")

    threading.Event().wait()


if __name__ == "__main__":
    main()
