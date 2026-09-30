#!/usr/bin/env python3
"""Rank repeated receiver-side iperf3 measurements conservatively."""

import argparse
import json
import math
import statistics
from collections import defaultdict
from pathlib import Path


def load_records(path):
    records = defaultdict(lambda: defaultdict(list))
    for order, line in enumerate(Path(path).read_text(encoding="utf-8").splitlines()):
        profile, family, rate, retrans, transferred, rtt = line.split("\t")
        measurement = {
            "rate": float(rate),
            "retrans": int(retrans),
            "bytes": int(transferred),
            "rtt": float(rtt),
            "order": order,
        }
        if not math.isfinite(measurement["rate"]) or measurement["rate"] <= 0:
            raise ValueError("invalid receiver rate")
        if measurement["bytes"] <= 0 or measurement["retrans"] < 0:
            raise ValueError("invalid receiver bytes")
        records[profile][family].append(measurement)
    return records


def estimated_loss(run):
    return run["retrans"] * 1460 / run["bytes"]


def baseline(records, families):
    base = {}
    loss = {}
    drift = 0.0
    for family in families:
        measurements = records["A"][family]
        if len(measurements) < 2:
            raise ValueError(f"IPv{family} baseline needs at least two independent runs")
        rates = [run["rate"] for run in measurements]
        center = statistics.median(rates)
        family_drift = max(abs(a - b) / statistics.median((a, b))
                           for a, b in zip(rates, rates[1:]))
        drift = max(drift, family_drift)
        base[family] = center
        loss[family] = statistics.median(estimated_loss(run) for run in measurements)
    return base, loss, drift


def reference(records, family, run, base, base_loss, min_gain):
    if "order" not in run:
        return base[family], base_loss[family], min_gain
    before = [a for a in records["A"][family] if a["order"] < run["order"]]
    after = [a for a in records["A"][family] if a["order"] > run["order"]]
    if not before or not after:
        raise ValueError("candidate needs adjacent A/B/A reference runs")
    pair = (before[-1], after[0])
    center = statistics.median(a["rate"] for a in pair)
    drift = abs(pair[0]["rate"] - pair[1]["rate"]) / center
    if drift > 0.20:
        return center, 0.0, math.inf
    return center, statistics.median(estimated_loss(a) for a in pair), max(0.05, drift + 0.03)


def score_candidate(records, profile, families, base, base_loss, min_gain, confirmed):
    selected = {}
    for family in families:
        runs = records.get(profile, {}).get(family, [])
        if len(runs) < (3 if confirmed else 1):
            return None
        selected[family] = runs[-2:] if confirmed else runs[:1]
    round_scores = []
    for index in range(2 if confirmed else 1):
        ratios, improved = [], False
        for family in families:
            run = selected[family][index]
            center, loss, threshold = reference(records, family, run, base, base_loss, min_gain)
            ratio = run["rate"] / center
            if ratio < 1.0 or estimated_loss(run) > max(0.03, loss + 0.03):
                return None
            improved |= ratio >= 1 + threshold
            ratios.append(ratio)
        if not improved:
            return None
        round_scores.append(math.prod(ratios) ** (1 / len(ratios)))
    return min(round_scores)


def choose(records, families, profiles, ceilings):
    base, base_loss, drift = baseline(records, families)
    if drift > 0.20:
        return {"status": "unstable", "drift": round(drift, 4), "baseline": base}
    threshold = max(0.05, drift + 0.03)
    ranked = []
    for profile, ceiling in zip(profiles, ceilings):
        score = score_candidate(records, profile, families, base, base_loss, threshold, False)
        if score is not None:
            ranked.append((score, -ceiling, profile, ceiling))
    if not ranked:
        return {"status": "no_gain", "drift": round(drift, 4),
                "threshold": round(threshold, 4), "baseline": base}
    ranked.sort(reverse=True)
    _, _, winner, ceiling = ranked[0]
    return {"status": "candidate", "profile": winner, "ceiling": ceiling,
            "drift": round(drift, 4), "threshold": round(threshold, 4),
            "baseline": base}


def confirm(records, families, profile):
    base, base_loss, drift = baseline(records, families)
    if drift > 0.20:
        return {"status": "unstable", "drift": round(drift, 4)}
    threshold = max(0.05, drift + 0.03)
    score = score_candidate(records, profile, families, base, base_loss, threshold, True)
    return {"status": "keep" if score is not None else "restore",
            "threshold": round(threshold, 4), "baseline": base,
            "score": round(score, 4) if score is not None else None}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("phase", choices=("choose", "confirm"))
    parser.add_argument("records")
    parser.add_argument("families", help="comma-separated, e.g. 4,6")
    parser.add_argument("profiles", help="comma-separated candidate labels")
    parser.add_argument("ceilings", nargs="?", default="", help="comma-separated ceiling bytes")
    args = parser.parse_args()
    records = load_records(args.records)
    families = args.families.split(",")
    profiles = args.profiles.split(",")
    if args.phase == "choose":
        ceilings = [int(value) for value in args.ceilings.split(",")]
        result = choose(records, families, profiles, ceilings)
    else:
        result = confirm(records, families, profiles[0])
    print(json.dumps(result, separators=(",", ":")))


if __name__ == "__main__":
    main()
