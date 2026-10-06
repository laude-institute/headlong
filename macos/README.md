# macos/

A small native macOS client for talking to a local agent: a menu bar
app (Swift, no Xcode project) with a popover chat window and
notifications. Build it with the Makefile in `Shellm/`. The design
notes are in [design/macos_client.md](../design/macos_client.md).

## Hotkey recorder regression check

Build with `make -C macos/Shellm app` and launch the resulting app in a
macOS desktop session. The repository's macOS CI job tests Bash, not this
Swift client.

1. Open Settings, select Record, and enter a new shortcut. Repeat several
   times and confirm each shortcut is saved once.
2. Select Record, then Cancel. Type in a Settings field and confirm that
   the shortcut does not change. Repeat several times.
3. Select Record, then close Settings with its close button before pressing
   a key. Open the chat and type without sending. Confirm that the first
   key appears in the input and does not change the shortcut.
4. Reopen Settings and confirm that the recorder is idle. Record another
   shortcut, then repeat the close and reopen check several times.
5. While recording, closing another app window must not cancel the recorder.
   Cleanup must apply only to the Settings window that owns the recorder.
