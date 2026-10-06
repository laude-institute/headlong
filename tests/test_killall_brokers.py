import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class KillallBrokerTests(unittest.TestCase):
    def check_mode(self, dry_run, scenario="mixed"):
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
    if any(value.split("=", 1)[0] not in {"name", "label"} for value in filters):
        print("invalid filter", file=sys.stderr)
        sys.exit(1)
    rows = [("sandbox", "shellm-123", ""), ("broker", "shellm-broker", "1"),
            ("nonbroker", "shellm-456", "0"), ("unrelated", "other-app", "")]
    scenario = os.environ["DOCKER_SCENARIO"]
    if scenario == "broker-only":
        rows = [row for row in rows if row[2] == "1"]
    elif scenario == "empty":
        rows = []
    for identifier, name, broker in rows:
        if "name=^shellm-" in filters and not name.startswith("shellm-"):
            continue
        if "label=shellm.broker=1" in filters and broker != "1":
            continue
        if "-q" in args:
            print(identifier)
        elif args[args.index("--format") + 1] == r'{{if ne (.Label "shellm.broker") "1"}}{{.ID}}\\t{{.Names}} ({{.Status}}){{end}}':
            print(identifier + "\\t" + name + " (Up)" if broker != "1" else "")
        elif args[args.index("--format") + 1] == '  {{.Names}} ({{.Status}})':
            print("  " + name + " (Up)")
        else:
            sys.exit("unsupported format in fixture")
elif args[:2] != ["rm", "-f"]:
    sys.exit(1)
''', encoding="utf-8")
            docker.chmod(0o755)
            environment = dict(os.environ, PATH=str(root) + os.pathsep + os.environ["PATH"],
                               DOCKER_CALLS=str(calls), DOCKER_SCENARIO=scenario)
            script = Path(__file__).resolve().parents[1] / "tools/headlong-killall"
            result = subprocess.run(["bash", str(script)] + (["--dry-run"] if dry_run else []),
                                    env=environment, text=True, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            commands = [json.loads(line) for line in calls.read_text().splitlines()]
            candidates = [args for args in commands if "name=^shellm-" in args]
            self.assertEqual(len(candidates), 1)
            removals = [args for args in commands if args[0] == "rm"]
            expected = [["rm", "-f", "sandbox", "nonbroker"]] if not dry_run and scenario == "mixed" else []
            self.assertEqual(removals, expected)
            if scenario == "mixed":
                self.assertIn("shellm-123 (Up)", result.stdout)
                self.assertIn("shellm-456 (Up)", result.stdout)
            else:
                self.assertNotIn("remove docker container(s)", result.stdout)
                self.assertNotIn("Removing docker container(s)", result.stdout)
            self.assertNotIn("other-app", result.stdout)
            if scenario != "empty":
                self.assertEqual(result.stdout.count("shellm-broker (Up)"), 1)
                candidates_output, broker_output = result.stdout.split("Note: broker container(s) left running", 1)
                self.assertNotIn("shellm-broker", candidates_output)
                self.assertIn("shellm-broker (Up)", broker_output)
            else:
                self.assertNotIn("broker container(s) left running", result.stdout)

    def test_normal_cleanup_keeps_broker(self):
        self.check_mode(False)

    def test_dry_run_keeps_broker_out_of_removal_listing(self):
        self.check_mode(True)

    def test_broker_only(self):
        for dry_run in (False, True):
            with self.subTest(dry_run=dry_run):
                self.check_mode(dry_run, "broker-only")

    def test_no_containers(self):
        for dry_run in (False, True):
            with self.subTest(dry_run=dry_run):
                self.check_mode(dry_run, "empty")


if __name__ == "__main__":
    unittest.main()
