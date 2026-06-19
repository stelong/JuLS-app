# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
"""Solve every problem synchronously and save a solution + objective-history plot.

    python clients/examples/solve_and_plot.py [BASE_URL]

Requires a running server (default http://localhost:8080) and the deps in
clients/requirements.txt. PNGs are written to clients/examples/out/.
"""
import sys
from pathlib import Path

# Make the sibling `juls` package importable when run as a script
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from juls import JuLSClient, plot_objective, plot_solution, summarize
from juls.samples import SAMPLES

OUT = Path(__file__).resolve().parent / "out"


def main(base_url: str = "http://localhost:8080") -> None:
    OUT.mkdir(exist_ok=True)
    with JuLSClient(base_url) as client:
        print("health:", client.health())
        for problem, data in SAMPLES.items():
            res = client.solve(problem, data, limit="auto", seed=0)
            r = res["result"]
            print(f"\n== {problem} ==  objective={r['objective']}  feasible={r['feasible']}")
            print(summarize(data, res))

            plot_solution(data, res).savefig(OUT / f"{problem}.png", dpi=150, bbox_inches="tight")
            plot_objective(res).savefig(OUT / f"{problem}_objective.png", dpi=150, bbox_inches="tight")
    print(f"\nsaved plots to {OUT}")


if __name__ == "__main__":
    main(*(sys.argv[1:2] or []))
