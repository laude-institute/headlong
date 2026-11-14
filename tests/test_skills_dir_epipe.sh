#!/usr/bin/env bash
# Skills dir-list writer EPIPE arms, fix/skills-dir-epipe (2026-10-08).
#
# _all_skill_dirs echoed each search directory as it resolved it, and
# find_skill reads that stream through a process substitution and
# returns mid-stream on the first match. The reader's close races the
# writer's remaining echoes, and the next echo died with "write error:
# Broken pipe" on stderr: 65 live firings between 2026-09-14 and
# 2026-10-05, 10 of 10 on `skills show chat` at the deployed checkout.
# Stdout was never lost; the cost is the death line polluting any merged
# capture, which later
# readbacks quote as skill content.
#
# Originally reproduced at 8c1a92c; the rebased unfixed baseline is c43e597.
# Arms 2, 3 and 7 must fail there, regardless of the runner's SIGPIPE state.
# Arm 7 injects a delayed producer after a real first match, forcing the
# early-close boundary without claiming normal short lists split writes.
# The fixture's local dir sits 60 levels deep so the old writer's last
# resolution is still in flight when the reader closes.
set -u
# Bash reports EPIPE only when SIGPIPE is ignored. Set it explicitly rather
# than inheriting a terminal's default or a supervisor's ignored disposition.
trap '' PIPE
# Do not source the runner's external skills configuration.
export SKILLSRC=/dev/null
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SKILLS="$ROOT/bin/skills"
PASS=0 FAIL=0
DEATH="write error: Broken pipe"
TRIALS=10
HOSTILE_TRIALS=40
FIX="" LOCAL="" SHOW_RC=0

ok()  { PASS=$((PASS+1)); echo "  ok: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

make_fixture() {
    FIX=$(mktemp -d) || return 1
    local deep="$FIX/local" i
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 \
             21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 \
             41 42 43 44 45 46 47 48 49 50 51 52 53 54 55 56 57 58 59 60; do
        deep="$deep/d$i"
    done
    mkdir -p "$deep/beta" "$deep/gamma" "$FIX/cwd" "$FIX/kernel/alpha" || return 1
    printf -- '---\nname: alpha\ndescription: fixture skill found in the kernel dir\n---\n\nAlpha skill body line.\n' > "$FIX/kernel/alpha/SKILL.md"
    printf -- '---\nname: beta\ndescription: fixture skill found later\n---\n\nBeta skill body line.\n' > "$deep/beta/SKILL.md"
    printf -- '---\nname: gamma\ndescription: fixture skill found last\n---\n\nGamma skill body line.\n' > "$deep/gamma/SKILL.md"
    LOCAL="$deep"
}

run_show() {  # run_show [merged]: `skills show alpha`, rc in SHOW_RC
    local rc=0
    if [ "${1:-}" = "merged" ]; then
        ( cd "$FIX/cwd" && SKILLS_KERNEL_DIR="$FIX/kernel" SKILLS_DIR="$LOCAL" \
            bash "$SKILLS" show alpha >"$FIX/mout" 2>&1 ) || rc=$?
    else
        ( cd "$FIX/cwd" && SKILLS_KERNEL_DIR="$FIX/kernel" SKILLS_DIR="$LOCAL" \
            bash "$SKILLS" show alpha >"$FIX/out" 2>"$FIX/err" ) || rc=$?
    fi
    SHOW_RC=$rc
}

a1_stdout_intact() {
    local i
    for ((i=1; i<=TRIALS; i++)); do
        run_show
        [ "$SHOW_RC" -eq 0 ] || { bad "a1: show exited $SHOW_RC on trial $i"; return; }
        grep -q 'Alpha skill body line.' "$FIX/out" || { bad "a1: stdout lost the skill body on trial $i"; return; }
    done
    ok "a1: show stdout intact over $TRIALS early matches"
}

a2_stderr_clean() {
    local i
    for ((i=1; i<=TRIALS; i++)); do
        run_show
        if grep -q "$DEATH" "$FIX/err"; then bad "a2: writer death on stderr, trial $i of $TRIALS"; return; fi
    done
    ok "a2: no writer death on stderr over $TRIALS early matches"
}

a3_merged_capture_clean() {
    local i
    for ((i=1; i<=TRIALS; i++)); do
        run_show merged
        grep -q 'Alpha skill body line.' "$FIX/mout" || { bad "a3: merged capture lost the body, trial $i"; return; }
        if grep -q "$DEATH" "$FIX/mout"; then bad "a3: merged capture polluted, trial $i of $TRIALS"; return; fi
    done
    ok "a3: merged capture clean over $TRIALS early matches"
}

a4_drain_readers_clean() {
    local rc=0
    ( cd "$FIX/cwd" && SKILLS_KERNEL_DIR="$FIX/kernel" SKILLS_DIR="$LOCAL" \
        bash "$SKILLS" list >"$FIX/lout" 2>"$FIX/lerr" ) || rc=$?
    [ "$rc" -eq 0 ] || { bad "a4: list exited $rc"; return; }
    [ -s "$FIX/lerr" ] && { bad "a4: list wrote to stderr"; return; }
    grep -q 'alpha' "$FIX/lout" || { bad "a4: list missing alpha"; return; }
    grep -q 'beta' "$FIX/lout" || { bad "a4: list missing beta"; return; }
    rc=0
    ( cd "$FIX/cwd" && SKILLS_KERNEL_DIR="$FIX/kernel" SKILLS_DIR="$LOCAL" \
        bash "$SKILLS" list-json >"$FIX/jout" 2>"$FIX/jerr" ) || rc=$?
    [ "$rc" -eq 0 ] || { bad "a4: list-json exited $rc"; return; }
    [ -s "$FIX/jerr" ] && { bad "a4: list-json wrote to stderr"; return; }
    jq -e 'length >= 1' "$FIX/jout" >/dev/null 2>&1 || { bad "a4: list-json not valid json"; return; }
    grep -q 'alpha' "$FIX/jout" || { bad "a4: list-json missing alpha"; return; }
    ok "a4: draining readers (list, list-json) complete with clean stderr"
}

dirs_of() {  # dirs_of <kernel> <local>: _all_skill_dirs output on stdout
    ( cd "$FIX/cwd" && SKILLS_LIB_ONLY=1 SKILLS_KERNEL_DIR="$1" SKILLS_DIR="$2" \
        bash -c 'source "$1" >/dev/null 2>&1; _all_skill_dirs' _ "$SKILLS" )
}

a5_dirs_exact_order() {
    local got want
    got=$(dirs_of "$FIX/kernel" "$LOCAL")
    want=$(printf '.skills\n%s\n%s' "$FIX/kernel" "$LOCAL")
    [ "$got" = "$want" ] || { bad "a5: dir list changed, got [$got] want [$want]"; return; }
    ok "a5: dir list exact and ordered: project, kernel, local"
}

a6_dedup_holds() {
    local got n
    got=$(dirs_of "$LOCAL" "$LOCAL")
    n=$(printf '%s\n' "$got" | wc -l)
    [ "$n" -eq 2 ] || { bad "a6: duplicate real paths not deduped, $n lines"; return; }
    case "$got" in
        *"$LOCAL"*) ok "a6: duplicate real paths still deduped" ;;
        *) bad "a6: local dir missing after dedup" ;;
    esac
}

a7_hostile_reader_silent() {
    local i rc
    for ((i=1; i<=HOSTILE_TRIALS; i++)); do
        rc=0
        ( cd "$FIX/cwd" && SKILLS_LIB_ONLY=1 SKILLS_KERNEL_DIR="$FIX/kernel" SKILLS_DIR="$LOCAL" \
            bash -c '
                source "$1"
                done_file=$2
                _all_skill_dirs() {
                    printf "%s\n" "$SKILLS_KERNEL_DIR"
                    # Wait for the caller to confirm the real reader closed.
                    for ((k=0; k<200; k++)); do
                        [ -f "$done_file.reader" ] && break
                        sleep 0.01
                    done
                    printf "%s\n" "$SKILLS_DIR" || true
                    # Synchronize with the test: process substitutions are not
                    # awaited when find_skill returns.
                    : > "$done_file"
                }
                find_skill alpha
                : > "$done_file.reader"
                for ((j=0; j<200; j++)); do
                    [ -f "$2" ] && exit 0
                    sleep 0.01
                done
                exit 1
            ' _ "$SKILLS" "$FIX/producer-done" >"$FIX/hout" 2>"$FIX/herr" ) || rc=$?
        [ "$rc" -eq 0 ] || { bad "a7: producer did not complete, trial $i"; return; }
        [ "$(cat "$FIX/hout")" = "$FIX/kernel/alpha" ] || { bad "a7: wrong first match"; return; }
        if [ -s "$FIX/herr" ]; then bad "a7: early close still noisy, trial $i of $HOSTILE_TRIALS"; return; fi
        rm -f "$FIX/producer-done" "$FIX/producer-done.reader"
    done
    ok "a7: forced early close silent over $HOSTILE_TRIALS trials"
}

a8_late_match() {
    local rc=0
    ( cd "$FIX/cwd" && SKILLS_KERNEL_DIR="$FIX/kernel" SKILLS_DIR="$LOCAL" \
        bash "$SKILLS" show gamma >"$FIX/gout" 2>"$FIX/gerr" ) || rc=$?
    [ "$rc" -eq 0 ] || { bad "a8: late match exited $rc"; return; }
    grep -q 'Gamma skill body line.' "$FIX/gout" || { bad "a8: late skill body missing"; return; }
    [ ! -s "$FIX/gerr" ] || { bad "a8: late match wrote to stderr"; return; }
    ok "a8: show reaches the last directory with clean stderr"
}

a9_write_failure_visible() {
    local rc=0
    ( cd "$FIX/cwd" && SKILLS_LIB_ONLY=1 SKILLS_KERNEL_DIR="$FIX/kernel" SKILLS_DIR="$LOCAL" \
        bash -c 'source "$1"; _all_skill_dirs >&-' _ "$SKILLS" 2>"$FIX/werr" ) || rc=$?
    [ "$rc" -ne 0 ] || { bad "a9: producer swallowed a write failure"; return; }
    [ -s "$FIX/werr" ] || { bad "a9: producer hid a write diagnostic"; return; }
    ok "a9: shared producer preserves write errors for draining callers"
}

make_fixture || { echo "fixture setup failed" >&2; exit 2; }
trap 'rm -rf "$FIX"' EXIT
a1_stdout_intact
a2_stderr_clean
a3_merged_capture_clean
a4_drain_readers_clean
a5_dirs_exact_order
a6_dedup_holds
a7_hostile_reader_silent
a8_late_match
a9_write_failure_visible
echo "skills dir epipe: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
