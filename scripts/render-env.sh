#!/usr/bin/env bash
# Per-branch Render environment for Agor.
# Usage: render-env.sh <start|stop|logs|nuke> <branch-name> <git-ref> <repo-url>
# Needs RENDER_API_KEY and RENDER_OWNER_ID (Agor Global env vars). Never prints them.
set -euo pipefail

action=${1:?action}; branch=${2:?branch name}; ref=${3:?git ref}; repo=${4:?repo url}
: "${RENDER_API_KEY:?RENDER_API_KEY not set}" "${RENDER_OWNER_ID:?RENDER_OWNER_ID not set}"

slug=$(printf '%s' "$branch" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9\n' '-' | sed 's/^-*//; s/-*$//' | cut -c1-40)
name="agor-$slug"
api=https://api.render.com/v1

r() { curl -fsS -H "Authorization: Bearer $RENDER_API_KEY" -H 'Accept: application/json' -H 'Content-Type: application/json' "$@"; }

find_id() {
  r "$api/services?name=$name&ownerId=$RENDER_OWNER_ID&limit=20" \
    | jq -r --arg n "$name" '[.[].service | select(.name == $n)][0].id // empty'
}
service_url() { r "$api/services/$1" | jq -r '.serviceDetails.url'; }

wait_live() { # service id, deploy id
  for _ in $(seq 1 60); do
    st=$(r "$api/services/$1/deploys/$2" | jq -r '.status')
    echo "deploy $2: $st" >&2
    case $st in
      live) return 0 ;;
      build_failed|update_failed|canceled|pre_deploy_failed) return 1 ;;
    esac
    sleep 10
  done
  return 1
}

envvars=$(jq -n --arg b "$branch" '[{key:"AGOR_BRANCH",value:$b},{key:"PAGE_MARKER",value:("page-"+$b)},{key:"HEALTH_MARKER",value:("health-"+$b)}]')

id=$(find_id)
case $action in
  start)
    if [ -z "$id" ]; then
      body=$(jq -n --arg n "$name" --arg o "$RENDER_OWNER_ID" --arg repo "$repo" --arg ref "$ref" --argjson env "$envvars" '{
        type:"web_service", name:$n, ownerId:$o, repo:$repo, branch:$ref, autoDeploy:"no", rootDir:"render-demo",
        envVars:$env,
        serviceDetails:{runtime:"node", plan:"free", region:"oregon", healthCheckPath:"/health",
          envSpecificDetails:{buildCommand:"npm install", startCommand:"node server.js"}}}')
      res=$(r -X POST "$api/services" -d "$body")
      id=$(jq -r '.service.id' <<<"$res"); dep=$(jq -r '.deployId' <<<"$res")
      echo "created $name ($id)" >&2
    else
      # Reuse: resume if suspended, refresh env vars and branch, redeploy.
      r -X POST "$api/services/$id/resume" >/dev/null 2>&1 || true
      r -X PUT "$api/services/$id/env-vars" -d "$envvars" >/dev/null
      r -X PATCH "$api/services/$id" -d "$(jq -n --arg ref "$ref" '{branch:$ref}')" >/dev/null
      dep=$(r -X POST "$api/services/$id/deploys" -d '{}' | jq -r '.id')
      echo "updated $name ($id)" >&2
    fi
    wait_live "$id" "$dep" || { echo "deploy failed; see logs" >&2; exit 1; }
    url=$(service_url "$id")
    echo "AGOR_ENVIRONMENT_RESULT=$(jq -cn --arg u "$url" '{app:$u, health:($u+"/health")}')"
    ;;
  stop)
    [ -n "$id" ] || { echo "no service $name; nothing to stop" >&2; exit 0; }
    r -X POST "$api/services/$id/suspend" >/dev/null; echo "suspended $name"
    ;;
  logs)
    [ -n "$id" ] || { echo "no service $name" >&2; exit 0; }
    r "$api/logs?ownerId=$RENDER_OWNER_ID&resource=$id&limit=100&direction=backward" \
      | jq -r '.logs | reverse[] | "\(.timestamp) \(.message)"'
    ;;
  nuke)
    [ -n "$id" ] || { echo "no service $name; nothing to delete" >&2; exit 0; }
    r -X DELETE "$api/services/$id" >/dev/null; echo "deleted $name"
    ;;
  *) echo "unknown action $action" >&2; exit 2 ;;
esac
