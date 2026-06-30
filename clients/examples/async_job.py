# Copyright (c) 2026 Stefano Longobardi
# SPDX-License-Identifier: Apache-2.0
"""Submit a solve asynchronously and poll it to completion.

    uv run examples/async_job.py [BASE_URL]   # from the clients/ directory

Demonstrates the job API: `submit_job` returns immediately with an id, `job` reports
status while the worker runs it, and `solve_async` wraps submit-then-poll into one
call. Set JULS_API_KEY on the server and pass api_key=... to authenticate.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from juls import JuLSClient, TERMINAL_STATES, sample


def main(base_url: str = "http://localhost:8080") -> None:
    with JuLSClient(base_url) as client:
        # Manual submit + poll, so you can watch the state transition.
        submitted = client.submit_job("tsp", sample("tsp", "hard"), limit="auto", seed=0)
        job_id = submitted["job_id"]
        print(f"submitted job {job_id} -> {submitted['status']}")

        while True:
            job = client.job(job_id)
            if job["status"] in TERMINAL_STATES:
                break
            time.sleep(0.2)

        print(f"finished -> {job['status']}")
        if "result" in job:
            print(f"  objective: {job['result']['result']['objective']}")

        # The same thing in one call.
        done = client.solve_async("knapsack", sample("knapsack", "hard"), limit="auto", seed=0)
        print(f"solve_async knapsack -> {done['status']}, objective {done['result']['result']['objective']}")


if __name__ == "__main__":
    main(*(sys.argv[1:2] or []))
