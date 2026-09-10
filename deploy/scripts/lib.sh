# deploy/scripts/lib.sh — shared helpers for the deploy scripts. Source, don't run.
# shellcheck shell=bash
#
# These scripts wrap the terraform/aws incantations from
# deploy/terraform/README.md. They only need AWS credentials + terraform
# state — not CLOUDFLARE_API_TOKEN (that's only for terraform plan/apply),
# so they work outside direnv.

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPTS_DIR/../.." && pwd)"
# Which stack to drive: SHELLM_TF_STACK=terraform-slack targets the Slack
# box; default is the demo stack.
TF_DIR="$REPO_ROOT/deploy/${SHELLM_TF_STACK:-terraform}"
[[ -d "$TF_DIR" ]] || { echo "error: no such stack dir: $TF_DIR" >&2; exit 1; }

die()  { echo "error: $*" >&2; exit 1; }
info() { printf '==> %s\n' "$*"; }

tf() { terraform -chdir="$TF_DIR" "$@"; }

require_tools() {
    local tool
    for tool in "$@"; do
        command -v "$tool" >/dev/null 2>&1 \
            || die "'$tool' not found — see deploy/terraform/README.md 'Install the tools'"
    done
}

require_state() {
    [[ -f "$TF_DIR/terraform.tfstate" ]] \
        || die "no terraform state in $TF_DIR — provision first (see the README there)"
}

require_aws() {
    aws sts get-caller-identity >/dev/null 2>&1 \
        || die "AWS credentials not working — aws configure / AWS_PROFILE / SSO login"
}

# Read a simple `key = "value"` line from terraform.tfvars.
tfvar() {
    local line=""
    line=$(grep -E "^[[:space:]]*$1[[:space:]]*=" "$TF_DIR/terraform.tfvars" 2>/dev/null | head -1) || true
    line="${line#*=}"
    line="${line%%#*}"
    line=$(printf '%s' "$line" | tr -d '"' | xargs)
    printf '%s' "${line:-${2:-}}"
}

region()      { tfvar aws_region; }
instance_id() { tf output -raw instance_id; }

instance_state() {
    aws ec2 describe-instances --region "$(region)" --instance-ids "$(instance_id)" \
        --query 'Reservations[0].Instances[0].State.Name' --output text
}

# Run a multi-line bash script on the box as root and print its output once
# it finishes. The script travels base64-encoded so bashisms and multi-line
# quoting survive the trip.
#
# This uses SSM RunCommand (send-command, then poll for the result) rather
# than an interactive session. The interactive channel is a terminal stream
# that wedges at session open when a stale session-manager-plugin lingers,
# and drops output chunks nondeterministically; RunCommand is a plain API
# call with the output fetched afterwards. Its one limit: output is capped
# at 24KB per stream — keep data small.
run_script_on_box() {
    require_tools jq
    local b64 cmd_id status tries
    b64=$(printf '%s' "$1" | base64 | tr -d '\n')
    cmd_id=$(aws ssm send-command --region "$(region)" \
        --instance-ids "$(instance_id)" \
        --document-name AWS-RunShellScript \
        --parameters "$(jq -n --arg c "echo $b64 | base64 -d | bash" '{commands: [$c]}')" \
        --query 'Command.CommandId' --output text) || return 1
    # Poll until the invocation leaves the queue. The invocation can take a
    # moment to exist after send-command, which reads as Pending here.
    tries=0
    while :; do
        status=$(aws ssm get-command-invocation --region "$(region)" \
            --command-id "$cmd_id" --instance-id "$(instance_id)" \
            --query Status --output text 2>/dev/null) || status=Pending
        case "$status" in
            Pending|InProgress|Delayed)
                tries=$((tries + 1))
                [[ "$tries" -gt 450 ]] && { echo "run_script_on_box: timed out after 15m (command $cmd_id still $status)" >&2; return 1; }
                sleep 2 ;;
            *) break ;;
        esac
    done
    local out err
    out=$(aws ssm get-command-invocation --region "$(region)" \
        --command-id "$cmd_id" --instance-id "$(instance_id)" \
        --query StandardOutputContent --output text)
    err=$(aws ssm get-command-invocation --region "$(region)" \
        --command-id "$cmd_id" --instance-id "$(instance_id)" \
        --query StandardErrorContent --output text)
    [[ -n "$out" && "$out" != "None" ]] && printf '%s' "$out"
    [[ -n "$err" && "$err" != "None" ]] && printf '%s' "$err" >&2
    [[ "$status" == "Success" ]]
}

# Run one command on the box over SSM, streaming its output as it happens.
# Only for commands that genuinely stream (deploy/scripts/watch's
# journalctl -f) or need a terminal; one-shot commands belong in
# run_script_on_box, which uses the reliable non-interactive channel.
run_on_box() {
    require_tools session-manager-plugin jq
    # JSON form: the shorthand parser would split the command on commas.
    # The EOF grep drops the plugin's harmless complaint when the command
    # session closes.
    aws ssm start-session --region "$(region)" --target "$(instance_id)" \
        --document-name AWS-StartInteractiveCommand \
        --parameters "$(jq -n --arg c "$1" '{command: [$c]}')" \
        2> >(grep -v "Cannot perform start session: EOF" >&2 || true)
}
