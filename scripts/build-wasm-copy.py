#!/usr/bin/env python3
"""Build the browser-only copy of the app, for GitHub Pages.

The copy runs with no server. The visitor brings their own LLM key (the `llm`
block in layers-input.json), and geo-query's tools run in the browser on
DuckDB-wasm (SchmidtDSE/geo-query-wasm), in a Web Worker that glen core's MCP
plugin starts. Each collection is read from its source.coop mirror when it has
one, and from NRP's public bucket otherwise.

It is generated from the app's own files, so it never drifts from them:

    layers-input.json  collection URLs moved to source.coop where mirrored;
                       the MCP plugin runs geo-query-wasm in a worker instead
                       of calling duckdb-mcp, with SQL on NRP paths rewritten
                       to the mirrors; the hex plugin loads the same
                       geo-query-wasm release, to draw its in-browser tiles
    worker.js          a same-origin wrapper around geo-query-wasm's worker
    index.html, system-prompt.md   copied as they are

Usage: scripts/build-wasm-copy.py OUT_DIR
"""
import json
import re
import shutil
import sys
import urllib.error
import urllib.request
from pathlib import Path

# geo-query-wasm at a pinned release. Bump deliberately, and check the copy.
GEO_QUERY_WASM = "v0.6.0"
GQW_BASE = f"https://cdn.jsdelivr.net/gh/SchmidtDSE/geo-query-wasm@{GEO_QUERY_WASM}/src/"

# An NRP bucket `public-<name>` is mirrored to source.coop as `cboettig/<name>`.
NRP_HTTPS = re.compile(r"https://s3-west\.nrp-nautilus\.io/public-([^/]+)/")
SC_HTTPS = "https://data.source.coop/cboettig/{}/"
SC_S3 = "s3://us-west-2.opendata.source.coop/cboettig/{}/"


def mirrored(url):
    """Whether source.coop serves this URL."""
    req = urllib.request.Request(url, method="HEAD")
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status == 200
    except urllib.error.HTTPError:
        return False


def plugin_url(p):
    return p if isinstance(p, str) else (p or {}).get("url", "")


def build(root, out):
    out.mkdir(parents=True, exist_ok=True)

    cfg = json.loads((root / "layers-input.json").read_text())
    buckets = set()
    for c in cfg.get("collections", []):
        url = c.get("collection_url", "") if isinstance(c, dict) else ""
        m = NRP_HTTPS.match(url)
        if not m:
            continue
        sc = NRP_HTTPS.sub(SC_HTTPS.format(m.group(1)), url, count=1)
        if mirrored(sc):
            c["collection_url"] = sc
            buckets.add(m.group(1))
        else:
            print(f"no source.coop mirror, reading from NRP: {c['collection_id']}")

    # SQL the model writes from NRP paths reads the mirror instead, bucket by
    # bucket, so collections with no mirror still read from NRP.
    rewrite = []
    for b in sorted(buckets):
        rewrite.append({"from": f"s3://public-{b}/", "to": SC_S3.format(b)})
        rewrite.append({"from": f"https://s3-west.nrp-nautilus.io/public-{b}/", "to": SC_HTTPS.format(b)})
    worker_config = {"discovery": False, "workers": 2, "rewrite": rewrite}

    # glen core's MCP plugin runs the worker in place of duckdb-mcp
    # (SchmidtDSE/glen#460), and its hex plugin draws the worker's tiles.
    plugins = cfg.get("plugins", [])
    mcp = [i for i, p in enumerate(plugins) if plugin_url(p).endswith("/core/plugins/mcp.js")]
    if len(mcp) != 1:
        sys.exit("layers-input.json: expected one glen core MCP plugin (core/plugins/mcp.js)")
    plugins[mcp[0]] = {"url": plugin_url(plugins[mcp[0]]), "options": {
        "worker": "worker.js", "worker_config": worker_config, "prompt": "geospatial-analyst"}}
    for i, p in enumerate(plugins):
        if plugin_url(p).endswith("/core/plugins/hex.js"):
            plugins[i] = {"url": plugin_url(p), "options": {**(p.get("options", {}) if isinstance(p, dict) else {}),
                                                            "geo_query_wasm": GEO_QUERY_WASM}}
    (out / "layers-input.json").write_text(json.dumps(cfg, indent=4) + "\n")

    html = (root / "index.html").read_text()
    if "/core/main.js" not in html:
        sys.exit("index.html: expected the page to load glen core (core/main.js)")
    (out / "index.html").write_text(html)

    (out / "worker.js").write_text(
        "// geo-query-wasm's worker, started from this origin so it can read its\n"
        "// configuration from this file's URL (built by scripts/build-wasm-copy.py).\n"
        f"import '{GQW_BASE}worker.js';\n")

    shutil.copy(root / "system-prompt.md", out)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    build(Path(__file__).resolve().parent.parent, Path(sys.argv[1]))
