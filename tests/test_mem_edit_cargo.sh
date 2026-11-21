#!/usr/bin/env bash
# test_mem_edit_cargo.sh — `mem edit` carries frontmatter fields it does
# not model through an edit as untouched cargo, instead of rebuilding the
# block from its own key list. First fired on responder-written person files
# (2026-09-30 05:12Z, memory 52af011c): an edit dropped person_key and
# aliases, exit 0, the file kept id and type so nothing looked wrong, the
# responder stopped claiming the file, and that person's next message minted
# a duplicate while the edited body sat orphaned. A multiline list also bled:
# the updated: collector greps list items anywhere in the block, so alias
# items became updated entries. Mirrors tests/test_mem_edit_flags.sh.
# No LLM calls, no docker.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(dirname "$HERE")"
export PATH="$REPO/bin:$PATH"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
export MEM_DIR="$WORK/mem"; mkdir -p "$MEM_DIR"

# --- fixture 1: a responder-written person file rides an edit ---
cat > "$MEM_DIR/2026-09-30-05-00-00_00a100a1_notes-on-a-person.md" <<'EOF'
---
id: 00a100a1
summary: Notes on a person
type: person
person_key: slack:U0BF
aliases: []
created: 2026-09-30 05:00:00
updated: 2026-09-30 05:00:00
---

A person body.
EOF

mem edit 00a100a1 "new body from an edit" >/dev/null 2>&1 \
  && ok "edit of a person file exits 0" || bad "edit of a person file fails"
f1=$(grep -l '^id: 00a100a1$' "$MEM_DIR"/*.md | head -1)
grep -q '^person_key: slack:U0BF$' "$f1" && ok "person_key rides the edit" || bad "person_key dropped" "$(sed -n '1,12p' "$f1")"
grep -q '^aliases: \[\]$' "$f1" && ok "aliases ride the edit" || bad "aliases dropped" "$(sed -n '1,12p' "$f1")"
grep -q '^type: person$' "$f1" && ok "type rides" || bad "type lost"
grep -q '^created: 2026-09-30 05:00:00$' "$f1" && ok "created rides" || bad "created lost"
grep -q '^id: 00a100a1$' "$f1" && ok "id rides" || bad "id lost"
grep -q '^summary: new body from an edit$' "$f1" && ok "summary is the new first line" || bad "summary wrong" "$(sed -n '1,12p' "$f1")"
grep -q '^new body from an edit$' "$f1" && ok "the body is the new text" || bad "body wrong"
ub1=$(awk '/^---$/{c++} c==1 && /^updated:/{p=1;next} p && /^  - /{n++} p && !/^  - /{exit} END{print n+0}' "$f1")
[ "$ub1" = "2" ] && ok "updated became a two-entry list" || bad "updated list wrong" "items: $ub1"

# --- fixture 2: a multiline aliases list rides without bleeding into updated ---
cat > "$MEM_DIR/2026-09-30-05-01-00_00b200b2_second-person.md" <<'EOF'
---
id: 00b200b2
summary: Second person
type: person
person_key: slack:U0BFD
aliases:
  - nick
  - nick jalbert
created: 2026-09-30 05:01:00
updated: 2026-09-30 05:01:00
---

Second body.
EOF

mem edit 00b200b2 "second edited body" >/dev/null 2>&1
f2=$(grep -l '^id: 00b200b2$' "$MEM_DIR"/*.md | head -1)
grep -q '^person_key: slack:U0BFD$' "$f2" && ok "person_key rides (multiline aliases file)" || bad "person_key dropped 2" "$(sed -n '1,14p' "$f2")"
grep -q '^aliases:$' "$f2" && ok "the aliases: key rides as a key" || bad "aliases key dropped" "$(sed -n '1,14p' "$f2")"
grep -q '^  - nick jalbert$' "$f2" && ok "multiline alias items ride under aliases" || bad "alias items lost" "$(sed -n '1,14p' "$f2")"
ub=$(awk '/^---$/{c++} c==1 && /^updated:/{p=1;next} p && /^  - /{n++} p && !/^  - /{exit} END{print n+0}' "$f2")
[ "$ub" = "2" ] && ok "updated holds only its own entries, aliases not bled in" || bad "updated bled" "updated items: $ub"

# --- an unknown second-writer field rides too (the family claim) ---
cat > "$MEM_DIR/2026-09-30-05-01-30_00c300c3_third.md" <<'EOF'
---
id: 00c300c3
summary: Third note
type: note
vendor_meta: writes-back
created: 2026-09-30 05:01:30
updated: 2026-09-30 05:01:30
---

Third body.
EOF
mem edit 00c300c3 "third edited body" >/dev/null 2>&1
f2b=$(grep -l '^id: 00c300c3$' "$MEM_DIR"/*.md | head -1)
grep -q '^vendor_meta: writes-back$' "$f2b" \
  && ok "an unknown second-writer field rides (the family claim)" || bad "unknown field dropped" "$(sed -n '1,14p' "$f2b")"

# --- fixture 3: until rides through the cargo path ---
mem add --type todo --until 2026-10-04 "cargo until probe body" >/dev/null 2>&1
id3=$(sed -n 's/^id: //p' "$MEM_DIR"/2026-*_cargo-until-probe-body.md | head -1)
mem edit "$id3" "cargo until probe body, edited" >/dev/null 2>&1
f3=$(grep -l "^id: $id3$" "$MEM_DIR"/*.md | head -1)
grep -q '^until: 2026-10-04$' "$f3" && ok "until rides the cargo path" || bad "until lost" "$(sed -n '1,12p' "$f3")"
grep -q '^type: todo$' "$f3" && ok "type rides the cargo path" || bad "type lost 3"

# --- fixture 4: a frontmatter with no summary line gains one ---
cat > "$MEM_DIR/2026-09-30-05-02-00_9d3f00c3_no-summary.md" <<'EOF'
---
id: 9d3f00c3
type: note
person_key: slack:U99999
created: 2026-09-30 05:02:00
---

Body four.
EOF

mem edit 9d3f00c3 "body four edited" >/dev/null 2>&1
f4=$(grep -l '^id: 9d3f00c3$' "$MEM_DIR"/*.md | head -1)
grep -q '^summary: body four edited$' "$f4" \
  && ok "a summary line is written when none existed" || bad "summary insert" "$(sed -n '1,10p' "$f4")"
grep -q '^person_key: slack:U99999$' "$f4" && ok "cargo rides the insert path" || bad "cargo lost 4"

# --- fixture 5: a file with no frontmatter at all gains a minimal block ---
printf 'no frontmatter here\n' > "$MEM_DIR/2026-09-30-05-04-00_7c1a55d4_bare.md"
mem edit 7c1a55d4 "bare file edited" >/dev/null 2>&1
f5=$(ls "$MEM_DIR"/*_7c1a55d4_*.md | head -1)
head -1 "$f5" | grep -q '^---$' && ok "a bare file gains a frontmatter block" || bad "no block" "$(cat "$f5")"
grep -q '^summary: bare file edited$' "$f5" && ok "the bare file's summary is written" || bad "bare summary"
grep -q '^bare file edited$' "$f5" && ok "the bare file's body is the new text" || bad "bare body"

# --- fixture 6: a frontmatter block that never closes is refused ---
cat > "$MEM_DIR/2026-09-30-05-05-00_2b8e66c5_unclosed.md" <<'EOF'
---
id: 2b8e66c5
summary: unclosed block
type: note
person_key: slack:U77777

Body six.
EOF
cp "$MEM_DIR/2026-09-30-05-05-00_2b8e66c5_unclosed.md" "$WORK/unclosed.orig"
mem edit 2b8e66c5 "edited into corruption" >/dev/null 2>&1
rc=$?
[ $rc -ne 0 ] && ok "an unterminated frontmatter block is refused (rc=$rc)" || bad "unclosed block accepted"
cmp -s "$MEM_DIR/2026-09-30-05-05-00_2b8e66c5_unclosed.md" "$WORK/unclosed.orig" \
  && ok "the refused edit left the file untouched" || bad "unclosed file mangled"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
