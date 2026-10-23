#!/usr/bin/env bash
f="$1"
B="$2"
a=$("$B/relcl/lint.pre-relclfix" "$f" >/dev/null 2>&1; echo $?)
b=$(bin/lesson-overreach-lint "$f" >/dev/null 2>&1; echo $?)
if [ "$a" != "$b" ]; then printf 'FLIP %s pre=%s post=%s\n' "$f" "$a" "$b"; fi
