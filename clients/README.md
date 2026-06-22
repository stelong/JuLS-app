# JuLS Python clients

Python client + plotting helpers for the JuLS solve API. The server returns plain
JSON, so these are pure clients — nothing here is needed to run the solver.

## Install

These clients are a [uv](https://docs.astral.sh/uv/) project. You do **not** need a
system Python — uv fetches the pinned interpreter (see `.python-version`) for you.

```bash
# 1. Install uv (macOS/Linux); see the docs for other methods
curl -LsSf https://astral.sh/uv/install.sh | sh

# 2. From the clients/ directory, create the env and install everything
#    (downloads Python 3.12 if missing, then installs the locked deps)
cd clients
uv sync
```

`uv sync` reads `pyproject.toml` + `uv.lock` and creates a `.venv/` with the exact,
reproducible dependency set. To update the lock after editing dependencies, run
`uv lock`.

## Run the server

```bash
docker run --rm -p 8080:8080 steplong/juls-app:latest
# or locally:  julia --project=. --threads=auto server/run.jl
```

## Quick start

Run any Python through the project env with `uv run` — no manual `activate` needed
(it auto-syncs first). From the `clients/` directory:

```bash
uv run python            # REPL with juls importable
uv run examples/solve_and_plot.py
```

```python
from juls import JuLSClient, plot_solution, summarize

with JuLSClient("http://localhost:8080") as client:
    data = {"capacity": 10, "values": [6, 5, 8, 9, 6], "weights": [2, 3, 6, 7, 5]}
    res = client.solve("knapsack", data, limit="auto", seed=0)

print(res["result"]["objective"])
print(summarize(data, res))                 # polars DataFrame
plot_solution(data, res).savefig("knapsack.png", dpi=150)
```

`solve(problem, data, **solve_opts)` — `solve_opts` becomes the request's `solve`
block, e.g. `limit=200`, `limit="auto"`, `limit={"time": 5}`, `using_cp=True`,
`seed=0`. Use `client.problems()` to discover each problem's input schema.

## Ready-made samples

Each problem ships three instances — `easy`, `medium`, `hard` — loaded from the
repo's `data/<problem>/<tier>.json` files. These are the exact same instances the
Julia package loads via `JuLS.load_sample(problem, tier)`, so a sample is identical
whether you drive it from Python or Julia.

```python
from juls import JuLSClient, sample, SAMPLES

data = sample("knapsack", "hard")        # or SAMPLES["knapsack"]["hard"]
with JuLSClient() as client:
    res = client.solve("knapsack", data, limit="auto", seed=0)
```

## Concurrency

The server is multi-threaded, so many solves run in parallel:

```python
import asyncio
from juls import AsyncJuLSClient

async def main():
    async with AsyncJuLSClient() as client:
        results = await client.solve_many([
            {"problem": "knapsack", "data": data, "solve": {"limit": n, "seed": s}}
            for n in (100, 500, 1000) for s in range(3)
        ])

asyncio.run(main())
```

## Plotting

`plot_solution(data, response)` dispatches on the problem and returns a matplotlib
`Figure`. `plot_objective(response)` shows the objective
history with the improving iterations marked. `summarize(data, response)` returns
a polars `DataFrame`.

## Examples

From the `clients/` directory:

```bash
uv run examples/solve_and_plot.py     # solve all problems, save PNGs to examples/out/
uv run examples/concurrent_solves.py  # sequential vs concurrent timing
```
