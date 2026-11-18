#!/usr/bin/env bash
# tests/test_nested_traj_isolation.sh — suites that exec a real nested
# shellm must neutralize the ambient trajectory variables first.
#
# Usage: tests/test_nested_traj_isolation.sh
#
# Why: bin/shellm resolves its trajectory directory as
#   SHELLM_TRAJ_DIR, then TRAJ_DIR, then the state home (bin/shellm line ~47),
# so a suite run inside a live wake (where both variables point at the
# caller's real log) writes its stub runs into that log: child trajectory
# directories are minted in the live root and inline shellm-run rows land in
# the live trajectory, where the rollup reads them as life events. On
# 2026-11-05 a full tests/run-all.sh inside one wake minted twelve child
# directories (say-hi, do-the-task, tmpdir-case, key-probe, oversized-prompt)
# into the live root. The six suites that already guard this all unset or
# reassign both variables; this lint holds the rest to the same bar.
#
# Covers:
#   1. Lint: every tests/test_*.sh that executes a real bin/shellm binary in
#      command position neutralizes SHELLM_TRAJ_DIR and TRAJ_DIR (unset or
#      suite-owned assignment) somewhere before relying on the run.
#   2. Mechanism, behavioral: with ambient variables pointed at a canary
#      directory, an unguarded copied shellm mints into the canary, and the
#      house unset keeps the canary untouched.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }

# --- 1. lint over the suite files ---------------------------------------------

# Print "lineno<TAB>line" for lines that execute a real shellm binary in
# command position. Approximate by word position: the path must be the first
# word of the command, after stripping a leading subshell/`cd ... &&`/
# $TIMEOUT/`name=$(«` prefix. References that are arguments (sed, eval,
# grep, test, cp, printf, heredoc content) have an earlier first word and
# are skipped by construction.
exec_lines() { # $1 = suite file
    # A suite may exec the binary by literal path or through a variable
    # (SHELLM="$REPO/bin/shellm" then "$SHELLM" ...), so first collect
    # every variable whose value is the binary path, then treat both the
    # literal path and those variable names in command position as execs.
    local varnames pat
    varnames=$(sed -nE 's|^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)="[^"]*bin/shellm".*$|\1|p' "$1" | sort -u | tr '\n' '|')
    pat='bin/shellm'
    [ -n "$varnames" ] && pat="bin/shellm|(${varnames%|})"
    grep -nE "$pat" "$1" | while IFS= read -r raw; do
        num="${raw%%:*}"; line="${raw#*:}"
        case "$line" in \#*|' '*'#'*) continue ;; esac   # comment lines
        first=$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' \
            -e 's/^([[:space:]]*//' -e 's/^cd [^&]*&&[[:space:]]*//' \
            -e 's/^[$]TIMEOUT[[:space:]]*//' -e 's/^[A-Za-z_][A-Za-z0-9_]*=[$](//')
        word="${first%%[[:space:]]*}"; word="${word//\"/}"
        word="${word#\$}"                       # "$SHELLM" -> SHELLM
        case "$word" in
            *bin/shellm)
                case "$word" in
                    [A-Za-z_][A-Za-z0-9_]*=*bin/shellm) continue ;;  # assignment
                    *) printf '%s\t%s\n' "$num" "$line" ;;
                esac ;;
            SHELLM|TRAJ_BIN)  # a variable whose value is the binary, exec'd
                printf '%s\t%s\n' "$num" "$line" ;;
        esac
    done
}


lint_failures=""
lint_checked=0
for t in "$HERE"/test_*.sh; do
    name=$(basename "$t")
    [ -n "$(exec_lines "$t")" ] || continue
    lint_checked=$((lint_checked + 1))
    neutralizes() { # $1 = var name
        grep -Eq "unset([^#]*[[:space:]])$1([[:space:]]|$)" "$t" \
            || grep -q "$1=" "$t"
    }
    if ! neutralizes SHELLM_TRAJ_DIR || ! neutralizes TRAJ_DIR; then
        lint_failures="$lint_failures $name"
    fi
done

if [ -z "$lint_failures" ]; then
    ok "lint: all $lint_checked shellm-execing suites neutralize the ambient trajectory variables"
else
    bad "lint: suites exec a real shellm without neutralizing the ambient trajectory variables" \
        "guard needed in:$lint_failures"
fi

# --- 2. the mechanism, on a canary --------------------------------------------

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/home" "$WORK/wd" "$WORK/canary" "$WORK/suitehome"
cp -R "$REPO/bin" "$WORK/toolbin"
cat > "$WORK/toolbin/llm" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do [[ "$a" == "--thinking" ]] && main_loop=1; done
if [[ "${main_loop:-0}" -ne 1 ]]; then printf '{}\n'; exit 0; fi
printf '```bash\nFINAL=done\n```\n'
STUB
chmod +x "$WORK/toolbin/llm"

# This suite execs a real shellm too, so it holds itself to its own rule:
# the ambient variables from any enclosing wake are neutralized first.
unset TRAJ_DIR TRAJ_ID SHELLM_TRAJ_DIR
export HOME="$WORK/home"
export HEADLONG_HOME="$WORK/suitehome"
export ANTHROPIC_API_KEY="test-key"
export SHELLM_MODEL="test-model"
export SHELLM_ENV=local

run_one() { # $1 = guard form: guarded | unguarded
    ( cd "$WORK/wd" && \
      if [ "$1" = guarded ]; then
          env -u TRAJ_DIR -u TRAJ_ID -u SHELLM_TRAJ_DIR \
              HOME="$WORK/home" HEADLONG_HOME="$WORK/suitehome" \
              PATH="$WORK/toolbin:$PATH" \
              "$WORK/toolbin/shellm" --workdir "$WORK/wd" --max-iterations 1 canary-run
      else
          env TRAJ_DIR="$WORK/canary" SHELLM_TRAJ_DIR="$WORK/canary" \
              HOME="$WORK/home" HEADLONG_HOME="$WORK/suitehome" \
              PATH="$WORK/toolbin:$PATH" \
              "$WORK/toolbin/shellm" --workdir "$WORK/wd" --max-iterations 1 canary-run
      fi ) > "$WORK/out" 2> "$WORK/err" < /dev/null
}

# Unguarded: both ambient variables set, as an enclosing wake would leave
# them. The run must mint into the canary, which is exactly the bug.
run_one unguarded; rc=$?
if [ "$rc" -eq 0 ] && [ -n "$(find "$WORK/canary" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)" ]; then
    ok "mechanism: ambient TRAJ_DIR/SHELLM_TRAJ_DIR capture the unguarded run (rc=$rc)"
else
    bad "mechanism: ambient TRAJ_DIR/SHELLM_TRAJ_DIR capture the unguarded run" \
        "rc=$rc: $(tail -c 200 "$WORK/err" 2>/dev/null)"
fi

# Guarded: the house unset. The canary must stay empty and the run must land
# in the suite-owned state home instead.
rm -rf "$WORK/canary"; mkdir -p "$WORK/canary"
run_one guarded; rc=$?
if [ "$rc" -eq 0 ] \
   && [ -z "$(find "$WORK/canary" -mindepth 1 -maxdepth 1 2>/dev/null)" ] \
   && [ -n "$(find "$WORK/suitehome/trajectories" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)" ]; then
    ok "guard: the unset keeps the caller's log untouched and the run lands in the suite home (rc=$rc)"
else
    bad "guard: the unset keeps the caller's log untouched" \
        "rc=$rc canary=$(find "$WORK/canary" -mindepth 1 | wc -l) home=$(find "$WORK/suitehome/trajectories" -mindepth 1 2>/dev/null | wc -l): $(tail -c 200 "$WORK/err" 2>/dev/null)"
fi

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
