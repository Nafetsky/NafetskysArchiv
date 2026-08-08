#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <fandom-base-url> <last-rcid>" >&2
  exit 2
fi

BASE="${1%/}"
LAST_RCID="$2"
API="$BASE/api.php"

for cmd in curl jq mktemp sort; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "ERROR: Required command '$cmd' was not found." >&2
    exit 127
  }
done

api() {
  curl -fsSLG --retry 3 --retry-delay 1 \
    --data-urlencode "format=json" \
    "$API" "$@"
}

# First run: rcid=0 means no previous sync.
# RecentChanges is not a complete page listing, so enumerate all pages.
if [[ "$LAST_RCID" == "0" ]]; then
  tmp_pages="$(mktemp)"
  trap 'rm -f "$tmp_pages"' EXIT
  cont=""

  while :; do
    args=(
      --data-urlencode "action=query"
      --data-urlencode "list=allpages"
      --data-urlencode "aplimit=max"
    )
    [[ -n "$cont" ]] && args+=(--data-urlencode "apcontinue=$cont")

    json="$(api "${args[@]}")"

    echo "$json" |
      jq -r '.query.allpages[] | [.pageid, .title] | @tsv' >> "$tmp_pages"

    cont="$(echo "$json" | jq -r '.continue.apcontinue // empty')"
    [[ -z "$cont" ]] && break
  done

  while IFS=$'\t' read -r page_id title; do
    json="$(api \
      --data-urlencode "action=query" \
      --data-urlencode "pageids=$page_id" \
      --data-urlencode "prop=revisions" \
      --data-urlencode "rvprop=ids|timestamp" \
      --data-urlencode "rvlimit=1"
    )"

    echo "$json" |
      jq -c --argjson pageId "$page_id" '
        .query.pages | to_entries[0].value |
        select(.missing != true and .revisions != null) |
        {
          type: "page",
          pageId: $pageId,
          revision: .revisions[0].revid,
          title: .title,
          lastModified: .revisions[0].timestamp
        }
      '
  done < "$tmp_pages"

  # Establish the cursor after the initial enumeration.
  rc_json="$(api \
    --data-urlencode "action=query" \
    --data-urlencode "list=recentchanges" \
    --data-urlencode "rcprop=ids" \
    --data-urlencode "rclimit=1"
  )"
  current_rcid="$(echo "$rc_json" | jq -r '.query.recentchanges[0].rcid // 0')"

  jq -cn --argjson rcid "$current_rcid" '{type:"cursor", rcid:$rcid}'
  exit 0
fi

# Incremental run: collect changes after LAST_RCID, then fetch the current
# revision once per affected page. Multiple edits are therefore collapsed.
tmp_changes="$(mktemp)"
trap 'rm -f "$tmp_changes"' EXIT
cont=""
max_rcid="$LAST_RCID"

while :; do
  args=(
    --data-urlencode "action=query"
    --data-urlencode "list=recentchanges"
    --data-urlencode "rcprop=ids|title|timestamp|loginfo"
    --data-urlencode "rclimit=max"
    --data-urlencode "rcdir=newer"
    --data-urlencode "rcstartid=$LAST_RCID"
  )
  [[ -n "$cont" ]] && args+=(--data-urlencode "rccontinue=$cont")

  json="$(api "${args[@]}")"

  echo "$json" |
    jq -c '
      .query.recentchanges[]
      | if .type == "edit" or .type == "new" then
          {type:"page", pageId:.pageid, title:.title, rcid:.rcid}
        elif .type == "log" and .logtype == "delete" then
          {type:"delete", pageId:.pageid, title:(.title // null), rcid:.rcid}
        elif .type == "log" and .logtype == "move" then
          {type:"move", pageId:.pageid, from:.title,
           to:(.logparams.target_title // null), rcid:.rcid}
        else empty
        end
    ' >> "$tmp_changes"

  batch_max="$(echo "$json" | jq -r '[.query.recentchanges[].rcid] | max // 0')"
  (( batch_max > max_rcid )) && max_rcid="$batch_max"

  cont="$(echo "$json" | jq -r '.continue.rccontinue // empty')"
  [[ -z "$cont" ]] && break
done

page_ids="$(
  jq -r 'select(.type == "page") | .pageId' "$tmp_changes" |
  sort -n -u
)"

while IFS= read -r page_id; do
  [[ -z "$page_id" ]] && continue

  json="$(api \
    --data-urlencode "action=query" \
    --data-urlencode "pageids=$page_id" \
    --data-urlencode "prop=revisions" \
    --data-urlencode "rvprop=ids|timestamp" \
    --data-urlencode "rvlimit=1"
  )"

  echo "$json" |
    jq -c --argjson pageId "$page_id" '
      .query.pages | to_entries[0].value |
      select(.missing != true and .revisions != null) |
      {
        type:"page",
        pageId:$pageId,
        revision:.revisions[0].revid,
        title:.title,
        lastModified:.revisions[0].timestamp
      }
    '
done <<< "$page_ids"

# Forward delete/move events for the downstream handler.
jq -c 'select(.type == "delete" or .type == "move")' "$tmp_changes"

# Persist this cursor only after the downstream pipeline successfully handles
# all preceding records.
jq -cn --argjson rcid "$max_rcid" '{type:"cursor", rcid:$rcid}'
