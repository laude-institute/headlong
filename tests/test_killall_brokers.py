import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class KillallBrokerTests(unittest.TestCase):
    def check_mode(self, dry_run):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            calls = root / "calls.jsonl"
            for command in ["ps", "pgrep"]:
                stub = root / command
                stub.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
                stub.chmod(0o755)
            docker = root / "docker"
            docker.write_text('''#!/usr/bin/env python3
import json
import os
import sys
args = sys.argv[1:]
with open(os.environ["DOCKER_CALLS"], "a") as stream:
    stream.write(json.dumps(args) + "\\n")
if args[0] == "ps":
    filters = [args[i + 1] for i, arg in enumerate(args) if arg == "--filter"]
    rows = [("sandbox", "shellm-123", False), ("broker", "shellm-broker", True)]
    for identifier, name, broker in rows:
        if "label=shellm.broker=1" in filters and not broker:
            continue
        if "label!=shellm.broker=1" in filters and broker:
            continue
        print(identifier if "-q" in args else "  " + name + " (Up)")
elif args[:2] != ["rm", "-f"]:
    sys.exit(1)
''', encoding="utf-8")
            docker.chmod(0o755)
            environment = dict(os.environ, PATH=str(root) + os.pathsep + os.environ["PATH"],
                               DOCKER_CALLS=str(calls))
            script = Path(__file__).resolve().parents[1] / "tools/headlong-killall"
            result = subprocess.run(["bash", str(script)] + (["--dry-run"] if dry_run else []),
                                    env=environment, text=True, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            commands = [json.loads(line) for line in calls.read_text().splitlines()]
            candidates = [args for args in commands if "name=^shellm-" in args]
            self.assertEqual(len(candidates), 2)
            self.assertTrue(all("label!=shellm.broker=1" in args for args in candidates))
            removals = [args for args in commands if args[0] == "rm"]
            self.assertEqual(removals, [] if dry_run else [["rm", "-f", "sandbox"]])
            self.assertIn("shellm-123 (Up)", result.stdout)
            self.assertEqual(result.stdout.count("shellm-broker (Up)"), 1)
            self.assertIn("broker container(s) left running", result.stdout)

    def test_normal_cleanup_keeps_broker(self):
        self.check_mode(False)

    def test_dry_run_keeps_broker_out_of_removal_listing(self):
        self.check_mode(True)


if __name__ == "__main__":
    unittest.main()
