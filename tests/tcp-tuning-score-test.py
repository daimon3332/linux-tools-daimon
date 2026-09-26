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
            "B6": {"4": [run(102)], "6": [run(110)]},
        }
        chosen = score.choose(records, ["4", "6"], ["B4", "B6"], [8388608, 12582912])
        self.assertEqual(chosen["status"], "candidate")
        self.assertEqual(chosen["profile"], "B6")
        records["B6"]["4"].extend([run(102), run(103)])
        records["B6"]["6"].append(run(108))
        records["B6"]["6"].append(run(111))
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

    def test_lossy_baseline_allows_down_candidate(self):
        records = {
            "A": {"6": [run(10, retrans=14000), run(11, retrans=13000)]},
            "B": {"6": [run(190, retrans=2400)]},
        }
        self.assertEqual(score.choose(records, ["6"], ["B"], [8388608])["status"], "candidate")

    def test_candidate_with_worse_loss_than_clean_baseline_rejected(self):
        records = {
            "A": {"6": [run(100, retrans=100), run(101, retrans=120)]},
            "B": {"6": [run(150, retrans=4000)]},
        }
        self.assertEqual(score.choose(records, ["6"], ["B"], [8388608])["status"], "no_gain")

    def test_confirmation_requires_two_consistent_runs(self):
        records = {"A": {"4": [run(100), run(102)]}, "B": {"4": [run(130), run(90)]}}
        self.assertEqual(score.confirm(records, ["4"], "B")["status"], "restore")

    def test_fast_exploration_cannot_hide_slower_confirmation(self):
        records = {"A": {"4": [run(100), run(100)]},
                   "B": {"4": [run(140), run(97)]}}
        self.assertEqual(score.confirm(records, ["4"], "B")["status"], "restore")

    def test_dual_family_net_regression_rejected(self):
        records = {"A": {"4": [run(100), run(100)], "6": [run(100), run(100)]},
                   "B": {"4": [run(105.1)], "6": [run(95)]}}
        self.assertEqual(score.choose(records, ["4", "6"], ["B"], [8388608])["status"], "no_gain")

    def test_two_new_confirmations_required(self):
        records = {"A": {"4": [run(100), run(100)]},
                   "B": {"4": [run(140), run(120)]}}
        self.assertEqual(score.confirm(records, ["4"], "B")["status"], "restore")
        records["B"]["4"].append(run(120))
        self.assertEqual(score.confirm(records, ["4"], "B")["status"], "keep")

    def test_adjacent_baselines_and_confirmation_threshold(self):
        samples = [('A', 100), ('B', 140), ('A', 100), ('B', 104),
                   ('A', 100), ('B', 120), ('A', 100)]
        records = {'A': {'4': []}, 'B': {'4': []}}
        for order, (profile, rate) in enumerate(samples):
            measurement = run(rate)
            measurement['order'] = order
            records[profile]['4'].append(measurement)
        self.assertEqual(score.confirm(records, ['4'], 'B')['status'], 'restore')
        records['B']['4'][1]['rate'] = 120
        self.assertEqual(score.confirm(records, ['4'], 'B')['status'], 'keep')


if __name__ == "__main__":
    unittest.main()
