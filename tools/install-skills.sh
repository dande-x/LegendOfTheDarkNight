#!/usr/bin/env bash
# Install ai-dev-kit skills into a target agent's discovery directory.
#
# Source:  <workspace>/skills/<name>/
# Target:  <workspace>/.<tool>/skills/<name>/  (symlink -> source, copy on fallback)
#
# Usage:
#   ./install-skills.sh <claude|codex|cursor|gemini|all>
#
# This script is invoked by the ai-dev-kit installer tooling, not by end users
# directly. It assumes cwd-independence -- paths are resolved relative to the
# script's own location.

set -euo pipefail

# This script is POSIX-only (Linux / macOS). On Windows, callers MUST use
# install-skills.ps1 directly -- not via bash. Git Bash / MSYS / Cygwin's
# `ln -s` falls back to a hard COPY on Windows (no native symlink support
# without elevation), which silently breaks source-tracking. Refuse to run.
case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*)
        echo "ERROR: install-skills.sh is POSIX-only." >&2
        echo "On Windows, run install-skills.ps1 instead:" >&2
        echo "  powershell -File tools/install-skills.ps1 $*" >&2
        exit 3
        ;;
esac

SUPPORTED_TOOLS=(claude codex cursor gemini)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE="$WORKSPACE/skills"

usage() {
    cat >&2 <<EOF
Usage: $(basename "$0") <tool>

tool:
  claude    install to .claude/skills/
  codex     install to .codex/skills/
  cursor    install to .cursor/skills/
  gemini    install to .gemini/skills/
  all       install to all of the above

Source skills directory: $SOURCE
EOF
    exit 1
}

install_for() {
    local tool="$1"
    local target_dir="$WORKSPACE/.${tool}/skills"

    # Safety: empty tool name would collapse target to '$WORKSPACE/./skills' = source.
    if [[ -z "$tool" ]]; then
        echo "ERROR: install_for called with empty tool name -- refusing (would destroy source)" >&2
        exit 2
    fi

    [[ -d "$SOURCE" ]] || { echo "ERROR: source not found: $SOURCE" >&2; exit 1; }

    # Safety: target must NOT resolve to source. If they collide, rm -rf below
    # would delete source files thinking they're stale targets.
    local resolved_target resolved_source
    resolved_target="$(cd "$(dirname "$target_dir")" 2>/dev/null && pwd)/$(basename "$target_dir")"
    resolved_source="$(cd "$SOURCE" && pwd)"
    if [[ "${resolved_target%/}" == "${resolved_source%/}" ]]; then
        echo "ERROR: refusing: target [$resolved_target] equals source [$resolved_source]" >&2
        exit 2
    fi

    mkdir -p "$target_dir"

    local installed=0
    for skill in "$SOURCE"/*/; do
        local name
        name="$(basename "$skill")"

        local dest="$target_dir/$name"

        # Remove existing entry (symlink, dir, or junction-as-dir) before re-creating.
        if [[ -L "$dest" || -e "$dest" ]]; then
            rm -rf "$dest"
        fi

        # POSIX symlink. (Windows users should use install-skills.ps1 directly;
        # see the dispatcher at the top of this script.)
        if ln -s "$skill" "$dest" 2>/dev/null; then
            :
        else
            # Final fallback: hard copy (FAT32, network share, perm issues, etc.)
            cp -r "$skill" "$dest"
        fi
        installed=$((installed + 1))
    done

    echo "[install-skills] $tool: installed=$installed target=$target_dir"
}

[[ $# -eq 1 ]] || usage

# Normalize to lowercase (matches install-skills.ps1 behavior). POSIX `case` is
# case-sensitive; without this `CODEX` would fall through to the unknown branch.
arg_lower="$(echo "$1" | tr '[:upper:]' '[:lower:]')"

case "$arg_lower" in
    all)
        for t in "${SUPPORTED_TOOLS[@]}"; do
            install_for "$t"
        done
        ;;
    claude|codex|cursor|gemini)
        install_for "$arg_lower"
        ;;
    -h|--help)
        usage
        ;;
    *)
        echo "ERROR: unknown tool '$1'" >&2
        usage
        ;;
esac
