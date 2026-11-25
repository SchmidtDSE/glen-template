#!/bin/sh
# Start nginx for a GLEN app from the shared snippets (glen-ops#340).
#
# Renders each snippet in this directory that the app's own server block
# includes (as /etc/nginx/glen/<name>.conf), then the server block itself,
# filling in per-app values from the environment, and starts nginx. Only the
# variables listed below are substituted, so nginx's own $variables pass through.
# A snippet whose values are missing stops the pod here rather than starting
# nginx with an empty key or upstream.
#
# Per-app values (set in the Deployment's env):
#   GLEN_APP          the app's name in APPS.md; sent as X-Glen-App
#   LLM_UPSTREAM      e.g. http://open-llm-proxy.schmidtdse.svc.cluster.local:8002
#   PROXY_KEY         the app's key for that proxy
#   MCP_UPSTREAM      e.g. http://duckdb-mcp.schmidtdse.svc.cluster.local:8000
#   MCP_HOST          the Host header the MCP server expects
#   MCP_TILES_SOURCE  tile URL prefix the server returns; default MCP_UPSTREAM/tiles/
#   MCP_AUTH_TOKEN    bearer token for the MCP server
#   MCP_SERVER_URL    absolute https://<host>/api/mcp, written into config.json
#   APP_NGINX_VARS    more variables for the app's own block, e.g. '${SDM_AUTH_TOKEN}'
#   CONFIG_JSON_VARS  more variables for config.json, e.g. '${MAPTILER_KEY}'; only
#                     values the browser may see, since config.json is public
#   CONFIG_JSON_COPIES  more places to copy config.json, e.g. a second page's
#                     /usr/share/nginx/html/iucn/config.json; skipped when the
#                     directory is absent
#   AUTH_REALM        the login prompt, for an app that includes auth-basic.conf
#   CORS_ORIGIN       Access-Control-Allow-Origin in base.conf; default *
#   APP_TOKEN         the chat bearer for llm-token.conf; by default derived from
#                     /etc/nginx/auth/htpasswd, so it changes with the password
set -eu

here=$(cd "$(dirname "$0")" && pwd)
app_conf=${APP_NGINX_TEMPLATE:-/nginx-template/nginx.conf.template}
out=/etc/nginx/glen

need() {
    for v in "$@"; do
        eval "val=\${$v:-}"
        if [ -z "$val" ]; then
            echo "glen nginx: $v must be set" >&2
            exit 1
        fi
    done
}

apk add --no-cache gettext >/dev/null

if [ -n "${MCP_UPSTREAM:-}" ]; then
    : "${MCP_TILES_SOURCE:=$MCP_UPSTREAM/tiles/}"
    export MCP_TILES_SOURCE
fi

if [ -z "${APP_TOKEN:-}" ] && [ -f /etc/nginx/auth/htpasswd ]; then
    APP_TOKEN=$(sha256sum /etc/nginx/auth/htpasswd | cut -c1-40)
    export APP_TOKEN
fi

: "${CORS_ORIGIN:=*}"
export CORS_ORIGIN

vars='${GLEN_APP} ${LLM_UPSTREAM} ${PROXY_KEY} ${MCP_UPSTREAM} ${MCP_HOST} ${MCP_TILES_SOURCE} ${MCP_AUTH_TOKEN} ${MCP_SERVER_URL} ${APP_TOKEN} ${AUTH_REALM} ${CORS_ORIGIN}'
vars="$vars ${APP_NGINX_VARS:-}"

need GLEN_APP
mkdir -p "$out"
for name in $(grep -o '/etc/nginx/glen/[a-z0-9-]*\.conf' "$app_conf" | sort -u | xargs -n1 basename || true); do
    case $name in
        llm.conf) need LLM_UPSTREAM PROXY_KEY ;;
        llm-token.conf) need LLM_UPSTREAM PROXY_KEY APP_TOKEN ;;
        llm-private.conf) need LLM_UPSTREAM PROXY_KEY ;;
        auth-basic.conf) need AUTH_REALM ;;
        mcp.conf) need MCP_UPSTREAM MCP_HOST MCP_AUTH_TOKEN ;;
    esac
    if [ ! -f "$here/$name" ]; then
        echo "glen nginx: no shared snippet $name in $here" >&2
        exit 1
    fi
    envsubst "$vars" < "$here/$name" > "$out/$name"
done
envsubst "$vars" < "$app_conf" > /etc/nginx/conf.d/default.conf

# Client-side config: no secrets, only the MCP URL and CONFIG_JSON_VARS.
if [ -f /config/config.template.json ]; then
    envsubst "\${MCP_SERVER_URL} ${CONFIG_JSON_VARS:-}" < /config/config.template.json > /usr/share/nginx/html/config.json
    for copy in ${CONFIG_JSON_COPIES:-}; do
        if [ -d "$(dirname "$copy")" ]; then
            cp /usr/share/nginx/html/config.json "$copy"
        fi
    done
fi

# nginx defaults to one worker per CPU, which on large NRP nodes OOMKills the
# 256Mi container (glen-ops#49).
sed -i 's/^worker_processes.*/worker_processes 2;/' /etc/nginx/nginx.conf

exec nginx -g 'daemon off;'
