#!/usr/bin/env bash
# tests/test_traj_verify.sh — `traj verify` validates step signature chain.
# Tests: legacy trajectory, valid chain, tampered chain, wrong key, verbose mode.
# No LLM calls, no docker.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(dirname "$HERE")"
export PATH="$REPO/bin:$PATH"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

# ---- Helper: sha256 of a line ----
hash_line() { printf '%s' "$1" | openssl dgst -sha256 -r | cut -d' ' -f1; }

# ---- Signing key setup ----
SIGNING_KEY="46cf6fe78961cb6a3d46d54fd6f4579d18af2be5c3f1ea59dc6da47c640838cd"
mkdir -p "$WORK/secrets"
printf '%s' "$SIGNING_KEY" > "$WORK/secrets/traj_signing_key"

# ---- Test 1: Legacy trajectory (no prev_hash, no sig) ----
TRAJ_ID="cafe0000-0000-0000-0000-0000000000d1"
LEGACY_DIR="$WORK/trajectories/$TRAJ_ID"
mkdir -p "$LEGACY_DIR"
T="$LEGACY_DIR/trajectory.jsonl"
printf '{"step_id":"%s","type":"trajectory","ts":"2026-01-01T00:00:00Z"}\n' "$TRAJ_ID" > "$T"
printf '{"step_id":"s1","type":"thought","content":"legacy step 1","ts":"2026-01-01T00:00:01Z"}\n' >> "$T"
printf '{"step_id":"s2","type":"thought","content":"legacy step 2","ts":"2026-01-01T00:00:02Z"}\n' >> "$T"

export TRAJ_DIR="$WORK/trajectories" TRAJ_ID
export IDENTITY_DIR="$WORK"

out=$(traj verify 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok "legacy trajectory returns 0" || bad "legacy rc" "rc=$rc, out=$out"
echo "$out" | grep -q "UNVERIFIED" && ok "legacy trajectory marked UNVERIFIED" || bad "legacy status" "$out"

# ---- Test 2: Signed trajectory with valid key ----
# Build a properly signed chain where each step's prev_hash = hash of previous line
TRAJ_ID="cafe0000-0000-0000-0000-0000000000d2"
SIGNED_DIR="$WORK/trajectories/$TRAJ_ID"
mkdir -p "$SIGNED_DIR"
T="$SIGNED_DIR/trajectory.jsonl"

# Step 1: trajectory header
HEADER='{"step_id":"'"$TRAJ_ID"'","type":"trajectory","ts":"2026-01-01T00:00:00Z"}'
printf '%s\n' "$HEADER" > "$T"
PREV_HASH=$(hash_line "$HEADER")

# Step 2: first thought
STEP1='{"step_id":"s1","type":"thought","content":"signed step 1","ts":"2026-01-01T00:00:01Z"}'
CANON1=$(printf '%s' "$STEP1" | jq -c '. + {prev_hash: "'"$PREV_HASH"'"}')
SIG1=$(printf '%s' "$CANON1" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:$SIGNING_KEY" -binary | xxd -p -c 256)
STEP1_SIGNED=$(printf '%s' "$STEP1" | jq -c '. + {prev_hash: "'"$PREV_HASH"'", sig: "'"$SIG1"'"}')
printf '%s\n' "$STEP1_SIGNED" >> "$T"
PREV_HASH=$(hash_line "$STEP1_SIGNED")

# Step 3: second thought
STEP2='{"step_id":"s2","type":"thought","content":"signed step 2","ts":"2026-01-01T00:00:02Z"}'
CANON2=$(printf '%s' "$STEP2" | jq -c '. + {prev_hash: "'"$PREV_HASH"'"}')
SIG2=$(printf '%s' "$CANON2" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:$SIGNING_KEY" -binary | xxd -p -c 256)
STEP2_SIGNED=$(printf '%s' "$STEP2" | jq -c '. + {prev_hash: "'"$PREV_HASH"'", sig: "'"$SIG2"'"}')
printf '%s\n' "$STEP2_SIGNED" >> "$T"

export TRAJ_ID
out=$(traj verify 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok "valid signed chain returns 0" || bad "valid chain rc" "rc=$rc, out=$out"
echo "$out" | grep -q "VERIFIED" && ok "valid chain marked VERIFIED" || bad "valid chain status" "$out"
echo "$out" | grep -q "Verified:    2" && ok "correctly counts 2 verified steps" || bad "verified count" "$out"
echo "$out" | grep -q "Unverified:  1" && ok "correctly counts 1 unverified (header)" || bad "unverified count" "$out"

# ---- Test 3: Tampered chain (modify content of step 1) ----
TRAJ_ID="cafe0000-0000-0000-0000-0000000000d3"
TAMPERED_DIR="$WORK/trajectories/$TRAJ_ID"
mkdir -p "$TAMPERED_DIR"
cp "$SIGNED_DIR/trajectory.jsonl" "$TAMPERED_DIR/trajectory.jsonl"
# Tamper: change content of step 1 (second line)
sed '2s/signed step 1/TAMPERED/' "$TAMPERED_DIR/trajectory.jsonl" > "$TAMPERED_DIR/trajectory.jsonl.tmp" && mv "$TAMPERED_DIR/trajectory.jsonl.tmp" "$TAMPERED_DIR/trajectory.jsonl"

export TRAJ_ID
out=$(traj verify 2>&1); rc=$?
[[ $rc -eq 1 ]] && ok "tampered chain returns 1" || bad "tampered rc" "rc=$rc, out=$out"
echo "$out" | grep -q "TAMPERED" && ok "tampered chain marked TAMPERED" || bad "tampered status" "$out"

# ---- Test 4: Wrong signing key ----
TRAJ_ID="cafe0000-0000-0000-0000-0000000000d4"
WRONGKEY_DIR="$WORK/trajectories/$TRAJ_ID"
mkdir -p "$WRONGKEY_DIR"
cp "$SIGNED_DIR/trajectory.jsonl" "$WRONGKEY_DIR/trajectory.jsonl"
# Use a different signing key
WRONG_KEY="ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
printf '%s' "$WRONG_KEY" > "$WORK/secrets/traj_signing_key"

export TRAJ_ID
out=$(traj verify 2>&1); rc=$?
[[ $rc -eq 1 ]] && ok "wrong key returns 1" || bad "wrong key rc" "rc=$rc, out=$out"
echo "$out" | grep -q "TAMPERED" && ok "wrong key marked TAMPERED" || bad "wrong key status" "$out"

# Restore correct key
printf '%s' "$SIGNING_KEY" > "$WORK/secrets/traj_signing_key"

# ---- Test 5: Verbose mode ----
TRAJ_ID="cafe0000-0000-0000-0000-0000000000d5"
VERBOSE_DIR="$WORK/trajectories/$TRAJ_ID"
mkdir -p "$VERBOSE_DIR"
cp "$SIGNED_DIR/trajectory.jsonl" "$VERBOSE_DIR/trajectory.jsonl"

export TRAJ_ID
out=$(traj verify -v 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok "verbose mode returns 0" || bad "verbose rc" "rc=$rc, out=$out"
echo "$out" | grep -q "verified" && ok "verbose shows step statuses" || bad "verbose output" "$out"
# Should show multiple steps with status
line_count=$(echo "$out" | grep -c "^\|^  " || true)
[[ "$line_count" -ge 2 ]] && ok "verbose mode shows multiple steps" || bad "verbose lines" "$out"

# ---- Test 6: Mixed legacy and signed ----
TRAJ_ID="cafe0000-0000-0000-0000-0000000000d6"
MIXED_DIR="$WORK/trajectories/$TRAJ_ID"
mkdir -p "$MIXED_DIR"
T="$MIXED_DIR/trajectory.jsonl"

# Legacy header
printf '{"step_id":"%s","type":"trajectory","ts":"2026-01-01T00:00:00Z"}\n' "$TRAJ_ID" > "$T"
# Legacy step (no prev_hash, no sig)
printf '{"step_id":"s1","type":"thought","content":"legacy","ts":"2026-01-01T00:00:01Z"}\n' >> "$T"
# Signed step (has prev_hash and sig) - prev_hash is hash of legacy step line
LINE2=$(sed -n '2p' "$T")
PREV_HASH=$(hash_line "$LINE2")
STEP2='{"step_id":"s2","type":"thought","content":"signed","ts":"2026-01-01T00:00:02Z"}'
CANON2=$(printf '%s' "$STEP2" | jq -c '. + {prev_hash: "'"$PREV_HASH"'"}')
SIG2=$(printf '%s' "$CANON2" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:$SIGNING_KEY" -binary | xxd -p -c 256)
printf '%s\n' "$(printf '%s' "$STEP2" | jq -c '. + {prev_hash: "'"$PREV_HASH"'", sig: "'"$SIG2"'"}')" >> "$T"

export TRAJ_ID
out=$(traj verify 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok "mixed legacy/signed returns 0" || bad "mixed rc" "rc=$rc, out=$out"
echo "$out" | grep -q "VERIFIED" && ok "mixed chain marked VERIFIED" || bad "mixed status" "$out"
echo "$out" | grep -q "Verified:    1" && ok "counts 1 verified step" || bad "mixed verified count" "$out"
# Header + legacy step = 2 unverified
echo "$out" | grep -q "Unverified:  2" && ok "counts 2 unverified (header + legacy)" || bad "mixed unverified count" "$out"

# ---- Test 7: Verify with explicit --traj_dir ----
TRAJ_ID_EXPLICIT="cafe0000-0000-0000-0000-0000000000d7"
EXPLICIT_DIR="$WORK/trajectories/$TRAJ_ID_EXPLICIT"
mkdir -p "$EXPLICIT_DIR"
cp "$SIGNED_DIR/trajectory.jsonl" "$EXPLICIT_DIR/trajectory.jsonl"

unset TRAJ_ID
out=$(traj verify --traj_dir "$WORK/trajectories" "$TRAJ_ID_EXPLICIT" 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok "explicit --traj_dir works" || bad "explicit traj_dir rc" "rc=$rc, out=$out"
echo "$out" | grep -q "VERIFIED" && ok "explicit traj_dir marked VERIFIED" || bad "explicit status" "$out"

# ---- Test 8: Missing trajectory file ----
# verify uses die() which exits 1, not 2
MISSING_DIR=$(mktemp -d)
mkdir -p "$MISSING_DIR/trajectories"
out=$(traj verify --traj_dir "$MISSING_DIR/trajectories" "cafe0000-0000-0000-0000-0000000000d0" 2>&1); rc=$?
[[ $rc -eq 1 ]] && ok "missing trajectory returns 1" || bad "missing rc" "rc=$rc, out=$out"
echo "$out" | grep -q "cannot resolve traj_id" && ok "missing trajectory error message" || bad "missing error" "$out"
rm -rf "$MISSING_DIR"

# ---- Test 9: Trajectory with no signing key configured ----
# When steps have signatures but no key is available, they are marked TAMPERED (invalid sig)
# This is the current behavior - let's test it
TRAJ_ID="cafe0000-0000-0000-0000-0000000000d8"
NOKEY_DIR="$WORK/trajectories/$TRAJ_ID"
mkdir -p "$NOKEY_DIR"
cp "$SIGNED_DIR/trajectory.jsonl" "$NOKEY_DIR/trajectory.jsonl"
# Remove signing key
rm -f "$WORK/secrets/traj_signing_key"

export TRAJ_ID
export IDENTITY_DIR="$WORK"
out=$(traj verify 2>&1); rc=$?
[[ $rc -eq 1 ]] && ok "no signing key returns 1 (tampered because sigs can't be verified)" || bad "no key rc" "rc=$rc, out=$out"
echo "$out" | grep -q "TAMPERED" && ok "no key marked TAMPERED (steps have sigs but no key)" || bad "no key status" "$out"

# Restore key
printf '%s' "$SIGNING_KEY" > "$WORK/secrets/traj_signing_key"

# ---- Test 10: Trajectory with no signing key AND no sigs on steps, but proper prev_hash chain ----
TRAJ_ID="cafe0000-0000-0000-0000-0000000000d9"
NOKEY_NOSIG_DIR="$WORK/trajectories/$TRAJ_ID"
mkdir -p "$NOKEY_NOSIG_DIR"
T="$NOKEY_NOSIG_DIR/trajectory.jsonl"
HEADER='{"step_id":"'"$TRAJ_ID"'","type":"trajectory","ts":"2026-01-01T00:00:00Z"}'
printf '%s\n' "$HEADER" > "$T"
PREV_HASH=$(hash_line "$HEADER")
# Step with prev_hash but no sig
STEP1='{"step_id":"s1","type":"thought","content":"step 1","ts":"2026-01-01T00:00:01Z"}'
STEP1_WITH_HASH=$(printf '%s' "$STEP1" | jq -c '. + {prev_hash: "'"$PREV_HASH"'"}')
printf '%s\n' "$STEP1_WITH_HASH" >> "$T"
PREV_HASH=$(hash_line "$STEP1_WITH_HASH")
STEP2='{"step_id":"s2","type":"thought","content":"step 2","ts":"2026-01-01T00:00:02Z"}'
STEP2_WITH_HASH=$(printf '%s' "$STEP2" | jq -c '. + {prev_hash: "'"$PREV_HASH"'"}')
printf '%s\n' "$STEP2_WITH_HASH" >> "$T"

export TRAJ_ID
export IDENTITY_DIR="$WORK"
rm -f "$WORK/secrets/traj_signing_key"
out=$(traj verify 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok "no key and no sigs (but valid hash chain) returns 0" || bad "no key no sig rc" "rc=$rc, out=$out"
echo "$out" | grep -q "UNVERIFIED" && ok "no key no sigs marked UNVERIFIED" || bad "no key no sig status" "$out"
echo "$out" | grep -q "Verified:    0" && ok "no key no sigs has 0 verified" || bad "no key no sig verified count" "$out"
echo "$out" | grep -q "Unverified:  3" && ok "no key no sigs has 3 unverified (header + 2 steps)" || bad "no key no sig unverified count" "$out"

# Restore key
printf '%s' "$SIGNING_KEY" > "$WORK/secrets/traj_signing_key"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
