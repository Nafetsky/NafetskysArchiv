#!/usr/bin/env bash
set -Eeuo pipefail

# Combines all exported page JSON files into one JSON tree.
#
# Usage:
#   ./combine-export.sh [input-directory] [output-file]
#
# Example:
#   ./combine-export.sh export fandom-export.json
#
# Output shape:
# {
#   "_files": [ ... pages directly in export/ ... ],
#   "Abenteuer": {
#     "_files": [ ... pages directly in export/Abenteuer ... ],
#     "Von eigenen Gnaden": {
#       "_files": [ ... ]
#     }
#   }
# }

INPUT_DIR="${1:-export}"
OUTPUT_FILE="${2:-fandom-export.json}"

for cmd in jq find sort mktemp dirname realpath; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "ERROR: Required command '$cmd' was not found." >&2
    exit 127
  }
done

if [[ ! -d "$INPUT_DIR" ]]; then
  echo "ERROR: Input directory does not exist: $INPUT_DIR" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

echo '{}' > "$TMP_DIR/result.json"

ensure_path() {
  local relative_dir="$1"
  local tmp="$TMP_DIR/update.json"

  if [[ -z "$relative_dir" || "$relative_dir" == "." ]]; then
    jq '
      if has("_files") then .
      else . + {"_files":[]}
      end
    ' "$TMP_DIR/result.json" > "$tmp"
  else
    local path_json
    path_json="$(
      printf '%s' "$relative_dir" |
        jq -R 'split("/")'
    )"

    jq --argjson p "$path_json" '
      def ensure($path):
        if ($path | length) == 0 then
          if has("_files") then .
          else . + {"_files":[]}
          end
        else
          ($path[0]) as $head
          | ($path[1:]) as $tail
          | .[$head] = ((.[$head] // {}) | ensure($tail))
        end;

      ensure($p)
    ' "$TMP_DIR/result.json" > "$tmp"
  fi

  mv "$tmp" "$TMP_DIR/result.json"
}

while IFS= read -r dir; do
  relative="${dir#"$INPUT_DIR"}"
  relative="${relative#/}"
  [[ -z "$relative" ]] && relative="."
  ensure_path "$relative"
done < <(find "$INPUT_DIR" -type d -print | sort)

while IFS= read -r file; do
  if [[ "$(realpath -m "$file")" == "$(realpath -m "$OUTPUT_FILE")" ]]; then
    continue
  fi

  if ! jq -e . "$file" >/dev/null 2>&1; then
    echo "ERROR: Invalid JSON: $file" >&2
    exit 1
  fi

  relative_file="${file#"$INPUT_DIR"/}"
  relative_dir="$(dirname "$relative_file")"
  tmp="$TMP_DIR/update.json"

  if [[ "$relative_dir" == "." ]]; then
    jq --slurpfile page "$file" '
      ._files += $page
    ' "$TMP_DIR/result.json" > "$tmp"
  else
    path_json="$(
      printf '%s' "$relative_dir" |
        jq -R 'split("/")'
    )"

    jq       --argjson p "$path_json"       --slurpfile page "$file" '
        def add_page($path; $page):
          if ($path | length) == 0 then
            ._files += $page
          else
            ($path[0]) as $head
            | ($path[1:]) as $tail
            | .[$head] = (.[$head] | add_page($tail; $page))
          end;

        add_page($p; $page)
      ' "$TMP_DIR/result.json" > "$tmp"
  fi

  mv "$tmp" "$TMP_DIR/result.json"
done < <(find "$INPUT_DIR" -type f -name '*.json' -print | sort)

TMP_OUTPUT="${OUTPUT_FILE}.tmp"
jq '.' "$TMP_DIR/result.json" > "$TMP_OUTPUT"
mv -f "$TMP_OUTPUT" "$OUTPUT_FILE"

echo "Wrote combined export: $OUTPUT_FILE" >&2
