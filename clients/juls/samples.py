# Copyright (c) 2026 Stefano Longobardi
# SPDX-License-Identifier: Apache-2.0
"""Ready-made example payloads — easy/medium/hard per problem — for demos and tests.

These are loaded straight from the repo's `data/<problem>/<tier>.json` files, the
same instances the Julia package loads via `JuLS.load_sample(problem, tier)`, so a
sample is identical whether you drive it from Python or Julia.

    from juls import JuLSClient, sample, SAMPLES

    data = sample("knapsack", "hard")     # or SAMPLES["knapsack"]["hard"]
    with JuLSClient() as client:
        res = client.solve("knapsack", data)
"""
from __future__ import annotations

import json
from pathlib import Path

# clients/juls/samples.py -> repo root is parents[2]; data/ lives there.
_DATA_DIR = Path(__file__).resolve().parents[2] / "data"

TIERS = ("easy", "medium", "hard")


def _load() -> dict[str, dict[str, dict]]:
    out: dict[str, dict[str, dict]] = {}
    for problem_dir in sorted(p for p in _DATA_DIR.iterdir() if p.is_dir()):
        tiers = {
            tier: json.loads(f.read_text())
            for tier in TIERS
            if (f := problem_dir / f"{tier}.json").is_file()
        }
        if tiers:
            out[problem_dir.name] = tiers
    return out


#: ``SAMPLES[problem][tier]`` -> the ``data`` payload for that instance.
SAMPLES: dict[str, dict[str, dict]] = _load()


def sample(problem: str, tier: str = "easy") -> dict:
    """Return the data payload for `problem` at difficulty `tier` (easy|medium|hard)."""
    if problem not in SAMPLES:
        available = ", ".join(SAMPLES) or "(none)"
        raise KeyError(f"unknown problem '{problem}'; available: {available}")
    if tier not in SAMPLES[problem]:
        raise KeyError(
            f"no '{tier}' sample for '{problem}'; available tiers: {', '.join(SAMPLES[problem])}"
        )
    return SAMPLES[problem][tier]
