---
name: juls-opt-problem-builder
description: >-
  Guide a user to translate a new constrained optimization problem into JuLS's
  constraint-based local search (CBLS) invariant-DAG building blocks, register it
  as an experiment, add a sample and test, build the solver image, and verify it
  from Python — explaining the "why" behind each modeling choice. Use when someone
  wants to solve a custom constrained optimization / assignment / scheduling /
  packing / routing problem with the JuLS-app solver.
license: Apache-2.0
metadata:
  homepage: https://github.com/stelong/JuLS-app
---

# JuLS optimization problem builder

This skill walks a user, step by step, through adding a **new constrained
optimization problem** to the JuLS-app solver. The hard part is mathematical:
translating an objective and a set of constraints into JuLS's **incremental
invariant DAG** (the CBLS building blocks). Your job is to make that translation
correct *and* to teach it — at every step, explain **what** you are doing and
**why** it is done that way.

Work from inside a clone of the JuLS-app repository. If the user hasn't cloned it,
help them do that first (`git clone https://github.com/stelong/JuLS-app`).

## Start here — kick off the intake (do this first)

**The moment this skill activates, your first reply must tell the user what to
provide — never respond with nothing or jump straight into theory.** If the user
hasn't already described a problem, open with a short intake that asks for:

1. **What you're optimizing** — one or two plain sentences.
2. **Decision variables** and their **domain** — binary on/off? an integer
   level/amount (1..K)? one category per item (e.g. a color/machine)?
3. **Constraints** — every limit or rule, written as an (in)equality where possible.
4. **Objective** — the quantity to optimize, and whether to **minimize or maximize**.
5. **A small example instance** — concrete numbers we can use as the first test.

Show one filled-in example so they know the level of detail expected, e.g.:

> *"Assign N shifts to workers. Variable: `xᵢ` = worker for shift i, domain 1..W.
> Constraint: each worker does ≤ 5 shifts/week. Objective: minimize total overtime
> cost. Example: 6 shifts, 3 workers, cost table […]."*

Keep it brief and friendly. **Do not begin modeling until you have at least the
decision-variable structure, the constraints, and the objective (with its sense).**
If the user already gave a problem when invoking the skill, skip the ask and go
straight to the workflow, echoing back your understanding of the five points above.

## How JuLS models a problem (read this before modeling)

JuLS solves by **local search over an incremental DAG of invariants**. Decision
variables sit at the roots; each *invariant* is a node that recomputes a value
from its parents. When local search flips one variable, only the affected part of
the DAG is re-evaluated — that incrementality is the whole point, and it dictates
how you decompose the math. Two ideas drive every model:

1. **Everything is minimized.** A maximization objective is expressed as its
   negative (e.g. knapsack scales values by `-value`). Say this to the user.
2. **Constraints are soft, via penalties.** A constraint becomes a
   `ComparatorInvariant` (measures violation) → `StaticConstraintInvariant(α)`
   (multiplies violation by a penalty `α`), which is added to the objective by a
   final `AggregatorInvariant`. Feasibility = zero total violation.

Details of each node type are in [`reference/invariant-catalog.md`](reference/invariant-catalog.md).
The math-construct → building-block lookup table is in
[`reference/modeling-patterns.md`](reference/modeling-patterns.md) — consult it for
each constraint and objective term.

## Workflow

Do these in order. Keep the user in the loop and **explain the reasoning** at each
step rather than just producing code.

### 1. Elicit the math
Extract, and write back to the user in plain notation:
- **Decision variables** and their **domain** (binary? integer range? a category
  per element?). This fixes `decision_type` (`BinaryDecisionValue` or
  `IntDecisionValue`) and `generate_domains`.
- **Constraints** (each as an inequality/equality over the variables).
- **Objective** and its **sense** (min or max — remember JuLS minimizes).
Explain: the shape of the decision variables is the single most important choice;
it determines the neighbourhood the solver explores.

### 2. Classify and anchor to a built-in
Match the problem to the closest existing experiment and use it as a worked
example the user can read:
- binary selection under a capacity → `knapsack`
- integer level per element, quadratic deviation objective → `production_planning`
- one category per node, conflict constraints → `graph_coloring`
- permutation / routing → `tsp`
Point the user at that experiment's files under `src/experiments/<name>/`.

### 3. Map each term to the DAG
For every constraint and objective term, pick invariants from
[`reference/modeling-patterns.md`](reference/modeling-patterns.md) and **explain why
that decomposition keeps moves incrementally evaluable**. Sketch the DAG in words:
roots (variables) → per-element invariants → aggregators → objective + penalties →
final aggregator. Confirm the sketch with the user before writing code.

### 4. Generate the experiment code
Create `src/experiments/<problem>/<problem>.jl` from
[`templates/experiment.jl.tmpl`](templates/experiment.jl.tmpl) and the DAG builder
from [`templates/model_dag.jl.tmpl`](templates/model_dag.jl.tmpl). Fill in:
- the `Experiment` struct fields, `from_data` (use the coercion helpers:
  `as_integer`, `as_number`, `as_integer_array`, `as_number_array`,
  `as_coordinate_array`, `as_edge_array`), and `data_schema`;
- `n_decision_variables`, `decision_type`, `generate_domains`, a
  `SimpleInitialization`, and `create_dag`.
Wire the file into the build by adding an `include` and a registry entry — see
[`reference/registration-checklist.md`](reference/registration-checklist.md).

### 5. Add a sample and a test
Write a small valid instance to `data/<problem>/easy.json` (and optionally
`medium`/`hard`). Add a `@testitem` from [`templates/testitem.jl.tmpl`](templates/testitem.jl.tmpl)
that loads the sample via `JuLS.load_sample("<problem>", "easy")`, builds the model,
and runs a few iterations. Run `julia --project=. -e 'using Pkg; Pkg.test()'`.

### 6. Build the image and verify from Python
Run [`scripts/smoke_test.sh`](scripts/smoke_test.sh) `<problem>` — it builds the
Docker image, starts it, and checks `GET /problems` lists the new problem, then
`POST /solve`s the sample.

Then generate the **Python verification helper** from
[`templates/verify_problem.py.tmpl`](templates/verify_problem.py.tmpl): substitute
`{{PROBLEM}}` (the problem name) and `{{SAMPLE_JSON}}` (a small instance as a Python
dict) and write it to `clients/examples/verify_<problem>.py`. Then, from `clients/`:

```bash
uv run examples/verify_<problem>.py            # against a running image on :8080
```

This confirms end to end that the freshly built image exposes and solves the new
problem, and leaves the user a reusable `verify(...)` function.

## Guardrails
- **Keep the Docker image lean.** Only `src/` and `server/` ship in the image
  (`.dockerignore` excludes `data/`, `clients/`, `test/`). Don't add heavy deps.
- **Validate input in `from_data`** — throw `InvalidInputError` with an actionable
  message for missing/mismatched fields (the server maps it to HTTP 400).
- **Minimize.** Negate maximization objectives; never invert feasibility.
- Always add a `@testitem` and a `data/<problem>/*.json` sample so the problem is
  covered and reproducible.
