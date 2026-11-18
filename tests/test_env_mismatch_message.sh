#!/usr/bin/env bash
# test_env_mismatch_message.sh — a reuse refusal names the axis that disagreed.
#
# env_metadata_matches refuses a running env for eight reasons: the access
# mode; under broker access, the broker transport; under socket access, the
# docker socket; under dind access, privilege; for docker envs, the tool
# mounts version and the image; the --var directory mounts; and the workdirs
# directory. The refusal message used to enumerate only three of those (tool
# mounts, image, var mounts), so a refusal for any other reason fell through
# to a sentence about docker_access that printed the same value twice and
# sent the reader to fix a knob that already matched. Each case below refuses
# an env on exactly one axis, with every other axis aligned, and asserts the
# message names that axis on both sides.
#
# The predicate and the message are lifted out of bin/shellm with sed (as
# tests/test_mem_frontmatter.sh does for bin/mem), so an env directory on
# disk is the only input and no Docker daemon is involved.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }

eval "$(sed -n '/^docker_metadata_value()/,/^}/p'         "$REPO/bin/shellm")"
eval "$(sed -n '/^_compute_var_mounts()/,/^}/p'           "$REPO/bin/shellm")"
eval "$(sed -n '/^env_metadata_matches()/,/^}/p'          "$REPO/bin/shellm")"
eval "$(sed -n '/^env_metadata_mismatch_message()/,/^}/p' "$REPO/bin/shellm")"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

SHELLM_ENVS_DIR="$WORK/envs"
SHELLM_WORKDIRS_DIR="$WORK/workdirs"
# shellcheck disable=SC2034  # ambient run settings the lifted functions read
SHELLM_DOCKER_ACCESS="none"
# shellcheck disable=SC2034
SHELLM_DOCKER_IMAGE="ubuntu:24.04"
# shellcheck disable=SC2034
_SHELLM_TOOL_MOUNTS_VERSION="v1"

# make_env NAME [KEY=VALUE...] — an env directory as env_register writes one,
# with every axis aligned to this run. Each KEY=VALUE moves exactly one axis.
make_env() {
    local name="$1"; shift
    local d="$SHELLM_ENVS_DIR/$name"
    mkdir -p "$d"
    printf 'docker\n'                     > "$d/type"
    printf 'none\n'                       > "$d/docker_access"
    printf 'v1\n'                         > "$d/tool_mounts_version"
    printf '%s\n' "$SHELLM_WORKDIRS_DIR"  > "$d/workdirs_dir"
    : > "$d/var_mounts"
    printf '%s\n' "$SHELLM_DOCKER_IMAGE"  > "$d/image"
    local kv key val
    for kv in "$@"; do
        key="${kv%%=*}" val="${kv#*=}"
        printf '%s\n' "$val" > "$d/$key"
    done
    return 0
}

# refuse_axis LABEL ENV STORED REQUESTED — the predicate must refuse, and the
# message must name both the stored and the requested value.
refuse_axis() {
    local label="$1" env_name="$2" stored="$3" requested="$4" msg
    if env_metadata_matches "$env_name"; then
        bad "$label" "predicate accepted an env it must refuse"
        return
    fi
    msg=$(env_metadata_mismatch_message "$env_name")
    if [[ "$msg" == *"$stored"* && "$msg" == *"$requested"* ]]; then
        ok "$label"
    else
        bad "$label" "message must name $stored and $requested, got: $msg"
    fi
}

# no_access_blame LABEL ENV — when the access mode itself matches, the message
# must not point the reader at it.
no_access_blame() {
    local label="$1" env_name="$2" msg
    msg=$(env_metadata_mismatch_message "$env_name")
    if [[ "$msg" != *docker_access* ]]; then
        ok "$label"
    else
        bad "$label" "message blames a matching access mode, got: $msg"
    fi
}

# --- control: a fully aligned env is reused, so no message is built -----------
make_env aligned
env_metadata_matches aligned \
    && ok "an aligned env is reusable" \
    || bad "an aligned env is reusable" "predicate refused an aligned env"

# --- 1. workdirs directory ----------------------------------------------------
make_env wd "workdirs_dir=$WORK/elsewhere"
SHELLM_DOCKER_ACCESS=none refuse_axis \
    "a workdirs mismatch names both directories" wd "$WORK/elsewhere" "$WORK/workdirs"
SHELLM_DOCKER_ACCESS=none no_access_blame \
    "a workdirs mismatch does not blame access mode" wd

# --- 2. broker transport under a matching broker mode -------------------------
make_env bt "docker_access=broker" "docker_broker_transport=socket"
SHELLM_DOCKER_ACCESS=broker _SHELLM_DOCKER_BROKER_TRANSPORT=filesystem refuse_axis \
    "a broker transport mismatch names both transports" bt "socket" "filesystem"
SHELLM_DOCKER_ACCESS=broker _SHELLM_DOCKER_BROKER_TRANSPORT=filesystem no_access_blame \
    "a broker transport mismatch does not blame access mode" bt

# --- 3. docker socket under a matching socket mode ----------------------------
make_env sk "docker_access=socket" "docker_socket=$WORK/elsewhere.sock"
SHELLM_DOCKER_ACCESS=socket SHELLM_DOCKER_SOCKET="$WORK/this-run.sock" refuse_axis \
    "a socket mismatch names both sockets" sk "$WORK/elsewhere.sock" "$WORK/this-run.sock"
SHELLM_DOCKER_ACCESS=socket SHELLM_DOCKER_SOCKET="$WORK/this-run.sock" no_access_blame \
    "a socket mismatch does not blame access mode" sk

# --- 4. privilege under a matching dind mode ----------------------------------
make_env di "docker_access=dind" "privileged=0"
SHELLM_DOCKER_ACCESS=dind refuse_axis \
    "a privilege mismatch names both privilege values" di "privileged=0" "privileged=1"
SHELLM_DOCKER_ACCESS=dind no_access_blame \
    "a privilege mismatch does not blame access mode" di

# --- 5. a legacy env with no workdirs directory recorded ---------------------
make_env legacy
rm "$SHELLM_ENVS_DIR/legacy/workdirs_dir"
SHELLM_DOCKER_ACCESS=none refuse_axis \
    "an env with no recorded workdirs says not recorded" legacy "not recorded" "$WORK/workdirs"
SHELLM_DOCKER_ACCESS=none no_access_blame \
    "an unrecorded workdirs does not blame access mode" legacy

# --- 6. the access mode itself: the fallback sentence stays right for it -----
make_env ac "docker_access=broker"
SHELLM_DOCKER_ACCESS=none refuse_axis \
    "an access mode mismatch still names both modes" ac "docker_access=broker" "docker_access=none"

# --- 7. a mode detail never outranks the mode itself --------------------------
make_env sb "docker_access=socket" "docker_socket=$WORK/elsewhere.sock"
SHELLM_DOCKER_ACCESS=broker _SHELLM_DOCKER_BROKER_TRANSPORT=socket refuse_axis \
    "a mode mismatch is not misread as a transport mismatch" sb "docker_access=socket" "docker_access=broker"
msg=$(SHELLM_DOCKER_ACCESS=broker _SHELLM_DOCKER_BROKER_TRANSPORT=socket env_metadata_mismatch_message sb)
[[ "$msg" != *transport* ]] \
    && ok "a mode mismatch does not mention transport" \
    || bad "a mode mismatch does not mention transport" "got: $msg"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
