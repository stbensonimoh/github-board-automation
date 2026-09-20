#!/usr/bin/env bats

# Fixture suite for scripts/parse-linked.sh per SPEC Testing Strategy.
# The parser takes a PR body as an argument (or on stdin), makes zero network
# calls, and prints one issue number per line.

PARSER="$BATS_TEST_DIRNAME/../scripts/parse-linked.sh"
export PARSER

# Argument form: the PR body as $1. One ref per line in $output.
run_body() {
  run bash "$PARSER" "$1"
}

@test "close #1 matches" {
  run_body 'close #1'
  [ "$output" = "1" ]
}

@test "closes #12 matches" {
  run_body 'closes #12'
  [ "$output" = "12" ]
}

@test "closed #13 matches" {
  run_body 'closed #13'
  [ "$output" = "13" ]
}

@test "fix #2 matches" {
  run_body 'fix #2'
  [ "$output" = "2" ]
}

@test "fixes #3 matches" {
  run_body 'fixes #3'
  [ "$output" = "3" ]
}

@test "fixed #4 matches" {
  run_body 'fixed #4'
  [ "$output" = "4" ]
}

@test "resolve #5 matches" {
  run_body 'resolve #5'
  [ "$output" = "5" ]
}

@test "resolves #44 matches" {
  run_body 'resolves #44'
  [ "$output" = "44" ]
}

@test "Resolved #45 matches (mixed case)" {
  run_body 'Resolved #45'
  [ "$output" = "45" ]
}

@test "CLOSES #6 matches (shouty case)" {
  run_body 'CLOSES #6'
  [ "$output" = "6" ]
}

@test "multiple refs on one line yield one number per line in order" {
  run_body 'closes #1 fixes #2 resolves #3'
  [ "$output" = $'1\n2\n3' ]
}

@test "bare #7 does not match" {
  run_body 'see #7 for context'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "closes#1 without whitespace does not match" {
  run_body 'closes#1'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "closes owner/repo#9 cross repo does not match" {
  run_body 'closes owner/repo#9'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "fixes owner/repo#9 #12 cross repo consumes the keyword, nothing matches" {
  run_body 'fixes owner/repo#9 #12'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "closing #10 gerund does not match" {
  run_body 'closing #10'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "prefix #7 embedded keyword does not match" {
  run_body 'prefix #7'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "unfixed #4 embedded keyword does not match" {
  run_body 'unfixed #4'
  [ -z "$output" ]
}

@test "Fixes: #12 colon form matches (GitHub documented form)" {
  run_body 'Fixes: #12'
  [ "$output" = "12" ]
}

@test "closes: #1 lowercase colon form matches" {
  run_body 'closes: #1'
  [ "$output" = "1" ]
}

@test "no keyword means zero exit, not an error" {
  run_body 'just a mention of #7'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "empty body exits zero" {
  run_body ''
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "non ascii letter before keyword is not a boundary" {
  run_body 'éfixes #12'
  [ -z "$output" ]
}

@test "argument form and stdin form agree" {
  body='Closes #12 and fixes #3'
  run_body "$body"
  arg_out="$output"
  BODY="$body" run bash -c 'printf %s "$BODY" | bash "$PARSER"'
  [ "$output" = "$arg_out" ]
  [ "$output" = $'12\n3' ]
}
@test "empty body yields empty output" {
  run_body ''
  [ -z "$output" ]
}

@test "multiline body matches per line" {
  run_body $'summary text\n\nCloses #12\n\nalso fixes #3 later'
  [ "$output" = $'12\n3' ]
}
