# Shared nginx config

Every GLEN app on NRP serves its page and relays chat and MCP calls through an
nginx container. The parts that are the same in every app live here, so a
fleet-wide change is one edit and a new tag rather than a hand edit per app
(glen-ops#340).

| file | context | what it holds |
|--|--|--|
| `limits.conf` | http (outside `server`) | client address from `X-Forwarded-For`, rate and connection limits |
| `base.conf` | server | document root, CORS headers, `/health` |
| `llm.conf` | server | `/api/llm/chat/completions` and `/api/llm/models` to open-llm-proxy, everything else under `/api/llm/` 404 |
| `mcp.conf` | server | `/api/mcp` and `/tiles/` to geo-query |
| `spa.conf` | server | `/`, serving `index.html` uncached |
| `auth-basic.conf` | server | password login on everything (`/health` and `llm-token.conf` turn it off) |
| `llm-private.conf` | server | for an app behind a sign-in proxy, in place of `llm.conf`: all of `/api/llm/` relayed, no token, no limits |
| `llm-token.conf` | server | for an app behind a password, in place of `llm.conf`: all of `/api/llm/` relayed, checked against `APP_TOKEN`, no limits |
| `render.sh` | | fills in per-app values from the env, writes `config.json`, starts nginx |

## Using it in an app

The app's `k8s/configmap.yaml` keeps only its own server block:

```nginx
include /etc/nginx/glen/limits.conf;

server {
    listen 80;
    server_name _;

    include /etc/nginx/glen/base.conf;
    include /etc/nginx/glen/llm.conf;
    include /etc/nginx/glen/mcp.conf;
    include /etc/nginx/glen/spa.conf;

    # This app's own routes go here.
}
```

The Deployment's init container copies this directory, at a tag, into an
`emptyDir` mounted at `/glen-nginx`:

```sh
git clone --depth 1 --branch nginx-v1 https://github.com/SchmidtDSE/glen-template.git /tmp/glen
cp /tmp/glen/nginx/* /glen-nginx/
```

and the nginx container runs `sh /glen-nginx/render.sh`, with these values in
its env:

| variable | example |
|--|--|
| `GLEN_APP` | the app's name in glen-ops APPS.md, sent as `X-Glen-App` |
| `LLM_UPSTREAM` | `http://open-llm-proxy.schmidtdse.svc.cluster.local:8002` |
| `PROXY_KEY` | from the namespace's proxy key Secret |
| `MCP_UPSTREAM` | `http://duckdb-mcp.schmidtdse.svc.cluster.local:8000` |
| `MCP_HOST` | `duckdb-mcp.schmidtdse.svc.cluster.local` |
| `MCP_TILES_SOURCE` | optional; the tile URL prefix the server returns, default `$MCP_UPSTREAM/tiles/` |
| `MCP_AUTH_TOKEN` | from the MCP token Secret |
| `MCP_SERVER_URL` | `https://<host>/api/mcp`, written into `config.json` |
| `APP_NGINX_VARS` | optional; more variables the app's own block uses, e.g. `'${SDM_AUTH_TOKEN}'` |
| `CONFIG_JSON_VARS` | optional; more variables for `config.json`, e.g. `'${MAPTILER_KEY}'`. `config.json` is public, so never a secret |
| `CONFIG_JSON_COPIES` | optional; more paths to copy `config.json` to, for a second page such as `/usr/share/nginx/html/iucn/config.json`; skipped when the directory is absent |
| `CORS_ORIGIN` | optional; `Access-Control-Allow-Origin` in `base.conf`, default `*`. A signed-in app can set its own origin |
| `AUTH_REALM` | with `auth-basic.conf`; the login prompt |
| `APP_TOKEN` | with `llm-token.conf`; derived from `/etc/nginx/auth/htpasswd` when unset. Put `'${APP_TOKEN}'` in `CONFIG_JSON_VARS` so the page can send it |

`render.sh` renders only the snippets the server block includes, and stops the
pod if a value one of them needs is missing.

## Changing a snippet

padus, the template's own deployment, reads these files from `main`, so it runs
a change first. Once it is checked there, tag the commit `nginx-vN` and bump the
tag in each app, the same way as a GLEN pin.
