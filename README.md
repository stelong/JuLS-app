# JuLS-app

A containerised REST API for the **JuLS** local-search solver: send an optimization problem as JSON over HTTP, get the solution back as JSON. One image, many problems, data-in / solution-out — runnable on your laptop, in Docker, or in a cluster.

> **Fork notice.** JuLS-app is a fork of [JuLS](https://github.com/amazon-science/JuLS) (Amazon Science), distributed under the Apache License 2.0. The core solver is unchanged; this fork adds a REST API, a container build, and Python clients. For the solver's theory and the accompanying paper, see the [upstream repository](https://github.com/amazon-science/JuLS) and its [paper](https://github.com/amazon-science/JuLS/blob/main/JuLS.pdf). See [`NOTICE`](NOTICE) and [`LICENSE`](LICENSE).

JuLS combines Constraint-Based Local Search (CBLS) and Constraint Programming (CP) to solve Constraint Optimization Problems. Solving is fast and stateless, so the API is a single synchronous endpoint and scales horizontally.

---

## Quick start

Pull and run the image (no build required):

```bash
docker run --rm -p 8080:8080 steplong/juls-app:latest
```

Then talk to it:

```bash
# liveness + registered problems
curl http://localhost:8080/health

# input schema for every problem
curl http://localhost:8080/problems

# solve a knapsack instance
curl -X POST http://localhost:8080/solve \
  -H 'Content-Type: application/json' \
  -d '{
        "problem": "knapsack",
        "data": {"capacity": 10, "values": [6,5,8,9,6], "weights": [2,3,6,7,5]},
        "solve": {"limit": 200, "seed": 0}
      }'
```

Built-in problems: `knapsack`, `tsp`, `graph_coloring`, `ticket_pricing`.

---

## HTTP API

| Method | Path        | Description |
|--------|-------------|-------------|
| `GET`  | `/health`   | Liveness probe; returns `ok` and the registered problem names. |
| `GET`  | `/problems` | Input schema (fields, types, required flags) for every problem. |
| `POST` | `/solve`    | Solve a problem synchronously; returns the solution as JSON. |

**Request body** for `POST /solve`:

```jsonc
{
  "problem": "knapsack",          // a registered problem name
  "data":    { ... },             // problem-specific fields (see GET /problems)
  "solve":   {                    // optional
    "limit":    200,              // int (iterations) | "auto" | {"time": 5} | {"stagnation": 20, "max_iterations": 1000}
    "using_cp": true,             // filter moves with CP (default true)
    "seed":     0                 // optional RNG seed for reproducibility
  }
}
```

**Response** (abridged):

```jsonc
{
  "id": "…", "problem": "knapsack", "status": "feasible",
  "solve":  { "limit": {"type": "iterations", "value": 200}, "using_cp": true, "seed": 0 },
  "result": {
    "objective": -15.0, "feasible": true,
    "variables": [true, false, false, true, false],
    "n_decision_variables": 5, "decision_type": "BinaryDecisionValue",
    "objective_sense": "minimize"
  },
  "metrics": {
    "iterations": 200, "solve_time_seconds": 0.01, "initial_objective": -11.0,
    "objective_history": [ … ], "feasible_history": [ … ],
    "iteration_time_seconds": [ … ], "improving_iterations": [1, 2, 6, 11]
  }
}
```

The objective is always **minimized** (e.g. knapsack returns `-15.0` for a maximized value of 15). Invalid input returns HTTP `400` with an `{"error": …}` message.

---

## Python clients

[`clients/`](clients/) provides a Python client (sync + async, with concurrent batch solving) and matplotlib/seaborn plotting from the JSON response. See [`clients/README.md`](clients/README.md).

```python
from juls import JuLSClient, plot_solution

with JuLSClient("http://localhost:8080") as client:
    data = {"capacity": 10, "values": [6, 5, 8, 9, 6], "weights": [2, 3, 6, 7, 5]}
    res = client.solve("knapsack", data, limit="auto", seed=0)
plot_solution(data, res).savefig("knapsack.png", dpi=150)
```

---

## Register a new optimization problem

A problem is a Julia `Experiment` type plus a data-loading contract, registered by name. To add one (use the existing experiments under [`src/experiments/`](src/experiments/) as templates):

1. **Define the experiment** and the core interface — `n_decision_variables`, `decision_type`, `generate_domains`, and `create_dag` (the DAG of invariants encoding objective + constraints). Optionally provide custom `init` / `neigh` / `pick` heuristics; defaults are used otherwise. See [`src/experiments/experiments.jl`](src/experiments/experiments.jl).

2. **Add the data-loading contract** so the problem is reachable over HTTP — implement
   ```julia
   from_data(::Type{YourExperiment}, data::AbstractDict)   # validate payload -> build instance
   data_schema(::Type{YourExperiment})                     # Vector{FieldSpec} describing the input
   ```
   using the coercion helpers (`as_integer`, `as_number`, `as_integer_array`, `as_coordinate_array`, `as_edge_array`, …) in [`src/experiments/data_loading.jl`](src/experiments/data_loading.jl). They validate input and raise `InvalidInputError` (→ HTTP 400) with actionable messages.

3. **Register it** by adding one entry to `EXPERIMENT_REGISTRY` in [`src/experiments/experiments.jl`](src/experiments/experiments.jl):
   ```julia
   "your_problem" => YourExperiment,
   ```

That's it — `GET /problems` now advertises its schema and `POST /solve` accepts `"problem": "your_problem"`.

---

## Build your own image

After registering your problem, build and run a custom image:

```bash
docker build -t <your-user>/juls-app .
docker run --rm -p 8080:8080 <your-user>/juls-app
```

The [`Dockerfile`](Dockerfile) is multi-stage: instantiate + precompile → build a PackageCompiler **sysimage** (so there's no first-request JIT latency) → slim runtime. On startup the server runs a warmup solve per problem before accepting traffic, and serves requests across threads (`JULIA_NUM_THREADS=auto`). Runtime is configurable via `HOST`, `PORT`, `PARALLEL`, `WARMUP`.

Pushing to `main` (or tagging `v*`) triggers [`.github/workflows/docker.yml`](.github/workflows/docker.yml), which builds and pushes the image to Docker Hub.

---

## Local Julia use

You can also drive the solver directly from Julia (no HTTP):

```bash
julia --threads=auto --project=.
```

```julia
using JuLS

experiment = KnapsackExperiment(joinpath(JuLS.PROJECT_ROOT, "data", "knapsack", "ks_4_0"))
model = init_model(experiment; using_cp = true)
optimize!(model; limit = IterationLimit(100))   # or limit = 100, TimeLimit(10), :auto, StagnationLimit(20)
println(model.best_solution.objective)
```

The solver internals live under [`src/`](src/): the local-search [`model`](src/model/model.jl), the [`dag`](src/dag/dag.jl) of invariants, the [`cp`](src/cp/cp.jl) filter, the [`heuristics`](src/heuristics/heuristics.jl), and the [`experiments`](src/experiments/experiments.jl).

---

## License

Apache License 2.0 — see [`LICENSE`](LICENSE), [`NOTICE`](NOTICE), and [`THIRD-PARTY-LICENSES.txt`](THIRD-PARTY-LICENSES.txt). A fork of [amazon-science/JuLS](https://github.com/amazon-science/JuLS).
