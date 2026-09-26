import importlib.util
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("tcp_tuning_score", ROOT / "tcp-tuning-score.py")
score = importlib.util.module_from_spec(spec)
spec.loader.exec_module(score)


def run(rate, retrans=0):
    return {"rate": rate, "retrans": retrans, "bytes": 100000000, "rtt": 100.0}


class ScoreTest(unittest.TestCase):
    def test_balanced_dual_family_candidate(self):
        records = {
            "A": {"4": [run(100), run(102)], "6": [run(80), run(82)]},
            "B4": {"4": [run(130)], "6": [run(83)]},
            "B6": {"4": [run(99)], "6": [run(110)]},
        }
        chosen = score.choose(records, ["4", "6"], ["B4", "B6"], [8388608, 12582912])
        self.assertEqual(chosen["status"], "candidate")
        self.assertEqual(chosen["profile"], "B6")
        records["B6"]["4"].append(run(100))
        records["B6"]["6"].append(run(108))
        self.assertEqual(score.confirm(records, ["4", "6"], "B6")["status"], "keep")

    def test_baseline_drift_aborts(self):
        records = {"A": {"4": [run(100), run(50)]}, "B": {"4": [run(150)]}}
        self.assertEqual(score.choose(records, ["4"], ["B"], [8388608])["status"], "unstable")

    def test_missing_gain_or_other_family_regression_rejected(self):
        records = {
            "A": {"4": [run(100), run(102)], "6": [run(100), run(102)]},
            "B": {"4": [run(130)], "6": [run(80)]},
        }
        self.assertEqual(score.choose(records, ["4", "6"], ["B"], [8388608])["status"], "no_gain")

    def test_confirmation_requires_two_consistent_runs(self):
        records = {"A": {"4": [run(100), run(102)]}, "B": {"4": [run(130), run(90)]}}
        self.assertEqual(score.confirm(records, ["4"], "B")["status"], "restore")


if __name__ == "__main__":
    unittest.main()
