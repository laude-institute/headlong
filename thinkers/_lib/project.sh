#!/usr/bin/env bash
# thinkers/_lib/project.sh — project mode for the monolith: long unattended
# research runs (design/long_autonomy.md). Sourced by thinkers/monolith/step.
#
# Project mode is on when <identity>/workdir/project/charter.md exists
# (`headlong-project init` sets it up) and HEADLONG_PROJECT_MODE is not 0.
# Everything here is deterministic shell: the runtime, not the model, decides
# when a ritual is due, when a question's default has matured, when the
# budget is spent, and it restores the read-only files and commits project/
# whether or not the model remembers to.
#
# Layout:
#   <identity>/workdir/project/   the mind's project files (a git repo)
#   <identity>/project-pristine/  read-only originals: charter.md, spec.md,
#                                 roles/, rituals/, started_at (epoch)
#   <identity>/run/project_freetime_<week>  when that week's free time opened
# Pristine files under project/ are restored from project-pristine/ on every
# wake if they changed.

_project_dir() { printf '%s' "${PROJECT_DIR:-$IDENTITY_DIR/workdir/project}"; }
_project_pristine() { printf '%s' "${PROJECT_PRISTINE_DIR:-$IDENTITY_DIR/project-pristine}"; }
_project_on() { [[ "${HEADLONG_PROJECT_MODE:-1}" != "0" && -f "$(_project_dir)/charter.md" ]]; }

# Epoch -> date/time in HEADLONG_TZ, GNU or BSD date.
_pj_date() {  # _pj_date <epoch> <format>
    TZ="${HEADLONG_TZ:-UTC}" date -d "@$1" "+$2" 2>/dev/null || TZ="${HEADLONG_TZ:-UTC}" date -r "$1" "+$2"
}
_pj_left() { local s="$1"; if (( s >= 86400 )); then printf '%sd %sh' $(( s / 86400 )) $(( s % 86400 / 3600 )); else printf '%sh %sm' $(( s / 3600 )) $(( s % 3600 / 60 )); fi; }
# Project time. PROJECT_TIME_SCALE=N runs the project clock N times faster
# than real time from the moment the project started, for accelerated test
# runs: days, weeks, rituals, the deadline, staleness, pacing and the budget
# window all follow it. 1 (the default) is real time. PROJECT_NOW pins the
# project clock and PROJECT_REAL_NOW the real one, in tests.
_pj_scale() { local k="${PROJECT_TIME_SCALE:-1}"; [[ "$k" =~ ^[1-9][0-9]*$ ]] || k=1; printf '%s' "$k"; }
_pj_real() {
    if [[ -n "${PROJECT_REAL_NOW:-}" ]]; then printf '%s' "$PROJECT_REAL_NOW"
    elif [[ -n "${PROJECT_NOW:-}" && "$(_pj_scale)" == 1 ]]; then printf '%s' "$PROJECT_NOW"
    else date +%s; fi
}
_pj_vtime() {  # _pj_vtime <real-epoch> -> project epoch
    local k; k=$(_pj_scale)
    if [[ "$k" == 1 ]]; then printf '%s' "$1"; return 0; fi
    local s; s=$(_project_started_at)
    printf '%s' $(( s + ($1 - s) * k ))
}
_pj_now() {
    if [[ -n "${PROJECT_NOW:-}" ]]; then printf '%s' "$PROJECT_NOW"; else _pj_vtime "$(_pj_real)"; fi
}
# Real seconds for a span of project seconds (at least 30 when scaled).
_pj_real_span() { local k; k=$(_pj_scale); local r=$(( $1 / k )); (( k > 1 && r < 30 )) && r=30; printf '%s' "$r"; }
_pj_mtime() {  # _pj_mtime <file> -> its mtime in project time (empty if missing)
    local m; m=$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null) || return 0
    _pj_vtime "$m"
}

_project_started_at() {
    local s
    s=$(cat "$(_project_pristine)/started_at" 2>/dev/null) || s=""
    [[ "$s" =~ ^[0-9]+$ ]] || s=${PROJECT_NOW:-$(date +%s)}
    printf '%s' "$s"
}
# Project week number (1-based), zero-padded.
_project_week() {  # _project_week [epoch]
    local now="${1:-$(_pj_now)}" start
    start=$(_project_started_at)
    printf '%02d' $(( (now - start) / 604800 + 1 ))
}

# The run's end (epoch), from project-pristine/end_at; empty when unset (an
# open-ended run: no phases, no final ritual).
_project_end_at() {
    local e
    e=$(cat "$(_project_pristine)/end_at" 2>/dev/null) || e=""
    [[ "$e" =~ ^[0-9]+$ ]] && printf '%s' "$e"
    return 0
}
# Where the run is against its deadline: build (first half), harden (second
# half), final (the last 15% or 2 days, whichever is longer), ended.
_project_phase() {  # _project_phase [epoch]
    local now="${1:-$(_pj_now)}" start end left final
    end=$(_project_end_at); [[ -n "$end" ]] || { printf 'open'; return 0; }
    start=$(_project_started_at)
    left=$(( end - now ))
    final=$(( (end - start) * 15 / 100 )); (( final < 172800 )) && final=172800
    if (( left <= 0 )); then printf 'ended'
    elif (( left <= final )); then printf 'final'
    elif (( now - start >= (end - start) / 2 )); then printf 'harden'
    else printf 'build'; fi
}
# The deliverable has been started: it exists and no longer carries the
# template's marker line.
_project_deliverable_started() {
    local f; f="$(_project_dir)/deliverable.md"
    [[ -f "$f" ]] && ! grep -q '^<!-- TEMPLATE' "$f"
}

# Restore any pristine file that changed under project/. Prints the restored
# paths (relative), one per line; empty when all is intact.
_project_guard() {
    local p d f rel
    p=$(_project_pristine); d=$(_project_dir)
    [[ -d "$p" ]] || return 0
    while IFS= read -r f; do
        rel="${f#"$p"/}"
        case "$rel" in charter.md|spec.md|roles/*) ;; *) continue ;; esac
        if ! cmp -s "$f" "$d/$rel"; then
            mkdir -p "$(dirname "$d/$rel")"
            chmod u+w "$d/$rel" 2>/dev/null || true
            cp "$f" "$d/$rel" && chmod a-w "$d/$rel" 2>/dev/null
            printf '%s\n' "$rel"
        fi
    done < <(find "$p" -type f 2>/dev/null | sort)
    return 0
}

# STATE: first word of line 1 (active | blocked | done), defaulting to active.
_project_state() {
    local s
    s=$(head -n 1 "$(_project_dir)/STATE" 2>/dev/null | awk '{print tolower($1)}') || s=""
    case "$s" in blocked|done) printf '%s' "$s" ;; *) printf 'active' ;; esac
}

# ---------------------------------------------------------------------------
# Questions (design/long_autonomy.md, "Questions and humans")
# ---------------------------------------------------------------------------
# An entry in questions.md:
#   ### Q3 — 2026-10-05 — title — STATUS: open | answered | defaulted | moot
#   Blocking: / Default: / Default-by: / Answer: / Resolution: lines
# Q ids are stamped by the runtime (_project_number_questions). Whether an
# Answer line came from a human is decided from git, not from its text: edits
# made between wakes are committed as author "human" before each wake
# (_project_commit_outside), and `headlong-project answer` commits as "human"
# too, so an Answer line whose last author is the agent is not a human answer.

# Stamp a Q<n> id on every question header that lacks one. Idempotent.
_project_number_questions() {
    local q tmp
    q="$(_project_dir)/questions.md"
    [[ -f "$q" ]] || return 0
    grep -qE '^### ' "$q" || return 0
    tmp=$(mktemp) || return 0
    awk '
        NR == FNR { if ($0 ~ /^### Q[0-9]+ /) { n = $2; sub(/^Q/, "", n); if (n + 0 > max) max = n + 0 } next }
        /^### / && /STATUS:/ && $0 !~ /^### Q[0-9]+ / {
            st = substr($0, index($0, "STATUS:")); if (index(st, "|")) { print; next }
            max++; print "### Q" max " — " substr($0, 5); next
        }
        { print }' "$q" "$q" > "$tmp" && ! cmp -s "$tmp" "$q" && cat "$tmp" > "$q"
    rm -f "$tmp"
    return 0
}

# questions.md -> records, one question per line, fields split by \037 (not
# tab: tab is IFS whitespace, so `read` would merge empty fields):
#   id, title, status, blocking, default-by, default, answer, resolution,
#   opened, answer-line-number
_project_questions() {
    local q
    q="$(_project_dir)/questions.md"
    [[ -f "$q" ]] || return 0
    awk '
        function clean(x) { gsub(/\t/, " ", x); sub(/^[[:space:]]+/, "", x); sub(/[[:space:]]+$/, "", x); return x }
        function flush() {
            if (t != "") printf "%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\n", id, t, st, b, db, df, an, rs, op, al
            t = ""
        }
        /^### / && /STATUS:/ {
            flush(); h = substr($0, 5); i = index(h, "STATUS:")
            st = tolower(substr(h, i + 7))
            if (index(st, "|")) { t = ""; next }   # the format example, not a question
            gsub(/[^a-z]/, "", st)
            t = substr(h, 1, i - 1); sub(/[[:space:]]*(—|-)+[[:space:]]*$/, "", t)
            id = ""; if (match(t, /^Q[0-9]+/)) { id = substr(t, 1, RLENGTH); t = substr(t, RLENGTH + 1); sub(/^[[:space:]]*(—|-)+[[:space:]]*/, "", t) }
            op = ""; if (match(t, /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/)) { op = substr(t, 1, 10); t = substr(t, 11); sub(/^[[:space:]]*(—|-)+[[:space:]]*/, "", t) }
            t = clean(t); b = "no"; db = ""; df = ""; an = ""; rs = ""; al = ""; next
        }
        /^### / { flush(); next }
        t != "" && /^Blocking:/ { b = tolower($2) }
        t != "" && /^Default-by:/ { db = $2 }
        t != "" && /^Default:/ { df = clean(substr($0, 9)) }
        t != "" && /^Answer:/ { an = clean(substr($0, 8)); if (an ~ /^\((filled in by a human|a human writes|none)/) an = ""; al = NR }   # () = the template placeholder
        t != "" && /^Resolution:/ { rs = clean(substr($0, 12)) }
        END { flush() }' "$q"
}

# Ids of questions whose Answer line was last written by a human commit.
_project_human_answers() {
    local d
    d=$(_project_dir)
    [[ -d "$d/.git" ]] || return 0
    local blame
    blame=$(git -C "$d" blame --line-porcelain -- questions.md 2>/dev/null) || return 0
    local id t st b db df an rs op al author
    while IFS=$'\037' read -r id t st b db df an rs op al; do
        [[ -n "$an" && -n "$al" && -n "$id" ]] || continue
        author=$(printf '%s\n' "$blame" | awk -v want="$al" '
            /^[0-9a-f]{40} / { line = $3 } /^author / && line == want { sub(/^author /, ""); print; exit }')
        [[ "$author" == human ]] && printf '%s\n' "$id"
    done < <(_project_questions)
    return 0
}

# How each question stands, for humans: \037-split id, kind, title, detail, where
# kind is one of: open, human-waiting (answered by a human, not yet applied),
# human (closed with a human answer), default, moot, unverified (marked
# answered, but no human wrote the answer).
_project_question_rows() {
    local humans id t st b db df an rs op al kind detail
    humans=" $(_project_human_answers | tr '\n' ' ') "
    while IFS=$'\037' read -r id t st b db df an rs op al; do
        local h=0; [[ "$humans" == *" $id "* ]] && h=1
        case "$st" in
            open) if (( h )); then kind=human-waiting; detail="human answer: $an"; else kind=open
                  detail="blocking: $b; default-by: ${db:-MISSING}; default: ${df:-none given}"; fi ;;
            answered) if (( h )); then kind=human; detail="$an"; else kind=unverified; detail="${an:-no answer text}"; fi ;;
            defaulted) kind=default; detail="${rs:-default: ${df:-not recorded}}" ;;
            *) kind=moot; detail="${rs:-moot}" ;;
        esac
        printf '%s\037%s\037%s\037%s\037%s\037%s\037%s\n' "${id:-Q?}" "$kind" "$t" "$detail" "$op" "$b" "$db"
    done < <(_project_questions)
}

# The questions block for human-facing status: every open question, loudly,
# for as long as it is open. $1 = "brief" for a one-screen version.
_project_question_banner() {
    local today rows open=0 id kind t detail op b db when
    today=$(_pj_date "$(_pj_now)" %F)
    rows=$(_project_question_rows)
    open=$(printf '%s\n' "$rows" | awk -F'\037' '$2 == "open" || $2 == "human-waiting"' | grep -c . || true)
    local name="${IDENTITY_NAME:-<name>}"
    if (( open == 0 )); then
        printf 'Open questions: none.\n'
    else
        printf '!!! %s OPEN QUESTION(S) FOR A HUMAN — answer with: headlong-project answer %s <Qn> "<answer>"\n' "$open" "$name"
        while IFS=$'\037' read -r id kind t detail op b db; do
            case "$kind" in
                open)
                    if [[ -z "$db" ]]; then when="no default date set"
                    elif [[ "$db" == never ]]; then when="will NOT default; blocked until a human answers"
                    elif [[ "$db" > "$today" ]]; then when="default applies on $db"
                    else when="default due now ($db); the agent will apply it"; fi
                    printf '  %s%s  %s\n      opened %s; %s\n      default: %s\n' "$id" "$([[ "$b" == yes ]] && printf ' [BLOCKING]')" "$t" "${op:-?}" "$when" \
                        "$(printf '%s' "$detail" | sed 's/.*default: //')" ;;
                human-waiting)
                    printf '  %s  %s\n      answered by a human; the agent applies it on its next wake\n' "$id" "$t" ;;
            esac
        done < <(printf '%s\n' "$rows" | awk -F'\037' '$2 == "open" || $2 == "human-waiting"')
    fi
    local closed unverified
    closed=$(printf '%s\n' "$rows" | awk -F'\037' '$2 == "human" || $2 == "default" || $2 == "moot" || $2 == "unverified"' | grep -c . || true)
    unverified=$(printf '%s\n' "$rows" | awk -F'\037' '$2 == "unverified" {print $1}' | tr '\n' ' ')
    if [[ "${1:-}" != brief ]] || (( closed > 0 )); then
        printf 'Closed questions: %s (how each was resolved: project/questions-summary.md, or headlong-project questions %s --closed)\n' "$closed" "$name"
    fi
    [[ -n "$unverified" ]] && printf '!!! Marked answered, but no human wrote the answer: %s\n' "$unverified"
    return 0
}

# Write project/questions-summary.md: open questions first, then every closed
# question with how it was closed (human answer, default, moot). Generated on
# every wake; edits to it are overwritten.
_project_write_summary() {
    local d out rows id kind t detail op b db
    d=$(_project_dir); out="$d/questions-summary.md"
    rows=$(_project_question_rows)
    {
        printf '# Questions: summary\n\nGenerated by the runtime from questions.md on every wake (%s). Do not edit; edit questions.md.\n' "$(_pj_date "$(_pj_now)" '%Y-%m-%d %H:%M %Z')"
        printf 'To answer an open question: headlong-project answer %s <Qn> "<answer>"\n\n' "${IDENTITY_NAME:-<name>}"
        printf '## Open: waiting on a human\n\n'
        printf '%s\n' "$rows" | awk -F'\037' '
            $2 == "open" { n++; printf "- **%s**%s %s  \n  opened %s; default-by %s. %s\n", $1, ($6 == "yes" ? " (blocking)" : ""), $3, $5, ($7 == "" ? "MISSING" : $7), $4 }
            $2 == "human-waiting" { n++; printf "- **%s** %s  \n  A human answered; the agent applies it on its next wake. %s\n", $1, $3, $4 }
            END { if (!n) print "None." }'
        printf '\n## Closed\n\n| Id | Question | Opened | Closed by | Answer or default used |\n|---|---|---|---|---|\n'
        printf '%s\n' "$rows" | awk -F'\037' '
            function esc(x) { gsub(/\|/, "\\|", x); return x }
            $2 == "human" { printf "| %s | %s | %s | Human answer | %s |\n", $1, esc($3), $5, esc($4) }
            $2 == "default" { printf "| %s | %s | %s | Default (no human answer) | %s |\n", $1, esc($3), $5, esc($4) }
            $2 == "moot" { printf "| %s | %s | %s | Moot | %s |\n", $1, esc($3), $5, esc($4) }
            $2 == "unverified" { printf "| %s | %s | %s | UNVERIFIED: marked answered, no human answer found | %s |\n", $1, esc($3), $5, esc($4) }'
    } > "$out.tmp" && mv "$out.tmp" "$out"
    return 0
}

# Commit edits made to project/ between wakes, as author "human", before the
# wake runs. Between wakes only humans write here (the monolith is the only
# writer during a wake, and it commits on the way out), so this is what makes
# a human's answer provable later. A wake that crashed before its commit would
# also land here; the message says so.
_project_commit_outside() {
    local d
    d=$(_project_dir)
    command -v git >/dev/null 2>&1 && [[ -d "$d/.git" ]] || return 0
    [[ -n "$(git -C "$d" status --porcelain 2>/dev/null)" ]] || return 0
    git -C "$d" add -A >/dev/null 2>&1 || return 0
    git -C "$d" -c user.name=human -c user.email=human@headlong.local \
        commit -q -m "edits made between wakes (a human, or a wake that crashed before committing)" >/dev/null 2>&1 || true
    return 0
}

# ---------------------------------------------------------------------------
# Token budget
# ---------------------------------------------------------------------------
# Every token processed: in + out, plus cached input on Anthropic-format
# providers, whose in_tok leaves cache reads out (OpenAI-format in_tok already
# includes them). The same 1M means the same work on any provider.
_PJ_TOK_JQ='(.in_tok // 0) + (.out_tok // 0) + (if (.provider == "anthropic" or .provider == "opencode" or .provider == "bedrock" or .provider == "bedrock-invoke") then (.cache_tok // 0) else 0 end)'
_project_ledger() { printf '%s' "${LLM_USAGE_LEDGER:-$IDENTITY_DIR/usage/llm.jsonl}"; }
_project_tokens_24h() {
    local ledger cutoff
    ledger=$(_project_ledger)
    [[ -f "$ledger" ]] || { printf '0'; return 0; }
    # The budget day is a project day: 86400 real seconds, or less when scaled.
    cutoff=$(TZ=UTC _pj_date $(( $(_pj_real) - 86400 / $(_pj_scale) )) '%Y-%m-%dT%H:%M:%SZ')
    tail -n "${PROJECT_LEDGER_TAIL:-200000}" "$ledger" | jq -Rn --arg c "$cutoff" \
        "[inputs | fromjson? // empty | select((.ts // \"\") >= \$c) | $_PJ_TOK_JQ] | add // 0" 2>/dev/null \
        || printf '0'
}
# Ledger line count now, and tokens on the lines after a given count: the
# step brackets its run with these to learn what one wake cost.
_project_ledger_lines() { local l; l=$(_project_ledger); [[ -f "$l" ]] && wc -l < "$l" | tr -d ' ' || printf '0'; }
_project_tokens_after() {  # _project_tokens_after <line-count>
    local l; l=$(_project_ledger)
    [[ -f "$l" ]] || { printf '0'; return 0; }
    tail -n +"$(( ${1:-0} + 1 ))" "$l" | jq -Rn "[inputs | fromjson? // empty | $_PJ_TOK_JQ] | add // 0" 2>/dev/null || printf '0'
}
# Tokens since the project started: the whole-run total.
_project_tokens_total() {
    local ledger since
    ledger=$(_project_ledger)
    [[ -f "$ledger" ]] || { printf '0'; return 0; }
    since=$(TZ=UTC _pj_date "$(_project_started_at)" '%Y-%m-%dT%H:%M:%SZ')
    jq -Rn --arg c "$since" "[inputs | fromjson? // empty | select((.ts // \"\") >= \$c) | $_PJ_TOK_JQ] | add // 0" "$ledger" 2>/dev/null \
        || printf '0'
}
# Over budget: the 24h cap (PROJECT_DAILY_TOKENS) or the whole-run cap
# (PROJECT_TOTAL_TOKENS). The step skips the model call entirely while over,
# so a cap is hard up to the one wake that crossed it.
_project_over_budget() {
    local cap="${PROJECT_DAILY_TOKENS:-0}" total="${PROJECT_TOTAL_TOKENS:-0}"
    if [[ "$total" =~ ^[0-9]+$ ]] && (( total > 0 )) && (( $(_project_tokens_total) >= total )); then return 0; fi
    [[ "$cap" =~ ^[0-9]+$ ]] && (( cap > 0 )) || return 1
    (( $(_project_tokens_24h) >= cap ))
}

# The ritual due now, if any, as "<kind> <arg>": "weekly 03", "daily
# 2026-10-05", "freetime 02 <until-epoch>". Weekly outranks daily outranks
# free time. Empty when nothing is due. Done-ness is the existence of the
# ritual's output file, so a ritual cut short by a crash is simply due again.
_project_due_ritual() {
    local d now start at at_m now_m bdate week prev fdir started
    d=$(_project_dir); now=$(_pj_now); start=$(_project_started_at)
    week=$(_project_week "$now")
    prev=$(printf '%02d' $(( 10#$week - 1 )))
    local phase; phase=$(_project_phase "$now")
    # Past the end, the final ritual is the only one: then the run rests.
    if [[ "$phase" == ended ]]; then
        [[ -f "$d/reports/final.md" ]] || printf 'final final'
        return 0
    fi
    if (( 10#$week >= 2 )) && [[ ! -f "$d/reports/week-$prev.md" ]]; then
        printf 'weekly %s' "$prev"; return 0
    fi
    at="${PROJECT_DAILY_AT:-21:00}"
    at_m=$(( 10#${at%:*} * 60 + 10#${at#*:} ))
    now_m=$(( 10#$(_pj_date "$now" %H) * 60 + 10#$(_pj_date "$now" %M) ))
    # The latest daily boundary (PROJECT_DAILY_AT local) at or before now; its
    # date names the day being closed. A project started after it owes nothing.
    local boundary=$(( now - ((now_m - at_m + 1440) % 1440) * 60 - 10#$(_pj_date "$now" %S) ))
    bdate=$(_pj_date "$boundary" %F)
    if (( boundary > start )) && [[ ! -f "$d/daily/$bdate.md" ]]; then
        printf 'daily %s' "$bdate"; return 0
    fi
    if [[ "${PROJECT_FREETIME:-1}" == "1" && "$phase" != final ]] && (( (now - start) % 604800 >= ${PROJECT_FREETIME_DAY:-5} * 86400 )); then
        fdir="$d/free-time/week-$week"
        [[ -f "$fdir/report.md" ]] && return 0
        started=$(cat "$IDENTITY_DIR/run/project_freetime_$week" 2>/dev/null) || started=""
        if [[ ! "$started" =~ ^[0-9]+$ ]]; then
            started="$now"
            mkdir -p "$IDENTITY_DIR/run" && printf '%s' "$now" > "$IDENTITY_DIR/run/project_freetime_$week" 2>/dev/null || true
        fi
        (( now - started < 86400 )) && printf 'freetime %s %s' "$week" $(( started + 43200 ))
    fi
    return 0
}

# Ritual instructions, from project-pristine/rituals/<kind>.md.
_project_ritual_text() {  # _project_ritual_text <kind> <arg> [until]
    local f
    f="$(_project_pristine)/rituals/$1.md"
    [[ -f "$f" ]] || return 0
    local until_s=""
    [[ -n "${3:-}" ]] && until_s=$(_pj_date "$3" '%a %Y-%m-%d %H:%M %Z')
    sed -e "s/{{date}}/$2/g" -e "s/{{week}}/$2/g" -e "s/{{until}}/$until_s/g" "$f"
}

# The project block of the wake prompt: charter, spec, memory, journal tail,
# state. Stable parts first, so the cached prompt prefix survives.
_project_section() {
    local d now start
    d=$(_project_dir); now=$(_pj_now); start=$(_project_started_at)
    local spec_max="${PROJECT_SPEC_MAX:-16000}" mem_max="${PROJECT_MEMORY_MAX:-14000}"
    printf 'PROJECT MODE. You are on a long unattended project. Your charter (project/charter.md, read-only) governs this wake and outranks the persona above wherever they differ:\n\n'
    sed "s/{{identity_name}}/$IDENTITY_NAME/g" "$d/charter.md"
    printf '\n\nProject specification (project/spec.md, read-only, verbatim from the humans):\n\n'
    head -c "$spec_max" "$d/spec.md" 2>/dev/null
    (( $(wc -c < "$d/spec.md" 2>/dev/null || echo 0) > spec_max )) && printf '\n[... spec continues; read project/spec.md for the rest]'
    printf '\n\nProject memory (project/project-memory.md, your formal record):\n\n'
    head -c "$mem_max" "$d/project-memory.md" 2>/dev/null
    (( $(wc -c < "$d/project-memory.md" 2>/dev/null || echo 0) > mem_max )) && printf '\n[... cut at %s bytes; read project/project-memory.md for the rest, and consider tightening it]' "$mem_max"
    printf '\n\nLast %s journal entries (project/journal.md):\n\n' "${PROJECT_JOURNAL_ENTRIES:-5}"
    awk -v n="${PROJECT_JOURNAL_ENTRIES:-5}" '
        /^### [0-9]/ { c++ } c { e[c] = e[c] $0 "\n" }
        END { if (!c) print "(no entries yet)"; for (i = (c > n ? c - n + 1 : 1); i <= c; i++) printf "%s", e[i] }' \
        "$d/journal.md" 2>/dev/null | tail -c "${PROJECT_JOURNAL_MAX:-8000}"
    local end; end=$(_project_end_at)
    if [[ -n "$end" ]]; then
        printf '\nProject clock: day %s of %s, week %s, phase %s. Started %s; the run ends %s (%s).\n' \
            $(( (now - start) / 86400 + 1 )) $(( (end - start + 86399) / 86400 )) "$(_project_week "$now")" "$(_project_phase "$now")" \
            "$(_pj_date "$start" '%Y-%m-%d %H:%M %Z')" "$(_pj_date "$end" '%Y-%m-%d %H:%M %Z')" \
            "$( (( end > now )) && printf '%s left' "$(_pj_left $(( end - now )))" || printf 'ended')"
    else
        printf '\nProject clock: day %s, week %s, started %s; no end date set.\n' \
            $(( (now - start) / 86400 + 1 )) "$(_project_week "$now")" "$(_pj_date "$start" '%Y-%m-%d %H:%M %Z')"
    fi
    printf 'STATE: %s' "$(head -n 3 "$d/STATE" 2>/dev/null | tr '\n' ' ' | cut -c1-300)"
    printf '\n'
    return 0
}

# Routing-signal lines for project mode. $1 = files the guard restored.
_project_signals() {
    local restored="${1:-}" d now today ritual kind arg until q title st b db
    d=$(_project_dir); now=$(_pj_now); today=$(_pj_date "$now" %F)
    if [[ "$(_pj_scale)" != 1 ]]; then
        printf -- '- PROJECT TIME runs %sx faster than real time (an accelerated run). It is now %s in project time. Use project time for every date you write (journal headers, Default-by dates); the system clock (`date`) shows real time and is wrong for this.\n' \
            "$(_pj_scale)" "$(_pj_date "$now" '%A %Y-%m-%d %H:%M %Z')"
    fi
    if [[ -n "$restored" ]]; then
        printf -- '- GUARD: these read-only files had changed and were restored from the pristine copy: %s. Never edit them; put reflections in project/addenda.md.\n' "$(printf '%s' "$restored" | tr '\n' ' ')"
    fi
    ritual=$(_project_due_ritual)
    if [[ -n "$ritual" ]]; then
        read -r kind arg until <<< "$ritual"
        case "$kind" in
            freetime)
                if (( now < until )); then
                    printf -- '- FREE TIME is open (weekly). Instructions:\n'
                else
                    printf -- '- FREE TIME has ended: write project/free-time/week-%s/report.md now, briefly, and return to the project.\n- Instructions were:\n' "$arg"
                fi ;;
            *) printf -- '- RITUAL DUE (%s). It outranks normal work this wake. Instructions:\n' "$kind" ;;
        esac
        _project_ritual_text "$kind" "$arg" "$until" | sed 's/^/    /'
    fi
    local open=0 blocking=0 nodef="" matured="" waiting="" unverified="" id kind t detail op bl db
    while IFS=$'\037' read -r id kind t detail op bl db; do
        case "$kind" in
            open)
                open=$(( open + 1 )); [[ "$bl" == yes ]] && blocking=$(( blocking + 1 ))
                if [[ -z "$db" ]]; then nodef="${nodef}${id} \"${t}\"; "
                elif [[ "$db" != never && ! "$db" > "$today" ]]; then matured="${matured}${id} \"${t}\" (default-by ${db}); "
                fi ;;
            human-waiting) waiting="${waiting}${id} \"${t}\"; " ;;
            unverified) unverified="${unverified}${id} " ;;
        esac
    done < <(_project_question_rows)
    waiting="${waiting%; }"; matured="${matured%; }"; nodef="${nodef%; }"; unverified="${unverified% }"
    if [[ -n "$waiting" ]]; then
        printf -- '- HUMAN ANSWER: a human answered %s. Apply it now, ahead of other work: update project-memory.md (and anything downstream it changes), add a "Resolution: YYYY-MM-DD human answer applied: <what changed>" line, mark it STATUS: answered, and journal it. Never edit the Answer line.\n' "$waiting"
    fi
    if [[ -n "$matured" ]]; then
        printf -- '- DEFAULT DUE: no human answered %s by its date. Apply its default now: record the call and its risk in project-memory.md under "Interpretation calls made without a human", add a "Resolution: YYYY-MM-DD default applied: <the default used>" line, mark it STATUS: defaulted, and unpark the work behind it.\n' "$matured"
    fi
    [[ -n "$unverified" ]] && printf -- '- QUESTION RECORD WRONG: %s is marked answered, but no human wrote its Answer line. Only a human answers. If you applied a default, mark it STATUS: defaulted with a Resolution line; otherwise set it back to open.\n' "$unverified"
    [[ -n "$nodef" ]] && printf -- '- These open questions have no Default-by line, so they can never resolve without a human: %s. Add a default and a date (or Default-by: never, on purpose).\n' "$nodef"
    (( open > 0 )) && printf -- '- Questions: %s open, %s blocking. Humans see every open question in their status view. Work an unblocked thread while they wait.\n' "$open" "$blocking"
    local phase start end left dl_stale="${PROJECT_DELIVERABLE_STALE_HOURS:-48}" dl_by="${PROJECT_DELIVERABLE_BY_DAYS:-1}" dm
    phase=$(_project_phase "$now"); start=$(_project_started_at); end=$(_project_end_at)
    [[ -n "$end" ]] && left=$(_pj_left $(( end > now ? end - now : 0 )))
    case "$phase" in
        build) printf -- '- DEADLINE: %s left in the run (phase: build). Spend effort where it moves project/deliverable.md toward a complete answer to the spec.\n' "$left" ;;
        harden) printf -- '- DEADLINE: %s left (phase: harden, second half). Prefer checking and stress-testing what the deliverable rests on (sources, uncertainty, sensitivity) over new scope.\n' "$left" ;;
        final) printf -- '- FINAL STRETCH: %s left. No new scope. Finish the deliverable: every number sourced or marked, every caveat explicit, open questions closed or defaulted, so it stands on its own when the run ends.\n' "$left" ;;
        ended) printf -- '- THE RUN HAS ENDED (%s). Do the final ritual if it is due; after that, set STATE to done.\n' "$(_pj_date "$end" '%Y-%m-%d %H:%M %Z')" ;;
    esac
    if ! _project_deliverable_started; then
        (( now - start >= dl_by * 86400 )) && printf -- '- DELIVERABLE MISSING: day %s and project/deliverable.md is still the template. Build the crude end-to-end model now (function: model) and write its headline number into a first full draft, however rough, with placeholders and caveats marked. Do this before any further exploration.\n' $(( (now - start) / 86400 + 1 ))
    else
        dm=$(_pj_mtime "$d/deliverable.md"); [[ -n "$dm" ]] || dm="$now"
        if [[ "$(_project_state)" == active && "$phase" != ended ]] && (( now - dm > dl_stale * 3600 )); then
            printf -- '- DELIVERABLE STALE: project/deliverable.md has not changed in %sh. Fold what the journal learned since into it.\n' $(( (now - dm) / 3600 ))
        fi
    fi
    local state; state=$(_project_state)
    case "$state" in
        blocked|done)
            printf -- '- STATE is %s, so wakes run at a rest pace. Rest (idle) unless a ritual or a default is due or you see a genuinely new way forward. If you do, set STATE back to active first.\n' "$state" ;;
        *)
            local jm stall_h="${PROJECT_STALL_HOURS:-12}"
            jm=$(_pj_mtime "$d/journal.md"); [[ -n "$jm" ]] || jm="$now"
            if (( now - jm > stall_h * 3600 )); then
                printf -- '- STALL: STATE is active but the journal has not changed in %sh. Re-read the spec, pick the smallest checkable next step and do it, or write the blocker to questions.md and set STATE to blocked. Do not keep circling.\n' $(( (now - jm) / 3600 ))
            fi ;;
    esac
    local wceil; wceil=$(_project_wake_ceiling)
    if (( wceil > 0 )); then
        printf -- '- WAKE BUDGET: about %s tokens for this whole wake, blind subagents included. One model step here costs roughly 20K to 40K tokens, and a blind run 100K to 400K; blind refuses to start once the wake has spent its share. Run at most one blind subagent per wake unless the budget clearly allows more.\n' "$wceil"
    fi
    local total="${PROJECT_TOTAL_TOKENS:-0}" tused
    if [[ "$total" =~ ^[0-9]+$ ]] && (( total > 0 )); then
        tused=$(_project_tokens_total)
        if (( tused * 10 >= total * 7 )); then
            printf -- '- RUN BUDGET: %s of the %s tokens for the whole run are spent. Spend the rest where it most improves the deliverable; leave enough for the final ritual.\n' "$tused" "$total"
        fi
    fi
    local cap="${PROJECT_DAILY_TOKENS:-0}" used
    if [[ "$cap" =~ ^[0-9]+$ ]] && (( cap > 0 )); then
        used=$(_project_tokens_24h)
        if (( used >= cap )); then
            printf -- '- BUDGET SPENT: %s of %s tokens used in the last 24h. Wakes are slowed until usage falls. Do only rituals and the cheapest essential work; prefer idle.\n' "$used" "$cap"
        elif (( used * 10 >= cap * 8 )); then
            printf -- '- BUDGET: %s of %s daily tokens used (24h window). Favor cheap, high-value steps.\n' "$used" "$cap"
        fi
    fi
    return 0
}

# Tokens this wake may spend, blind subagents included (0 = no ceiling):
# PROJECT_WAKE_TOKENS, else half the daily cap; never more than what is left
# of the whole-run cap. A step cap bounds one model run, not a wake: on the
# first live run one wake started two blind explorers and spent 1.3M tokens.
_project_wake_ceiling() {
    local w="${PROJECT_WAKE_TOKENS:-}" cap="${PROJECT_DAILY_TOKENS:-0}" total="${PROJECT_TOTAL_TOKENS:-0}" left
    if [[ ! "$w" =~ ^[0-9]+$ ]]; then
        w=0; [[ "$cap" =~ ^[0-9]+$ ]] && (( cap > 0 )) && w=$(( cap / 2 ))
    fi
    if [[ "$total" =~ ^[0-9]+$ ]] && (( total > 0 )); then
        left=$(( total - $(_project_tokens_total) )); (( left < 0 )) && left=0
        if (( w == 0 || left < w )); then w=$left; fi
    fi
    printf '%s' "$w"
}

# Seconds the next wake must at least wait in project mode (0 = no floor):
# the budget floor when spent, the rest floor when STATE is blocked or done
# and nothing (ritual, matured default) needs doing.
_project_delay_floor() {  # _project_delay_floor [tokens-this-wake]
    local cap="${PROJECT_DAILY_TOKENS:-0}" wake_tok="${1:-0}" floor=0
    [[ "$wake_tok" =~ ^[0-9]+$ ]] || wake_tok=0
    if _project_over_budget; then floor=$(_pj_real_span "${PROJECT_BUDGET_REST:-1800}"); fi
    # Pacing: a wake that cost T tokens waits T/cap of a day, so a mind that is
    # busy around the clock spends the daily cap evenly instead of burning it
    # by noon and sleeping until the window rolls. PROJECT_PACE=0 turns it off.
    if [[ "${PROJECT_PACE:-1}" != 0 && "$cap" =~ ^[0-9]+$ ]] && (( cap > 0 )); then
        local pace=$(( wake_tok * 86400 / cap / $(_pj_scale) ))
        (( pace > floor )) && floor=$pace
    fi
    local st; st=$(_project_state)
    # A run past its end with the final report written rests like done.
    [[ "$(_project_phase)" == ended && -f "$(_project_dir)/reports/final.md" ]] && st=done
    case "$st" in
        blocked|done)
            # Capture, then match: `_project_signals | grep -q` under pipefail
            # fails when grep exits early and the writer takes SIGPIPE.
            local sig; sig=$(_project_signals)
            if [[ -z "$(_project_due_ritual)" && "$sig" != *"- DEFAULT DUE"* && "$sig" != *"- HUMAN ANSWER"* ]]; then
                local rest; rest=$(_pj_real_span "${PROJECT_REST:-3600}")
                (( floor < rest )) && floor=$rest
            fi ;;
    esac
    printf '%s' "$floor"
}

# Should this timer wake skip the model entirely? Resting must be free: a
# blocked or done mind that wakes once a project hour only to idle spends a
# model call each time (the first live run's finished mind did). Skip when
# STATE is blocked or done and nothing is due (no ritual, matured default or
# human answer). A blocked mind still gets one real wake per
# PROJECT_REST_CHECK project seconds (default a day) to look for a new way
# forward; a run past its end with its final report gets none. $1 = wake
# mode: a reactive wake (someone wrote to the mind) always runs.
_project_should_skip_rest() {
    [[ "${1:-}" == reactive ]] && return 1
    local st; st=$(_project_state)
    [[ "$(_project_phase)" == ended && -f "$(_project_dir)/reports/final.md" ]] && st=done-final
    case "$st" in blocked|done|done-final) ;; *) return 1 ;; esac
    [[ -n "$(_project_due_ritual)" ]] && return 1
    local sig; sig=$(_project_signals)
    [[ "$sig" == *"- DEFAULT DUE"* || "$sig" == *"- HUMAN ANSWER"* ]] && return 1
    [[ "$st" == done-final ]] && return 0
    local f="$IDENTITY_DIR/run/project_rest_checked" last now
    now=$(_pj_now); last=$(cat "$f" 2>/dev/null) || last=0
    [[ "$last" =~ ^[0-9]+$ ]] || last=0
    if (( now - last >= ${PROJECT_REST_CHECK:-86400} )); then
        printf '%s' "$now" > "$f" 2>/dev/null || true
        return 1
    fi
    return 0
}

# Commit project/ if anything changed. $1 = message (the run's FINAL).
_project_commit() {
    local d msg
    d=$(_project_dir); msg="${1:-wake}"
    command -v git >/dev/null 2>&1 || return 0
    [[ -d "$d/.git" ]] || git -C "$d" init -q 2>/dev/null || return 0
    [[ -n "$(git -C "$d" status --porcelain 2>/dev/null)" ]] || return 0
    git -C "$d" add -A >/dev/null 2>&1 || return 0
    git -C "$d" -c user.name="${IDENTITY_NAME:-headlong}" -c user.email="${IDENTITY_NAME:-headlong}@headlong.local" \
        commit -q -m "$(printf '%s' "$msg" | head -c 2000)" >/dev/null 2>&1 || true
    return 0
}
