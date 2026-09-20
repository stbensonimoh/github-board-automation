#!/usr/bin/env bash
# Pure close keyword parser for PR bodies.
#
# Input: PR body on stdin, or as the first argument.
# Output: one issue number per line, for every same repo close reference.
# Contract: zero network calls so the workflow and tests share this file.
#
# The keyword set is normative in SPEC.md (Code Style): close, closes, closed,
# fix, fixes, fixed, resolve, resolves, resolved, case insensitive, each with a
# leading boundary and followed by an optional colon (GitHub documents
# "Closes: #10") then whitespace then #N. The locale is pinned so the
# non ASCII boundary test behaves the same everywhere. No trailing terminator:
# [0-9]+ is greedy, so consuming the separator would drop a second reference on
# the same line. Keywords followed by owner/repo#N are cross repo close refs,
# out of scope by design, and they consume the keyword, so a trailing bare #N
# after one is a plain mention, not a close ref.
set -euo pipefail

parse_linked() {
  LC_ALL=C.UTF-8 grep -oEi '(^|[^[:alnum:]_])(closes?|closed|fix(es|ed)?|resolves?|resolved):?[[:space:]]+#[0-9]+' \
    | grep -oE '[0-9]+' || true
}

if [ $# -ge 1 ]; then
  printf '%s' "$1" | parse_linked
else
  parse_linked
fi
