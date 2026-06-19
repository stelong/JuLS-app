# JuLS Python clients

Python client + plotting helpers for the JuLS solve API. The server returns plain
JSON, so these are pure clients — nothing here is needed to run the solver.

## Install

```bash
pip install -r clients/requirements/requirements.txt
```

## Run the server

```bash
docker run --rm -p 8080:8080 steplong/juls-app:latest
# or locally:  julia --project=. --threads=auto server/run.jl
```

## Quick start

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
`Figure` (matplotlib + seaborn). `plot_objective(response)` shows the objective
history with the improving iterations marked. `summarize(data, response)` returns
a polars `DataFrame`.

## Examples

```bash
python clients/examples/solve_and_plot.py   # solve all 4 problems, save PNGs to out/
python clients/examples/concurrent_solves.py # sequential vs concurrent timing
```
