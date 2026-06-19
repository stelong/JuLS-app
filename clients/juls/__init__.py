# Copyright (c) 2026 Stefano Longobardi
# SPDX-License-Identifier: Apache-2.0
"""Python client and plotting helpers for the JuLS solve API.

    from juls import JuLSClient, plot_solution

    with JuLSClient("http://localhost:8080") as client:
        res = client.solve("knapsack", {"capacity": 10, "values": [...], "weights": [...]})
    plot_solution({"capacity": 10, ...}, res).savefig("knapsack.png")
"""
from .client import AsyncJuLSClient, JuLSClient, JuLSError
from .plotting import plot_objective, plot_solution, summarize

__all__ = [
    "JuLSClient",
    "AsyncJuLSClient",
    "JuLSError",
    "plot_solution",
    "plot_objective",
    "summarize",
]
