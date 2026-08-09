#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 <fandom-base-url> [output-directory]" >&2
  exit 2
fi

BASE="${1%/}"
OUTPUT_DIR="${2:-export}"
API="$BASE/api.php"
ROOT_CATEGORY="Kategorie:Kategorien"

for cmd in curl jq html2text awk sort mktemp sed; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "ERROR: Required command '$cmd' was not found." >&2
    exit 127
  }
done

mkdir -p "$OUTPUT_DIR"

api() {
  sleep 0.25
  curl -fsSLG \
    --retry 10 \
    --retry-max-time 300 \
    --retry-all-errors \
    --user-agent "NafetskysArchivGitHubBackup/1.0" \
    --data-urlencode "format=json" \
    "$API" "$@"
}

safe_name() {
  local value="$1"

  # Invalid in Windows file/directory names: < > : " / \ | ? *
  # Remove them instead of replacing them.
  value="$(printf '%s' "$value" | tr -d '<>:"/\\|?*')"

  # Remove ASCII control characters (0x00-0x1F).
  value="$(printf '%s' "$value" | tr -d '\000-\037')"

  # Windows does not allow trailing spaces or dots.
  while [[ "$value" == *" " || "$value" == *"." ]]; do
    value="${value%?}"
  done

  [[ "$value" == "." ]] && value="_"
  [[ "$value" == ".." ]] && value="__"
  [[ -z "$value" ]] && value="_"

  # Reserved Windows device names are invalid even with an extension.
  case "${value^^}" in
    CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])
      value="_${value}"
      ;;
  esac

  printf '%s' "$value"
}

category_name() {
  local title="$1"
  title="${title#Kategorie:}"
  title="${title#Category:}"
  printf '%s' "$title"
}

CATEGORY_PATHS="$(mktemp)"
QUEUE="$(mktemp)"
NEXT_QUEUE="$(mktemp)"

cleanup() {
  rm -f "$CATEGORY_PATHS" "$QUEUE" "$NEXT_QUEUE"
}
trap cleanup EXIT

printf '%s\t%s\n' "$ROOT_CATEGORY" "" > "$CATEGORY_PATHS"
printf '%s\t%s\n' "$ROOT_CATEGORY" "" > "$QUEUE"

category_seen() {
  local category="$1"
  awk -F $'\t' -v category="$category" '
    $1 == category { found=1; exit }
    END { exit !found }
  ' "$CATEGORY_PATHS"
}

while [[ -s "$QUEUE" ]]; do
  : > "$NEXT_QUEUE"

  sort -t $'\t' -k2,2 -k1,1 "$QUEUE" |
  while IFS=$'\t' read -r parent parent_path; do
    cont=""

    while :; do
      args=(
        --data-urlencode "action=query"
        --data-urlencode "list=categorymembers"
        --data-urlencode "cmtitle=$parent"
        --data-urlencode "cmtype=subcat"
        --data-urlencode "cmlimit=max"
      )

      [[ -n "$cont" ]] && args+=(--data-urlencode "cmcontinue=$cont")

      json="$(api "${args[@]}")"

      while IFS= read -r child; do
        [[ -z "$child" ]] && continue

        if category_seen "$child"; then
          continue
        fi

        child_name="$(category_name "$child")"
        child_dir="$(safe_name "$child_name")"

        if [[ -n "$parent_path" ]]; then
          child_path="$parent_path/$child_dir"
        else
          child_path="$child_dir"
        fi

        printf '%s\t%s\n' "$child" "$child_path" >> "$CATEGORY_PATHS"
        printf '%s\t%s\n' "$child" "$child_path" >> "$NEXT_QUEUE"
      done < <(jq -r '.query.categorymembers[]?.title' <<< "$json")

      cont="$(jq -r '.continue.cmcontinue // empty' <<< "$json")"
      [[ -z "$cont" ]] && break
    done
  done

  mv "$NEXT_QUEUE" "$QUEUE"
  NEXT_QUEUE="$(mktemp)"
done

while IFS= read -r event; do
  [[ -z "$event" ]] && continue

  type="$(jq -r '.type // empty' <<< "$event")"
  [[ "$type" != "page" ]] && continue

  page_id="$(jq -r '.pageId' <<< "$event")"

  meta_json="$(api \
    --data-urlencode "action=query" \
    --data-urlencode "pageids=$page_id" \
    --data-urlencode "prop=revisions|categories" \
    --data-urlencode "rvprop=ids|timestamp" \
    --data-urlencode "rvlimit=1" \
    --data-urlencode "cllimit=max"
  )"

  missing="$(jq -r '.query.pages | to_entries[0].value.missing // false' <<< "$meta_json")"
  if [[ "$missing" == "true" ]]; then
    echo "WARN: pageId=$page_id no longer exists; skipping." >&2
    continue
  fi

  title="$(jq -r '.query.pages | to_entries[0].value.title' <<< "$meta_json")"

  parse_json="$(api \
    --data-urlencode "action=parse" \
    --data-urlencode "pageid=$page_id" \
    --data-urlencode "prop=text"
  )"

  if jq -e '.error' >/dev/null <<< "$parse_json"; then
    echo "ERROR: Could not parse pageId=$page_id ($title):" >&2
    jq -c '.error' <<< "$parse_json" >&2
    exit 1
  fi

  html="$(jq -r '.parse.text["*"] // empty' <<< "$parse_json")"

  if [[ -z "$html" ]]; then
    echo "ERROR: Fandom returned no parsed text for pageId=$page_id ($title)." >&2
    exit 1
  fi

  text="$(
    printf '%s' "$html" |
      html2text -utf8 -width 10000 |
      sed -e 's/[[:space:]]\+$//'
  )"

  chosen_path="$(
    while IFS= read -r category; do
      [[ -z "$category" ]] && continue

      awk -F $'\t' -v category="$category" '
        $1 == category {
          path=$2
          depth=(path == "" ? 0 : split(path, parts, "/"))
          print depth "\t" path
          exit
        }
      ' "$CATEGORY_PATHS"
    done < <(
      jq -r '.query.pages | to_entries[0].value.categories[]?.title' <<< "$meta_json"
    ) |
      sort -t $'\t' -k1,1n -k2,2 |
      head -n 1 |
      cut -f2-
  )"

  target_dir="$OUTPUT_DIR"
  [[ -n "$chosen_path" ]] && target_dir="$OUTPUT_DIR/$chosen_path"
  mkdir -p "$target_dir"

  filename="$(safe_name "$title").json"
  target="$target_dir/$filename"
  tmp_target="$target.tmp"

  jq \
    --arg text "$text" \
    '
      .query.pages
      | to_entries[0].value
      | {
          title: .title,
          pageId: .pageid,
          revision: .revisions[0].revid,
          lastModified: .revisions[0].timestamp,
          categories: [
            .categories[]?.title
            | sub("^(Kategorie|Category):"; "")
          ],
          text: $text
        }
    ' <<< "$meta_json" > "$tmp_target"

  mv -f "$tmp_target" "$target"

  echo "Wrote: $target" >&2
done
