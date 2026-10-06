# Recover a stuck chat index

`chat history --with`, `chat pending`, and `chat sent` share derived indexes
next to the root trajectory. An updater killed before releasing
`messages.jsonl.lock` can leave those indexes stuck. Calls still return, but
new messages, requests, and delivery notices are absent from the indexes.

The box's existing silence timer alerts when the lock directory is older
than `HEADLONG_SILENCE_SECS` (30 minutes by default), even if the trajectory
is still growing. The alert repeats at `HEADLONG_SILENCE_REPOST_SECS`.
A long rebuild can also hold the lock, so the watchdog never deletes it
based on age. Check for a live rebuild before beginning recovery.

## Stop, reset, and restart

1. Record which services are running. Stop the affected identity's thinkers
   and every other process that can call `chat` for that identity. On a box,
   include the web service and installed bridges. Stop any manual CLI reader
   or agent shell as well. Wait for the stops to finish and investigate any
   failed stop. A thinkers-only restart does not establish this condition.
2. Run `chat index-reset --offline` with the affected identity's trajectory
   environment. The flag acknowledges that **all chat callers are stopped**;
   the command cannot establish that condition for you.
3. Restart only the services that were running before recovery. The next
   indexed read rebuilds from the trajectory, so allow time for a large log.
   Check that a new message appears in history and that the alert clears on
   the next timer tick.

For Audel's standard box layout, after completing step 1, the reset can run
without loading API keys or starting an identity shell:

```bash
app=/opt/shellm/app
identity_dir="$app/.identities/audel"
root_id=$(sed -n 's/^root_trajectory=//p' "$identity_dir/info.txt")
test -n "$root_id" || exit 1
sudo -u shellm env PATH="$app/bin:/usr/bin:/bin" \
    TRAJ_DIR="$identity_dir/trajectories" TRAJ_ID="$root_id" \
    "$app/bin/chat" index-reset --offline
```

The reset removes `messages.jsonl`, `deferrals.jsonl`, `deliveries.jsonl`,
and `messages.jsonl.offset`, then removes the empty lock directory. Resetting
all derived data also removes partial writes from an interrupted update.
The trajectory itself is unchanged. If removal fails, the lock is retained
so the next reader cannot extend a partially reset index. The command refuses
a symlinked or nonempty lock directory and never deletes one recursively.

Use the same stopped-caller procedure on a local install. SIGKILL cannot be
handled by a shell trap; recovery is deliberately an operator action at a
stopped service boundary, rather than automatic lock stealing during reads.
