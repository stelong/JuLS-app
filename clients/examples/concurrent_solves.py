# Copyright (c) 2026 Stefano Longobardi
# SPDX-License-Identifier: Apache-2.0
"""Fire many solves concurrently and compare against running them one by one.

    python clients/examples/concurrent.py [BASE_URL]

Sweeps the knapsack solve over several iteration limits and seeds, all in flight
at once via AsyncJuLSClient.solve_many (the server runs them across threads).
"""
import asyncio
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from juls import AsyncJuLSClient, JuLSClient
from juls.samples import SAMPLES

DATA = SAMPLES["knapsack"]
REQUESTS = [
    {"problem": "knapsack", "data": DATA, "solve": {"limit": limit, "seed": seed}}
    for limit in (2000, 4000, 8000)
    for seed in range(4)
]


async def run_concurrent(base_url: str) -> list[dict]:
    async with AsyncJuLSClient(base_url) as client:
        return await client.solve_many(REQUESTS)


def run_sequential(base_url: str) -> list[dict]:
    with JuLSClient(base_url) as client:
        return [client.solve(r["problem"], r["data"], **r["solve"]) for r in REQUESTS]


def main(base_url: str = "http://localhost:8080") -> None:
    t0 = time.perf_counter()
    seq = run_sequential(base_url)
    t_seq = time.perf_counter() - t0

    t0 = time.perf_counter()
    con = asyncio.run(run_concurrent(base_url))
    t_con = time.perf_counter() - t0

    print(f"{len(REQUESTS)} solves")
    print(f"  sequential: {t_seq:6.2f}s")
    print(f"  concurrent: {t_con:6.2f}s   ({t_seq / t_con:.1f}x faster)")
    best = min(r["result"]["objective"] for r in con)
    print(f"  best objective across the sweep: {best}")


if __name__ == "__main__":
    main(*(sys.argv[1:2] or []))
