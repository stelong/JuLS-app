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

Each built-in experiment provides a CairoMakie visualization of the best solution found:

```@docs
plot_solution(::Experiment, ::JuLS.AbstractModel)
plot_solution(::TSPExperiment, ::JuLS.Solution)
plot_solution(::KnapsackExperiment, ::JuLS.Solution)
plot_solution(::GraphColoringExperiment, ::JuLS.Solution)
```
