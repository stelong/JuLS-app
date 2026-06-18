# JuLSPlots

Local-only plotting companion for JuLS. It is deliberately kept as a **separate
Julia environment** so that CairoMakie and its heavy dependency tree stay out of
the deployable `juls-app` Docker image (the image solves; it does not plot).

The REST API returns solutions as JSON — clients are expected to plot those
client-side (e.g. with matplotlib/plotly in Python). The functions here are the
reference for what each problem's solution looks like, and are handy for local
exploration.

## Setup

From the repository root:

```bash
julia --project=plotting -e 'using Pkg; Pkg.instantiate()'
```

This resolves JuLS from the parent directory (see `[sources]` in `Project.toml`)
and installs CairoMakie into this environment only.

## Use

```julia
julia --project=plotting

using JuLS, JuLSPlots
e = KnapsackExperiment(JuLS.PROJECT_ROOT * "/data/knapsack/ks_4_0")
model = init_model(e)
optimize!(model; limit = IterationLimit(50))

save("knapsack.png", plot_solution(e, model))     # per-experiment solution plot
save("objective.png", plot_objective(model.run_metrics))  # objective history
```

`plot_solution` is implemented for the Knapsack, TSP, Graph Coloring and Ticket
Pricing experiments.

## Tests

```bash
julia --project=plotting -e 'using Pkg; Pkg.test()'
```
