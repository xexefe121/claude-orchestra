#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 0 ]; then printf 'Usage: uninstall.sh\n' >&2; exit 1; fi
claude_root="$HOME/.claude"
backup_path() {
    local candidate="$1.bak-$(date -u +%Y%m%d-%H%M%S)-$$"
    while [ -e "$candidate" ] || [ -L "$candidate" ]; do candidate="$candidate-1"; done
    printf '%s' "$candidate"
}
destination="$claude_root/skills/orchestra"
if [ -e "$destination" ] || [ -L "$destination" ]; then
    backup=$(backup_path "$destination")
    mv -- "$destination" "$backup"
    printf 'Removed active skill; backup: %s\n' "$backup"
else
    printf 'Already absent: orchestra\n'
fi
temp_file=''
cleanup() { if [ -n "$temp_file" ]; then rm -f -- "$temp_file"; fi; }
trap cleanup EXIT
for name in AGENTS.md CLAUDE.md; do
    rule_path="$claude_root/$name"
    if [ ! -f "$rule_path" ]; then continue; fi
    if ! grep -Eq '^<!-- orchestra:start -->[[:space:]]*$' "$rule_path" ||
       ! grep -Eq '^<!-- orchestra:end -->[[:space:]]*$' "$rule_path"; then continue; fi
    temp_file=$(mktemp "$claude_root/.orchestra-uninstall.XXXXXXXX")
    awk '/^<!-- orchestra:start -->[[:space:]]*$/ {active=1; next}
         /^<!-- orchestra:end -->[[:space:]]*$/ && active {active=0; next}
         !active {print}' "$rule_path" > "$temp_file"
    backup=$(backup_path "$rule_path")
    cp -p -- "$rule_path" "$backup"
    cat "$temp_file" > "$rule_path"
    rm -f -- "$temp_file"
    temp_file=''
    printf 'Rule removed: %s; backup: %s\n' "$rule_path" "$backup"
done
printf 'Uninstalled. Backups remain beside original folders and rule files.\n'
