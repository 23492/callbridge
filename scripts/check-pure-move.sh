#!/bin/bash
# Proves that splitting CallBridge/CallBridge/main.swift into several files was a pure move.
# Concatenates every *.swift file under CallBridge/CallBridge/ at <base-ref> and at <head-ref>
# (or the working tree when no head ref is given), drops blank lines, import lines and
# "// MARK: " lines, sorts the rest and diffs the two. Any edited, added or dropped
# statement shows up in the diff. Runs against the git repo of the current directory.
#
# Usage: scripts/check-pure-move.sh [--ignore <path>]... <base-ref> [<head-ref>]
#   --ignore <path>  leave this file (relative to the repo root) out of the head side;
#                    a path that does not exist is not an error.
set -euo pipefail

usage() {
    echo "usage: $0 [--ignore <path>]... <base-ref> [<head-ref>]" >&2
    exit 2
}

SRC_DIR=CallBridge/CallBridge
IGNORES=()
POSITIONAL=()
while [ $# -gt 0 ]; do
    case "$1" in
        --ignore)
            [ $# -ge 2 ] || usage
            IGNORES+=("$2")
            shift 2
            ;;
        -h|--help) usage ;;
        *)
            POSITIONAL+=("$1")
            shift
            ;;
    esac
done
[ ${#POSITIONAL[@]} -ge 1 ] && [ ${#POSITIONAL[@]} -le 2 ] || usage
BASE_REF="${POSITIONAL[0]}"
HEAD_REF="${POSITIONAL[1]:-}"

git rev-parse --git-dir >/dev/null 2>&1 || { echo "check-pure-move: not inside a git repo" >&2; exit 2; }
git rev-parse --verify --quiet "${BASE_REF}^{commit}" >/dev/null || { echo "check-pure-move: unknown base ref '$BASE_REF'" >&2; exit 2; }
if [ -n "$HEAD_REF" ]; then
    git rev-parse --verify --quiet "${HEAD_REF}^{commit}" >/dev/null || { echo "check-pure-move: unknown head ref '$HEAD_REF'" >&2; exit 2; }
fi

is_ignored() {
    local p="$1" i
    for i in ${IGNORES[@]+"${IGNORES[@]}"}; do
        [ "$p" = "$i" ] && return 0
    done
    return 1
}

# Strip blank, import and MARK lines (judged on the trimmed form), then sort bytewise.
normalize() {
    awk '{
        t = $0
        sub(/^[ \t\r]+/, "", t)
        sub(/[ \t\r]+$/, "", t)
        if (t == "") next
        if (index(t, "import ") == 1) next
        if (index(t, "// MARK: ") == 1) next
        print
    }' | LC_ALL=C sort
}

dump_ref() {
    local ref="$1" path
    git ls-tree -r --name-only "$ref" -- "$SRC_DIR" | grep -E '\.swift$' | LC_ALL=C sort | while IFS= read -r path; do
        git show "${ref}:${path}"
        echo
    done
}

dump_head() {
    local path
    if [ -n "$HEAD_REF" ]; then
        git ls-tree -r --name-only "$HEAD_REF" -- "$SRC_DIR" | grep -E '\.swift$' | LC_ALL=C sort | while IFS= read -r path; do
            is_ignored "$path" && continue
            git show "${HEAD_REF}:${path}"
            echo
        done
    else
        [ -d "$SRC_DIR" ] || return 0
        find "$SRC_DIR" -type f -name '*.swift' | LC_ALL=C sort | while IFS= read -r path; do
            path="${path#./}"
            is_ignored "$path" && continue
            cat "$path"
            echo
        done
    fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

dump_ref "$BASE_REF" | normalize > "$TMP/base.txt"
dump_head | normalize > "$TMP/head.txt"

if diff "$TMP/base.txt" "$TMP/head.txt"; then
    echo "PURE MOVE OK ($(wc -l < "$TMP/base.txt" | tr -d ' ') lines compared; base $BASE_REF, head ${HEAD_REF:-working tree})"
    exit 0
else
    echo ""
    echo "NOT A PURE MOVE: lines above differ ('<' only in $BASE_REF, '>' only in ${HEAD_REF:-working tree})"
    exit 1
fi
