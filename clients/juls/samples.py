# Copyright (c) 2026 Stefano Longobardi
# SPDX-License-Identifier: Apache-2.0
"""Ready-made example payloads, one per problem, for demos and smoke tests."""

SAMPLES: dict[str, dict] = {
    "knapsack": {
        "capacity": 50,
        "values": [6, 5, 8, 9, 6, 7, 3, 4, 8, 2, 9, 5],
        "weights": [2, 3, 6, 7, 5, 4, 1, 2, 6, 3, 8, 4],
    },
    "tsp": {
        "coordinates": [
            [0, 0], [1, 5], [5, 2], [6, 6], [8, 3],
            [2, 8], [7, 9], [3, 3], [9, 1], [4, 7],
        ],
    },
    "graph_coloring": {
        "n_nodes": 6,
        "edges": [[1, 2], [2, 3], [3, 4], [4, 5], [5, 6], [6, 1], [1, 4], [2, 5], [3, 6]],
        "max_color": 3,
    },
    "ticket_pricing": {
        "n_tickets": 20,
        "price_tiers": [50, 75, 100],
        "retailers": [
            {"name": "Alpha", "commission": 0.10, "fixed_fee": 5, "demands": [12, 8, 4]},
            {"name": "Bravo", "commission": 0.15, "fixed_fee": 3, "demands": [10, 7, 3]},
            {"name": "Charlie", "commission": 0.08, "fixed_fee": 6, "demands": [9, 6, 5]},
        ],
    },
    "production_planning": {
        "capacity": 20,
        "ideal_loads": [8, 6, 7, 5],
    },
}
