#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <fandom-base-url> <last_rcid>" >&2
  echo "Example: $0 https://nafetskys-archiv.fandom.com/de 0" >&2
  exit 1
fi

BASE="${1%/}"
LAST="${2}"

API="$BASE/api.php"

cont=""

while :; do
  url="$API?action=query&list=recentchanges&rcprop=ids|title|loginfo|timestamp&rclimit=max&rcdir=newer&rcstartid=$LAST&format=json"
  if [[ -n "$cont" ]]; then
    url="${url}&rccontinue=${cont}"
  fi

  json="$(curl -fsSL "$url")"

  echo "$json" | jq -c '
    .query.recentchanges[]
    | if .type=="edit" or .type=="new" then
        {
          type:"page",
          pageId:.pageid,
          revision:.revid,
          title:.title,
          lastModified:.timestamp,
          rcid:.rcid
        }
      elif .type=="log" and .logtype=="delete" then
        {
          type:"delete",
          pageId:.pageid,
          title:(.title // null),
          rcid:.rcid
        }
      elif .type=="log" and .logtype=="move" then
        {
          type:"move",
          pageId:.pageid,
          from:.title,
          to:(.logparams.target_title // null),
          rcid:.rcid
        }
      else
        empty
      end
  '

  cont="$(echo "$json" | jq -r '.continue.rccontinue // empty')"
  [[ -z "$cont" ]] && break
done
