# JuLS-app

A containerised REST API for the **JuLS** local-search solver: send an optimization problem as JSON over HTTP, get the solution back as JSON. One image, many problems, data-in / solution-out — runnable on your laptop, in Docker, or in a cluster.

> **Fork notice.** JuLS-app is a fork of [JuLS](https://github.com/amazon-science/JuLS) (Amazon Science), distributed under the Apache License 2.0. The core solver is unchanged; this fork adds a REST API, a container build, and Python clients. For the solver's theory and the accompanying paper, see the [upstream repository](https://github.com/amazon-science/JuLS) and its [paper](https://github.com/amazon-science/JuLS/blob/main/JuLS.pdf). See [`NOTICE`](NOTICE) and [`LICENSE`](LICENSE).

JuLS combines Constraint-Based Local Search (CBLS) and Constraint Programming (CP) to solve Constraint Optimization Problems. Solving is fast and stateless, so the API is a single synchronous endpoint and scales horizontally.

---

## Quick start

Pull and run the image (no build required):

```bash
docker run --rm --pull=always -p 8080:8080 steplong/juls-app:latest
```

`latest` is a moving tag and Docker/colima won't re-fetch it on its own, so an already-cached `latest` can be stale (e.g. missing newer endpoints). Use `--pull=always` as above, or run `docker pull steplong/juls-app:latest` first. For a reproducible run, pin an immutable commit tag instead — every push publishes `steplong/juls-app:sha-<short-commit>` (and `vX.Y.Z` for releases):

```bash
docker run --rm -p 8080:8080 steplong/juls-app:sha-f4c4bf1
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

Built-in problems: `knapsack`, `tsp`, `graph_coloring`, `ticket_pricing`, `production_planning`.

> **No API key needed by default.** Auth and the concurrency cap are opt-in (see [Configuration](#configuration)) — out of the box the server is open, so the calls above work as-is for local trials. Set `JULS_API_KEY` only when you want to lock it down.

---

## HTTP API

| Method | Path        | Description |
|--------|-------------|-------------|
| `GET`  | `/health`   | Liveness probe; returns `ok` and the registered problem names. |
| `GET`  | `/ready`    | Readiness probe; `200` once warmup is complete, `503` while starting. |
| `GET`  | `/problems` | Input schema (fields, types, required flags) for every problem. |
| `GET`  | `/metrics`  | Prometheus metrics (request counts, latency histogram, in-flight gauge). |
| `POST` | `/solve`    | Solve a problem synchronously; returns the solution as JSON. |
| `POST` | `/jobs`     | Submit a solve asynchronously; returns a job id (`202`). |
| `GET`  | `/jobs/{id}`| Poll an async job's status and result. |

**Which one?** `/solve` blocks until the solve finishes and returns the result on the same response — best for quick solves (you can still fire many *concurrently* from the client; see [Concurrency](clients/README.md)). `/jobs` returns immediately and you poll for the result — use it for long or variable-duration solves that would otherwise hold a connection open (and trip HTTP/load-balancer timeouts). Same solver underneath; only the delivery differs.

**Request body** for `POST /solve`:

```jsonc
{
  "problem": "knapsack",          // a registered problem name
  "data":    { ... },             // problem-specific fields (see GET /problems)
  "id":      "my-run-1",          // optional correlation id: echoed back + logged for tracing
  "solve":   {                    // optional
    "limit":    200,              // int (iterations) | "auto" | {"time": 5} | {"stagnation": 20, "max_iterations": 1000}
    "using_cp": true,             // filter moves with CP (default true)
    "seed":     0                 // optional RNG seed for reproducibility
  }
}
```

The optional `id` is a **correlation label**, not a handle you need to fetch results:
`/solve` is synchronous, so the response you get back *is* your result. The `id` is
echoed unchanged and included in the server's structured logs, which is handy for
tracing a specific run. If you omit it, the server generates a UUID. (For the async
`/jobs` flow below, this same field instead becomes the `job_id` you poll with.)

**Response** (abridged):

```jsonc
{
  "id": "my-run-1",               // your id echoed back (or a generated UUID)
  "problem": "knapsack", "status": "feasible",
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

### Async jobs

For long or variable-duration solves, submit asynchronously instead of blocking on `/solve`. The request body is identical to `/solve` and is validated up front (so bad input still fails fast with `400`/`413`); the call returns immediately with a job id you poll. Here the optional `id` field **becomes the `job_id`** (supply your own as an idempotency key, or the server generates a UUID) — unlike `/solve`, where `id` is just a correlation label.

```bash
# submit -> 202
curl -X POST http://localhost:8080/jobs \
  -H 'Content-Type: application/json' \
  -d '{"problem": "tsp", "data": {...}, "solve": {"limit": {"time": 30}}}'
# {"job_id": "0f9c…", "status": "queued", "poll": "/jobs/0f9c…"}

# poll -> 200 (status is queued | running | succeeded | failed | timed_out)
curl http://localhost:8080/jobs/0f9c…
```

Once `status` is `succeeded` (or `timed_out`, which keeps the best solution found), the response carries the same `result` object as `/solve`; `failed` carries an `{"error": …}`. Unknown ids return `404`.

The job runs through the exact same solver path as `/solve` (including the wall-clock budget). Today the queue and worker run inside the container (all-in-one), but they sit behind small `JobQueue`/`JobStore` interfaces ([`server/jobs.jl`](server/jobs.jl)) so the backend can move to a managed queue + store (e.g. SQS with DynamoDB/S3) and a separate worker pool without changing the API.

---

## Python clients

[`clients/`](clients/) provides a Python client (sync + async, with concurrent batch solving) and matplotlib plotting from the JSON response. Managed with [uv](https://docs.astral.sh/uv/). See [`clients/README.md`](clients/README.md).

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

### Worked example: a constrained quadratic

[`production_planning`](src/experiments/production_planning/production_planning.jl) is a deliberately small problem added with exactly the recipe above — a good single-file template to copy.

**The problem.** A fixed production quota must be split across a few plants without exceeding a shared `capacity`. Each plant must stay open (produce at least one unit), and running a plant away from its ideal load wastes money that grows *quadratically* with the gap. Minimise the total waste:

```
minimise  ∑ (load_i − ideal_i)²            ← a paraboloid (sum of squares)
s.t.      ∑ load_i ≤ capacity              ← shared budget (the binding constraint)
          1 ≤ load_i ≤ capacity            ← each plant stays open (positivity)
```

When the ideal loads together ask for more than the capacity, the solver has to find the best feasible compromise — pulling some plants below their sweet spot to fit the budget.

**The interface.** Loads are integers, one decision variable per plant, and "produce at least one unit" is baked straight into the domain (`1..capacity`), so positivity needs no constraint:

```julia
n_decision_variables(e::ProductionPlanningExperiment) = e.n_plants
decision_type(::ProductionPlanningExperiment) = IntDecisionValue
generate_domains(e::ProductionPlanningExperiment) = [collect(1:e.capacity) for _ = 1:e.n_plants]
(::SimpleInitialization)(e::ProductionPlanningExperiment) = fill(1, e.n_plants)  # start feasible
```

**The DAG.** The objective maps each load to its squared deviation with an `ElementInvariant` (a precomputed value→cost table — the trick that lets you express a non-linear per-variable cost without writing a custom invariant), turns it into a scalar with a unit `ScaleInvariant`, and sums those with an `ObjectiveInvariant`. The constraint sums the loads, compares them against `capacity` with a `ComparatorInvariant`, and penalises any overflow via a `StaticConstraintInvariant`. An `AggregatorInvariant` combines the two:

```julia
for i = 1:e.n_plants
    squared_deviation = [IntDecisionValue((load - e.ideal_loads[i])^2) for load = 1:e.capacity]
    deviation_node = add_invariant!(dag, ElementInvariant(i, squared_deviation); variable_parent_indexes = [i])
    push!(cost_nodes, add_invariant!(dag, ScaleInvariant(1.0); invariant_parent_indexes = [deviation_node]))
end
objective_node = add_invariant!(dag, ObjectiveInvariant(); invariant_parent_indexes = cost_nodes)
# ... ComparatorInvariant(capacity) over the loads → StaticConstraintInvariant(α) → AggregatorInvariant
```

**Solve it over HTTP** — ideals sum to 18 but only 10 units of capacity, so the budget binds:

```bash
curl -X POST http://localhost:8080/solve \
  -H 'Content-Type: application/json' \
  -d '{"problem": "production_planning", "data": {"capacity": 10, "ideal_loads": [6, 5, 7]}}'
# → loads like [3, 2, 5] (sum 10), objective 22.0 — the minimal achievable waste
```

---

## Build your own image

After registering your problem, build and run a custom image:

```bash
docker build -t <your-user>/juls-app .
docker run --rm -p 8080:8080 <your-user>/juls-app
```

The [`Dockerfile`](Dockerfile) is multi-stage: instantiate + precompile → build a PackageCompiler **sysimage** (so there's no first-request JIT latency) → slim runtime. On startup the server runs a warmup solve per problem before accepting traffic, then serves requests across threads.

### Configuration

All runtime settings are environment variables (with their defaults below). Pass them to `docker run` with `-e NAME=value`, or an `--env-file`:

| Variable | Default | Effect |
| --- | --- | --- |
| `HOST` | `0.0.0.0` | Bind address. |
| `PORT` | `8080` | Listen port — must match your `-p` mapping. |
| `PARALLEL` | `true` | Multi-threaded serve. |
| `WARMUP` | `true` | Warm the solver before serving (`/ready` stays `503` until done). |
| `JULIA_NUM_THREADS` | `auto` | Thread pool; also the basis for the two `*_CONCURRENCY` defaults. |
| `JULS_MAX_BODY_BYTES` | `1000000` | Largest accepted request body; over → `413`. |
| `JULS_MAX_ITERATIONS` | `100000` | Iteration-budget cap; over → `400`. |
| `JULS_MAX_SOLVE_SECONDS` | `60.0` | Wall-clock ceiling. On hit, returns `200` with best-so-far and `metrics.time_budget_exceeded = true` (enforced cooperatively inside the solver loop, so it never abandons work). |
| `JULS_API_KEY` | _(unset)_ | When set, `/solve` and `/jobs` require it via `X-API-Key: <key>` or `Authorization: Bearer <key>` (else `401`). Probes/metrics (`/health`, `/ready`, `/metrics`, `/problems`) stay open. |
| `JULS_MAX_CONCURRENT` | `4 × threads` | Max concurrent `/solve`; excess → `429` with `Retry-After` (the Python client auto-retries). `0` disables the cap. |
| `JULS_RUN_WORKER` | `true` | Run the in-process async-job workers (all-in-one). Set `false` on the API in a split API/worker deployment. |
| `JULS_WORKER_CONCURRENCY` | `threads` | Number of worker tasks draining the `/jobs` queue. |

```bash
docker run --rm --pull=always -p 8080:8080 \
  -e JULS_API_KEY=s3cret \
  -e JULS_MAX_CONCURRENT=16 \
  -e JULS_MAX_SOLVE_SECONDS=120 \
  steplong/juls-app:latest

# ...or from a file (NAME=value per line, no quotes, no `export`):
docker run --rm -p 8080:8080 --env-file juls.env steplong/juls-app:latest
```

Two gotchas:
- **`PORT` must match `-p`.** `-p` is `host:container`; if you set `-e PORT=9000`, publish `-p 9000:9000`. Colima forwards published ports to your host just like Docker Desktop.
- **Threads drive the concurrency defaults.** `JULS_MAX_CONCURRENT` and `JULS_WORKER_CONCURRENCY` derive from `JULIA_NUM_THREADS`, so on a small colima VM the cap can be low (e.g. 2 threads → cap 8). Set them explicitly for a predictable cap.

The startup log echoes the effective `auth`, `max_concurrent`, and worker count.

**Observability.** Every `/solve` request emits one structured JSON log line to stdout (`id`, `problem`, `outcome`, `status`, `duration_seconds`, and solve fields) for log pipelines to parse, and updates the Prometheus metrics at `GET /metrics`:

- `juls_requests_total{problem,outcome}` — request counter (outcome ∈ `success`, `infeasible`, `time_budget_exceeded`, `invalid_request`, `payload_too_large`, `error`)
- `juls_request_duration_seconds` — latency histogram
- `juls_solves_in_flight` — gauge of in-progress solves

```bash
curl http://localhost:8080/metrics
```

Pushing to `main` (or tagging `v*`) triggers [`.github/workflows/docker.yml`](.github/workflows/docker.yml), which builds and pushes the image to Docker Hub.

---

## Local Julia use

You can also drive the solver directly from Julia (no HTTP):

```bash
julia --threads=auto --project=.
```

```julia
using JuLS

# Each problem ships easy/medium/hard sample instances under data/<problem>/<tier>.json
# (the same payloads the Python client exposes via juls.samples):
experiment = load_sample("knapsack", "hard")     # or build_experiment("knapsack", data)
model = init_model(experiment; using_cp = true)
optimize!(model; limit = IterationLimit(100))   # or limit = 100, TimeLimit(10), :auto, StagnationLimit(20)
println(model.best_solution.objective)
```

The solver internals live under [`src/`](src/): the local-search [`model`](src/model/model.jl), the [`dag`](src/dag/dag.jl) of invariants, the [`cp`](src/cp/cp.jl) filter, the [`heuristics`](src/heuristics/heuristics.jl), and the [`experiments`](src/experiments/experiments.jl).

---

## License

Apache License 2.0 — see [`LICENSE`](LICENSE), [`NOTICE`](NOTICE), and [`THIRD-PARTY-LICENSES.txt`](THIRD-PARTY-LICENSES.txt). A fork of [amazon-science/JuLS](https://github.com/amazon-science/JuLS).
