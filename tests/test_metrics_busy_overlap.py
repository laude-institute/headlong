import base64
from datetime import datetime, timedelta, timezone
import gzip
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


class MetricsBusyOverlapTests(unittest.TestCase):
    def test_full_extractor_keeps_old_overlapping_run_busy(self):
        script = (Path(__file__).resolve().parents[1] / "deploy/scripts/audel-metrics").read_text(encoding="utf-8")
        extractor = script.split("<<'PYEOF'\n", 1)[1].split("\nPYEOF", 1)[0]
        origin = datetime(2026, 1, 1, tzinfo=timezone.utc)
        rows = []

        def step(seconds, kind, **fields):
            rows.append({"ts": (origin + timedelta(seconds=seconds)).isoformat(),
                         "type": kind, **fields})

        step(10, "reasoning", run_id="long")
        for index, start in enumerate([20, 30, 40, 50]):
            step(start, "reasoning", run_id=f"short-{index}")
            step(start + 1, "final", run_id=f"short-{index}")
        step(100, "final", run_id="long")
        expected = [False, True, True, True, False]
        for index, seconds in enumerate([5, 10, 70, 100, 101]):
            step(seconds, "message", step_id=f"message-{index}",
                 **{"from": "reader", "to": "fixture"})
        rows.sort(key=lambda row: row["ts"])
        with tempfile.TemporaryDirectory() as temporary:
            identity = Path(temporary) / "fixture"
            trajectory = identity / "trajectories" / "00000000-root"
            trajectory.mkdir(parents=True)
            (trajectory / "trajectory.jsonl").write_text(
                "".join(json.dumps(row) + "\n" for row in rows), encoding="utf-8")
            result = subprocess.run(
                [sys.executable, "-", str(identity)], input=extractor,
                text=True, encoding="utf-8", capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
        payload = result.stdout.split("AUDEL_METRICS_BEGIN\n", 1)[1].split("AUDEL_METRICS_END", 1)[0]
        data = json.loads(gzip.decompress(base64.b64decode(payload)))
        self.assertEqual(data["inbound"], 5)
        self.assertEqual(data["skipped"], 0)
        self.assertEqual([record[2] for record in data["records"]], expected)


if __name__ == "__main__":
    unittest.main()
