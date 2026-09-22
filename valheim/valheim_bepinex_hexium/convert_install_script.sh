#!/bin/bash

input="install_script.sh"
output="install_script_oneline.txt"

[[ -f "$input" ]] || {
    printf 'Error: %s not found\n' "$input" >&2
    exit 1
}

{
    printf '"script": "'

    while IFS= read -r line || [[ -n "$line" ]]; do
        # Strip CR left behind when input uses CRLF.
        line="${line%$'\r'}"

        # JSON escaping + Pterodactyl-style escaped slashes.
        line="${line//\\/\\\\}"
        line="${line//\"/\\\"}"
        line="${line//\//\\/}"
        line="${line//$'\t'/\\t}"

        printf '%s\\r\\n' "$line"
    done < "$input"

    printf '",'
} > "$output"

printf 'Created %s\n' "$output"