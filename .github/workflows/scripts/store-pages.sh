#!/usr/bin/env bash
set -Eeuo pipefail

# Reads NDJSON from stdin as produced by changes.sh.
#
# Usage:
#   ./changes.sh "https://nafetskys-archiv.fandom.com/de" 0 \
#     | ./store-pages.sh "https://nafetskys-archiv.fandom.com/de" export
#
# Processes only records with type="page".
# Other records (cursor/delete/move) are ignored here.

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 <fandom-base-url> [output-directory]" >&2
  exit 2
fi

BASE="${1%/}"
OUTPUT_DIR="${2:-export}"
API="$BASE/api.php"
ROOT_CATEGORY="Kategorie:Kategorien"

for cmd in curl jq mktemp sort awk cut head; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "ERROR: Required command '$cmd' was not found." >&2
    exit 127
  }
done

mkdir -p "$OUTPUT_DIR"

api() {
  curl -fsSLG \
    --retry 3 \
    --retry-delay 1 \
    --data-urlencode "format=json" \
    "$API" \
    "$@"
}

safe_name() {
  local value="$1"

  value="${value//\//_}"
  value="${value//\\/_}"
  value="${value//$'\n'/ }"
  value="${value//$'\r'/ }"
  value="${value//$'\t'/ }"
  value="${value//:/ -}"

  [[ "$value" == "." ]] && value="_"
  [[ "$value" == ".." ]] && value="__"
  [[ -z "$value" ]] && value="_"

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
INPUT="$(mktemp)"

cleanup() {
  rm -f "$CATEGORY_PATHS" "$QUEUE" "$NEXT_QUEUE" "$INPUT"
}
trap cleanup EXIT

# Root category itself maps to the export root.
printf '%s\t%s\n' "$ROOT_CATEGORY" "" > "$CATEGORY_PATHS"
printf '%s\t%s\n' "$ROOT_CATEGORY" "" > "$QUEUE"

category_seen() {
  local category="$1"
  awk -F $'\t' -v category="$category" \
    '$1 == category { found=1; exit } END { exit !found }' \
    "$CATEGORY_PATHS"
}

# Breadth-first walk from Kategorie:Kategorien.
# The first discovered path to a category is therefore a shortest path.
while [[ -s "$QUEUE" ]]; do
  : > "$NEXT_QUEUE"

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
        category_seen "$child" && continue

        child_name="$(category_name "$child")"
        child_dir="$(safe_name "$child_name")"

        if [[ -n "$parent_path" ]]; then
          child_path="$parent_path/$child_dir"
        else
          child_path="$child_dir"
        fi

        printf '%s\t%s\n' "$child" "$child_path" >> "$CATEGORY_PATHS"
        printf '%s\t%s\n' "$child" "$child_path" >> "$NEXT_QUEUE"
      done < <(echo "$json" | jq -r '.query.categorymembers[].title')

      cont="$(echo "$json" | jq -r '.continue.cmcontinue // empty')"
      [[ -z "$cont" ]] && break
    done
  done < <(sort -t $'\t' -k1,1 "$QUEUE")

  cp "$NEXT_QUEUE" "$QUEUE"
done

# Buffer stdin so the caller can pipe changes.sh directly into us.
cat > "$INPUT"

while IFS= read -r event; do
  [[ -z "$event" ]] && continue

  type="$(jq -r '.type // empty' <<< "$event")"
  [[ "$type" != "page" ]] && continue

  page_id="$(jq -r '.pageId' <<< "$event")"

  # Fetch current revision metadata, categories and full plain text.
  json="$(api \
    --data-urlencode "action=query" \
    --data-urlencode "pageids=$page_id" \
    --data-urlencode "prop=revisions|categories|extracts" \
    --data-urlencode "rvprop=ids|timestamp" \
    --data-urlencode "rvlimit=1" \
    --data-urlencode "cllimit=max" \
    --data-urlencode "explaintext=1" \
    --data-urlencode "exsectionformat=plain"
  )"

  missing="$(echo "$json" | jq -r '.query.pages | to_entries[0].value.missing // false')"
  if [[ "$missing" == "true" ]]; then
    echo "WARN: pageId=$page_id no longer exists; skipping." >&2
    continue
  fi

  title="$(echo "$json" | jq -r '.query.pages | to_entries[0].value.title')"

  # For every category of the page, look up its path from Kategorie:Kategorien.
  # Pick the path with the fewest directory components.
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
      echo "$json" |
        jq -r '.query.pages | to_entries[0].value.categories[]?.title'
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

  echo "$json" |
    jq '
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
          text: (.extract // "")
        }
    ' > "$tmp_target"

  mv -f "$tmp_target" "$target"
  echo "Wrote: $target" >&2

done < "$INPUT"
