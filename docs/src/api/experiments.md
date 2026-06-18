# Experiments API

```@meta
CurrentModule = JuLS
```

The Experiments API provides the problem definitions and data handling functionality.

## Built-in Experiments

```@docs
KnapsackExperiment
TSPExperiment
GraphColoringExperiment
```

## Experiment Interface

All experiments must implement the following interface:

- `n_decision_variables(experiment)`: Return the number of decision variables
- `decision_type(experiment)`: Return the type of decision variables  
- `generate_domains(experiment)`: Return the domains for each variable
- `create_dag(experiment)`: Return the DAG representation of the problem

## Plotting

Plotting lives in a separate, local-only environment (`plotting/`, the `JuLSPlots`
package) so that CairoMakie stays out of the deployable solver. It provides
`plot_solution(experiment, model)` for the Knapsack, TSP, Graph Coloring and
Ticket Pricing experiments, plus `plot_objective(model.run_metrics)`. See
`plotting/README.md` for setup and usage.
