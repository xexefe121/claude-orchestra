#!/usr/bin/env bash
set -euo pipefail

add_rule=false
case "${1:-}" in
    '') ;;
    --add-agents-rule) add_rule=true; shift ;;
    *) printf 'Usage: install.sh [--add-agents-rule]\n' >&2; exit 1 ;;
esac
if [ "$#" -ne 0 ]; then
    printf 'Usage: install.sh [--add-agents-rule]\n' >&2
    exit 1
fi

download_root=''
cleanup() {
    if [ -n "$download_root" ]; then
        rm -rf -- "$download_root"
    fi
}
trap cleanup EXIT
source_root=''
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    source_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
fi
if [ -z "$source_root" ] || [ ! -f "$source_root/skills/orchestra/scripts/codex-run.py" ]; then
    download_root=$(mktemp -d "${TMPDIR:-/tmp}/orchestra-install.XXXXXXXX")
    curl -fsSL https://github.com/xexefe121/claude-orchestra/archive/refs/heads/main.tar.gz -o "$download_root/main.tar.gz"
    tar -xzf "$download_root/main.tar.gz" -C "$download_root"
    source_root="$download_root/claude-orchestra-main"
fi
for required in skills/orchestra/scripts/codex-run.py docs/AGENTS-snippet.md; do
    if [ ! -f "$source_root/$required" ]; then
        printf 'Package file missing: %s\n' "$required" >&2
        exit 1
    fi
done
snippet=$(awk '{sub(/\r$/, "")} /^<!-- orchestra:start -->$/ {active=1} active {print} /^<!-- orchestra:end -->$/ {exit}' "$source_root/docs/AGENTS-snippet.md")
if [[ "$snippet" != *'<!-- orchestra:start -->'* ]] || [[ "$snippet" != *'<!-- orchestra:end -->'* ]]; then
    printf 'Activation snippet markers missing.\n' >&2
    exit 1
fi

claude_root="$HOME/.claude"
destination="$claude_root/skills/orchestra"
mkdir -p -- "$claude_root/skills"
backup() {
    local path="$1" candidate
    candidate="$path.bak-$(date -u +%Y%m%d-%H%M%S)-$$"
    while [ -e "$candidate" ] || [ -L "$candidate" ]; do candidate="$candidate-1"; done
    mv -- "$path" "$candidate"
    printf 'Backup: %s\n' "$candidate"
}
if [ -e "$destination" ] || [ -L "$destination" ]; then backup "$destination"; fi
cp -R -- "$source_root/skills/orchestra" "$destination"
chmod +x "$destination/scripts/codex-run.py"
printf 'Installed: %s\n' "$destination"
if "$add_rule"; then
    rule_path="$claude_root/AGENTS.md"
    if [ ! -e "$rule_path" ] && [ -f "$claude_root/CLAUDE.md" ]; then rule_path="$claude_root/CLAUDE.md"; fi
    if [ -f "$rule_path" ] && grep -Eq '^<!-- orchestra:start -->[[:space:]]*$' "$rule_path"; then
        printf 'Rule already present: %s\n' "$rule_path"
    else
        printf '\n%s\n' "$snippet" >> "$rule_path"
        printf 'Rule added: %s\n' "$rule_path"
    fi
else
    printf 'Opt-in rule: run install.sh --add-agents-rule.\n'
fi
printf 'Prerequisites (nothing installed automatically):\n'
python_fix='brew install python (requires Homebrew: https://brew.sh)'
if command -v python3 >/dev/null 2>&1 && python3 -c 'import sys; sys.exit(sys.version_info < (3, 9))' >/dev/null 2>&1; then
    printf '[OK] python3 (3.9+)\n'
else
    printf '[MISSING] python3 (3.9+). Fix: %s\n' "$python_fix"
fi
for name in codex claude; do
    if command -v "$name" >/dev/null 2>&1; then
        printf '[OK] %s\n' "$name"
    elif [ "$name" = codex ]; then
        printf '[MISSING] codex. Fix: npm install -g @openai/codex; codex login\n'
    else
        printf '[MISSING] claude. Fix: curl -fsSL https://claude.ai/install.sh | bash\n'
    fi
done
printf 'Usage: /orchestra <project> <goal>\n'
