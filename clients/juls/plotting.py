# Copyright (c) 2026 Stefano Longobardi
# SPDX-License-Identifier: Apache-2.0
"""matplotlib/seaborn renderings of JuLS solutions.

Every function takes the request `data` you sent and the JSON `response` the
server returned, and returns a matplotlib `Figure`. `summarize` returns a polars
`DataFrame` with the per-entity breakdown and is reused by the plots.

    fig = plot_solution(data, response)      # dispatches on response["problem"]
    fig.savefig("solution.png", dpi=150)
    df = summarize(data, response)            # polars DataFrame
"""
from __future__ import annotations

import math
from typing import Any

import matplotlib.pyplot as plt
import numpy as np
import polars as pl
import seaborn as sns

sns.set_theme(style="whitegrid")

_SELECTED = "seagreen"
_UNSELECTED = (0.5, 0.5, 0.5, 0.4)


# ---------------------------------------------------------------------------
# Objective history (problem-agnostic)
# ---------------------------------------------------------------------------
def plot_objective(response: dict, ax: "plt.Axes | None" = None) -> "plt.Figure":
    """Objective value per iteration, with the improving (best) iterations marked."""
    metrics = response["metrics"]
    history = metrics["objective_history"]
    improving = metrics["improving_iterations"]
    iterations = range(1, len(history) + 1)

    fig = ax.figure if ax is not None else plt.figure(figsize=(7, 4))
    ax = ax or fig.add_subplot(111)
    ax.plot(list(iterations), history, color="steelblue", label="objective")
    if improving:
        ax.scatter(improving, [history[i - 1] for i in improving], color="crimson", zorder=5, label="best solutions")
    ax.set(xlabel="iteration", ylabel="objective", title=f"Objective evolution — {response['problem']}")
    ax.legend()
    return fig


# ---------------------------------------------------------------------------
# polars summaries
# ---------------------------------------------------------------------------
def _summarize_knapsack(data: dict, response: dict) -> pl.DataFrame:
    values = list(data["values"])
    weights = list(data["weights"])
    selected = [bool(v) for v in response["result"]["variables"]]
    return pl.DataFrame(
        {
            "item": list(range(1, len(values) + 1)),
            "value": values,
            "weight": weights,
            "selected": selected,
        }
    )


def _summarize_tsp(data: dict, response: dict) -> pl.DataFrame:
    coords = [(float(x), float(y)) for x, y in data["coordinates"]]
    order = [int(i) for i in np.argsort(response["result"]["variables"])]  # 0-indexed tour order
    closed = order + [order[0]]
    legs = [_round_l2(coords[closed[k]], coords[closed[k + 1]]) for k in range(len(order))]
    return pl.DataFrame(
        {
            "step": list(range(1, len(order) + 1)),
            "city": [i + 1 for i in order],
            "x": [coords[i][0] for i in order],
            "y": [coords[i][1] for i in order],
            "leg_to_next": legs,
        }
    )


def _summarize_graph_coloring(data: dict, response: dict) -> pl.DataFrame:
    colors = list(response["result"]["variables"])
    edges = [(int(i), int(j)) for i, j in data["edges"]]
    degree = [sum(1 for i, j in edges if node in (i, j)) for node in range(1, data["n_nodes"] + 1)]
    return pl.DataFrame(
        {
            "node": list(range(1, data["n_nodes"] + 1)),
            "color": colors,
            "degree": degree,
        }
    )


def _summarize_ticket_pricing(data: dict, response: dict) -> pl.DataFrame:
    retailers = data["retailers"]
    price_tiers = list(data["price_tiers"])
    n_ret = len(retailers)
    variables = response["result"]["variables"]
    allocations = variables[:n_ret]
    tiers = variables[n_ret : 2 * n_ret]  # 1-indexed price tier per retailer

    prices = [price_tiers[t - 1] for t in tiers]
    demands = [int(retailers[j]["demands"][tiers[j] - 1]) for j in range(n_ret)]
    sales = [min(allocations[j], demands[j]) for j in range(n_ret)]
    margins = [
        (prices[j] * (1 - retailers[j]["commission"]) - retailers[j]["fixed_fee"]) * sales[j] for j in range(n_ret)
    ]
    return pl.DataFrame(
        {
            "retailer": [r["name"] for r in retailers],
            "allocated": allocations,
            "price": prices,
            "demand": demands,
            "sales": sales,
            "margin": margins,
        }
    )


def _summarize_production_planning(data: dict, response: dict) -> pl.DataFrame:
    ideal = list(data["ideal_loads"])
    load = [int(v) for v in response["result"]["variables"]]
    deviation = [load[i] - ideal[i] for i in range(len(ideal))]
    return pl.DataFrame(
        {
            "plant": list(range(1, len(ideal) + 1)),
            "ideal": ideal,
            "load": load,
            "deviation": deviation,
            "waste": [d * d for d in deviation],
        }
    )


_SUMMARIZERS = {
    "knapsack": _summarize_knapsack,
    "tsp": _summarize_tsp,
    "graph_coloring": _summarize_graph_coloring,
    "ticket_pricing": _summarize_ticket_pricing,
    "production_planning": _summarize_production_planning,
}


def summarize(data: dict, response: dict) -> pl.DataFrame:
    """Per-entity breakdown of a solution as a polars DataFrame."""
    problem = response["problem"]
    if problem not in _SUMMARIZERS:
        raise ValueError(f"no summary for problem '{problem}'")
    return _SUMMARIZERS[problem](data, response)


# ---------------------------------------------------------------------------
# Per-problem figures
# ---------------------------------------------------------------------------
def _round_l2(p: tuple[float, float], q: tuple[float, float]) -> int:
    return round(math.hypot(p[0] - q[0], p[1] - q[1]))


def plot_knapsack(data: dict, response: dict) -> "plt.Figure":
    df = _summarize_knapsack(data, response)
    selected = df["selected"].to_list()
    colors = [_SELECTED if s else _UNSELECTED for s in selected]
    total_value = df.filter(pl.col("selected"))["value"].sum() or 0
    total_weight = df.filter(pl.col("selected"))["weight"].sum() or 0

    fig, (ax_value, ax_weight) = plt.subplots(2, 1, sharex=True, figsize=(8, 6))
    items = df["item"].to_list()
    ax_value.bar(items, df["value"].to_list(), color=colors)
    ax_value.set(ylabel="value", title=f"Knapsack — total value = {total_value}, weight = {total_weight} / {data['capacity']}")
    ax_weight.bar(items, df["weight"].to_list(), color=colors)
    ax_weight.set(xlabel="item", ylabel="weight")
    ax_value.legend(
        [plt.Rectangle((0, 0), 1, 1, color=_SELECTED), plt.Rectangle((0, 0), 1, 1, color=_UNSELECTED)],
        ["selected", "not selected"],
        loc="upper right",
    )
    fig.tight_layout()
    return fig


def plot_tsp(data: dict, response: dict) -> "plt.Figure":
    coords = [(float(x), float(y)) for x, y in data["coordinates"]]
    df = _summarize_tsp(data, response)
    order = [c - 1 for c in df["city"].to_list()]
    closed = order + [order[0]]
    tour_length = int(df["leg_to_next"].sum())
    xs = [coords[i][0] for i in closed]
    ys = [coords[i][1] for i in closed]

    fig, ax = plt.subplots(figsize=(6, 6))
    ax.plot(xs, ys, "-o", color="steelblue", mfc="black", mec="black", markersize=6)
    start = coords[order[0]]
    ax.scatter([start[0]], [start[1]], color="crimson", s=140, zorder=5, label="start city")
    ax.set(xlabel="x", ylabel="y", title=f"TSP tour — {len(coords)} cities, length = {tour_length}")
    ax.set_aspect("equal", "datalim")
    ax.legend()
    return fig


def plot_graph_coloring(data: dict, response: dict) -> "plt.Figure":
    n = data["n_nodes"]
    max_color = data["max_color"]
    edges = [(int(i), int(j)) for i, j in data["edges"]]
    colors = list(response["result"]["variables"])
    n_used = len(set(colors))
    conflicts = [(i, j) for i, j in edges if colors[i - 1] == colors[j - 1]]

    angles = [2 * math.pi * k / n for k in range(n)]
    nx = [math.cos(a) for a in angles]
    ny = [math.sin(a) for a in angles]
    cmap = plt.get_cmap("rainbow")
    palette = [cmap(0.0)] if max_color == 1 else [cmap(t) for t in np.linspace(0, 1, max_color)]

    fig, ax = plt.subplots(figsize=(6, 6))
    for i, j in edges:
        if (i, j) not in conflicts:
            ax.plot([nx[i - 1], nx[j - 1]], [ny[i - 1], ny[j - 1]], color=(0.5, 0.5, 0.5, 0.6), zorder=1)
    labelled = False
    for i, j in conflicts:
        ax.plot(
            [nx[i - 1], nx[j - 1]],
            [ny[i - 1], ny[j - 1]],
            color="red",
            linewidth=3,
            zorder=2,
            label=None if labelled else "conflict",
        )
        labelled = True
    ax.scatter(nx, ny, c=[palette[c - 1] for c in colors], s=600, edgecolors="black", zorder=3)
    for k in range(n):
        ax.text(nx[k], ny[k], str(k + 1), ha="center", va="center", color="white", fontsize=9, zorder=4)
    ax.set_title(f"Graph coloring — {n_used} colors used, {len(conflicts)} conflicts")
    if conflicts:
        ax.legend()
    ax.set_aspect("equal")
    ax.axis("off")
    return fig


def plot_ticket_pricing(data: dict, response: dict) -> "plt.Figure":
    df = _summarize_ticket_pricing(data, response)
    names = df["retailer"].to_list()
    allocated = df["allocated"].to_list()
    demand = df["demand"].to_list()
    sales = df["sales"].to_list()
    prices = df["price"].to_list()
    margins = df["margin"].to_list()
    total_margin = round(float(df["margin"].sum()), 2)
    js = np.arange(len(names))

    fig, (ax_alloc, ax_margin) = plt.subplots(1, 2, figsize=(11, 4.5))
    ax_alloc.bar(js - 0.2, allocated, width=0.35, color="steelblue", label="allocated")
    ax_alloc.bar(js + 0.2, demand, width=0.35, color=(1.0, 0.65, 0.0, 0.8), label="demand at price")
    ax_alloc.scatter(js - 0.2, sales, color="black", marker="_", s=400, zorder=5, label="expected sales")
    for j in js:
        ax_alloc.text(j, max(allocated[j], demand[j]), f"price = {prices[j]:g}", ha="center", va="bottom", fontsize=9)
    ax_alloc.set_xticks(js, names)
    ax_alloc.set(ylabel="tickets", title=f"Allocation & demand — {data['n_tickets']} tickets, total margin = {total_margin}")
    ax_alloc.set_ylim(0, 1.25 * max(max(allocated), max(demand)))
    ax_alloc.legend()

    ax_margin.bar(js, margins, color="seagreen")
    for j in js:
        ax_margin.text(j, margins[j], str(round(margins[j], 1)), ha="center", va="bottom", fontsize=9)
    ax_margin.set_xticks(js, names)
    ax_margin.set(ylabel="margin", title="Margin contribution")
    if max(margins) > 0:
        ax_margin.set_ylim(0, 1.15 * max(margins))
    fig.tight_layout()
    return fig


def plot_production_planning(data: dict, response: dict) -> "plt.Figure":
    df = _summarize_production_planning(data, response)
    plants = df["plant"].to_list()
    ideal = df["ideal"].to_list()
    load = df["load"].to_list()
    total_waste = int(df["waste"].sum())
    used = sum(load)
    js = np.arange(len(plants))

    fig, ax = plt.subplots(figsize=(8, 4.5))
    ax.bar(js - 0.2, ideal, width=0.35, color=(0.5, 0.5, 0.5, 0.7), label="ideal load")
    ax.bar(js + 0.2, load, width=0.35, color="seagreen", label="assigned load")
    for j in js:
        if load[j] != ideal[j]:
            ax.text(j + 0.2, load[j], f"{load[j] - ideal[j]:+d}", ha="center", va="bottom", fontsize=9)
    ax.set_xticks(js, [f"plant {p}" for p in plants])
    ax.set(ylabel="units", title=f"Production planning — waste = {total_waste}, used {used} / {data['capacity']}")
    ax.legend()
    fig.tight_layout()
    return fig


_PLOTTERS = {
    "knapsack": plot_knapsack,
    "tsp": plot_tsp,
    "graph_coloring": plot_graph_coloring,
    "ticket_pricing": plot_ticket_pricing,
    "production_planning": plot_production_planning,
}


def plot_solution(data: dict, response: dict) -> "plt.Figure":
    """Render a solution, dispatching on `response["problem"]`."""
    problem = response["problem"]
    if problem not in _PLOTTERS:
        raise ValueError(f"no plotter for problem '{problem}'")
    return _PLOTTERS[problem](data, response)
