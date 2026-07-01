# Registration checklist

Everything needed to expose a new problem `<problem>` end to end. Verify each item.

## 1. Experiment source
Create `src/experiments/<problem>/<problem>.jl` (optionally split the DAG builder,
init, and neighbourhood into `<problem>_dag.jl`, `<problem>_init.jl`,
`<problem>_neigh.jl`, as the built-ins do). It must define:

- [ ] `struct <Problem>Experiment <: Experiment` with the instance fields.
- [ ] `from_data(::Type{<Problem>Experiment}, data::AbstractDict)` — parse with the
      coercion helpers and `throw(InvalidInputError(...))` on bad input.
- [ ] `data_schema(::Type{<Problem>Experiment})` — a `Vector{FieldSpec}` documenting
      every field (drives `GET /problems`).
- [ ] `n_decision_variables(e)` and `decision_type(e)`.
- [ ] `generate_domains(e)` returning `Vector{Vector{T}}` where `T` is the raw type
      wrapped by `decision_type` (`Bool` for `BinaryDecisionValue`, `Int` for
      `IntDecisionValue`).
- [ ] `(::SimpleInitialization)(e::<Problem>Experiment)` returning a starting
      solution vector (raw values). Optionally a `GreedyInitialization` too.
- [ ] `create_dag(e)` returning the invariant DAG (see `invariant-catalog.md`).
- [ ] Optional heuristic overrides: `default_init`, `default_neigh`, `default_pick`,
      `default_using_cp` (defaults live in `src/experiments/experiments.jl`).

## 2. Wire it into the package
In `src/experiments/experiments.jl`:

- [ ] Add `include("<problem>/<problem>.jl")` next to the other experiment includes.
- [ ] Add the registry entry:
      ```julia
      const EXPERIMENT_REGISTRY = Dict{String,DataType}(
          ...,
          "<problem>" => <Problem>Experiment,
      )
      ```
`available_problems()`, `experiment_type`, and `build_experiment` pick it up
automatically, so `/problems` and `/solve` expose it with no server changes.

## 3. Sample + test
- [ ] `data/<problem>/easy.json` — a small valid instance (just the `data` payload).
      Optionally `medium.json` / `hard.json`. These are shared with the Python
      client (`juls.samples`) and Julia (`JuLS.load_sample`).
- [ ] A `@testitem` (see `templates/testitem.jl.tmpl`) that loads the sample and
      solves a few iterations. Run `julia --project=. -e 'using Pkg; Pkg.test()'`.

## 4. Build + verify
- [ ] `scripts/smoke_test.sh <problem>` — builds the image, checks `/problems`
      lists `<problem>`, solves the sample.
- [ ] `clients/examples/verify_<problem>.py` from `templates/verify_problem.py.tmpl`
      — run `uv run examples/verify_<problem>.py` from `clients/`.

## Gotchas
- JSON objects decode with **string keys**; the coercion helpers already handle both
  plain `Dict` and JSON payloads, so always read fields through them.
- The image only contains `src/` and `server/` — the new experiment ships, but the
  `data/` sample and Python helper do **not** (they're for local dev/tests).
- Keep the objective **minimized** and constraints **soft** (penalties), matching
  the built-ins.
