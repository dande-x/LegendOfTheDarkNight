#!/usr/bin/env bash
# Install ai-dev-kit skills into a target agent's discovery directory.
#
# Phase 1: Move skills from <workspace>/skills/ to <workspace>/.installer/skills/,
#           filtering out platform-excluded skills listed in
#           <workspace>/.installer/local-skill-filter.json (key = "linux" or "darwin").
# Phase 2: Create symlinks from <workspace>/.<tool>/skills/<name>/
#           pointing to <workspace>/.installer/skills/<name>/ (copy fallback).
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
RAW_SOURCE="$WORKSPACE/skills"
INSTALLER_DIR="$WORKSPACE/.installer"
SOURCE="$INSTALLER_DIR/skills"
FILTER_CONFIG="$INSTALLER_DIR/local-skill-filter.json"

# Detect platform key for filter config.
case "$(uname -s 2>/dev/null)" in
    Darwin*) PLATFORM_KEY="darwin" ;;
    *)       PLATFORM_KEY="linux" ;;
esac

# --------------------------------------------------------------------------- #
# Phase 1: Move skills/ -> .installer/skills/ with platform filtering
# --------------------------------------------------------------------------- #

get_excluded_skills() {
    # Reads exclude_skills.$PLATFORM_KEY from the filter config.
    # Outputs one skill name per line. Empty output = no filtering.
    #
    # Pure bash/sed -- no python3/jq dependency. Works because the config
    # structure is a simple flat JSON with string arrays.
    if [[ ! -f "$FILTER_CONFIG" ]]; then
        return
    fi

    # Extract the array value for the platform key, then pull out quoted strings.
    # 1. Collapse the file to one line
    # 2. Extract everything between "platform_key": [ ... ]
    # 3. Pull out quoted skill names
    local content
    content="$(tr -d '\n\r' < "$FILTER_CONFIG" 2>/dev/null)" || return 0
    local array
    array="$(echo "$content" | sed -n 's/.*"'"$PLATFORM_KEY"'"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p' 2>/dev/null)" || return 0
    if [[ -z "$array" ]]; then
        return
    fi
    echo "$array" | grep -o '"[^"]*"' | sed 's/"//g' || true
}

move_skills_to_installer() {
    [[ -d "$RAW_SOURCE" ]] || return 0

    # Build excluded list as a newline-delimited string (bash 3.2 compatible).
    local excluded_list
    excluded_list="$(get_excluded_skills)"

    mkdir -p "$SOURCE"

    local filtered=0
    for skill in "$RAW_SOURCE"/*/; do
        [[ -d "$skill" ]] || continue
        local name
        name="$(basename "$skill")"

        if echo "$excluded_list" | grep -qx "$name" 2>/dev/null; then
            filtered=$((filtered + 1))
            continue
        fi

        # Move skill directory to .installer/skills/.
        if [[ -e "$SOURCE/$name" ]]; then
            rm -rf "$SOURCE/$name"
        fi
        mv "$skill" "$SOURCE/$name"
    done

    # Move any remaining files (e.g. README).
    for file in "$RAW_SOURCE"/*; do
        [[ -e "$file" ]] || continue
        [[ -f "$file" ]] && mv "$file" "$SOURCE/$(basename "$file")"
    done

    # Remove the top-level skills/ directory. If non-empty (excluded skills left
    # behind), force-remove — excluded skills are not needed on this platform.
    if ! rmdir "$RAW_SOURCE" 2>/dev/null; then
        rm -rf "$RAW_SOURCE" 2>/dev/null || true
        echo "[install-skills] removed excluded skill directories from $RAW_SOURCE"
    fi

    if [[ $filtered -gt 0 ]]; then
        echo "[install-skills] filtered $filtered skill(s) for platform=$PLATFORM_KEY"
    fi
}

move_skills_to_installer

# --------------------------------------------------------------------------- #
# Phase 2: Create symlinks from .installer/skills/ to .<tool>/skills/
# --------------------------------------------------------------------------- #

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
        if ln -s "${skill%/}" "$dest" 2>/dev/null; then
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
