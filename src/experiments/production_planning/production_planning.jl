# Copyright (c) 2026 Stefano Longobardi
# SPDX-License-Identifier: Apache-2.0

"""
    ProductionPlanningExperiment <: Experiment

A small constrained quadratic problem, kept deliberately simple as a template for
registering a new problem.

A fixed production quota must be split across `n_plants` plants without exceeding a
shared `capacity`. Each plant must stay open (produce at least one unit), and running
a plant away from its ideal load wastes money that grows quadratically with the gap.
The goal is to minimise the total waste

    minimise  ∑ (load_i − ideal_loads_i)²
    s.t.      ∑ load_i ≤ capacity          (shared budget)
              1 ≤ load_i ≤ capacity        (each plant stays open)

The objective is a paraboloid (a sum of squares); the budget is the binding constraint
whenever the ideal loads together ask for more than the capacity. Unlike the other
built-in problems this one has no file format — it is built only from a JSON payload.

# Fields
- `n_plants::Int`: Number of plants (decision variables)
- `capacity::Int`: Shared production budget; also the largest load a plant may take
- `ideal_loads::Vector{Int}`: Each plant's most efficient load (length `n_plants`)
- `α::Float64`: Penalty parameter for exceeding the budget
"""
struct ProductionPlanningExperiment <: Experiment
    n_plants::Int
    capacity::Int
    ideal_loads::Vector{Int}
    α::Float64
end

"""
    n_decision_variables(e::ProductionPlanningExperiment)

One decision variable per plant: how many units it produces.
"""
n_decision_variables(e::ProductionPlanningExperiment) = e.n_plants

"""
    decision_type(::ProductionPlanningExperiment)

Each plant's load is an integer number of units.
"""
decision_type(::ProductionPlanningExperiment) = IntDecisionValue

# Loads range over 1..capacity, so "produce at least one unit" is baked into the
# domain rather than enforced as a constraint.
generate_domains(e::ProductionPlanningExperiment) = [collect(1:e.capacity) for _ = 1:e.n_plants]

"""
    (::SimpleInitialization)(e::ProductionPlanningExperiment)

Starts every plant at one unit — always within budget, so the search begins feasible.
"""
(::SimpleInitialization)(e::ProductionPlanningExperiment) = fill(1, e.n_plants)

default_init(::ProductionPlanningExperiment) = SimpleInitialization()

"""
    create_dag(e::ProductionPlanningExperiment)

Builds the DAG encoding the quadratic objective and the budget constraint.

Objective: each plant's load is mapped to its squared deviation with an
[`ElementInvariant`](@ref) (a precomputed value→cost table), turned into a scalar by a
unit [`ScaleInvariant`](@ref), and summed by an [`ObjectiveInvariant`](@ref).

Constraint: the loads are summed and compared against `capacity` with a
[`ComparatorInvariant`](@ref); any overflow is penalised by `α` through a
[`StaticConstraintInvariant`](@ref). An [`AggregatorInvariant`](@ref) combines the two.
"""
function create_dag(e::ProductionPlanningExperiment)
    dag = DAG(e.n_plants)

    # Objective: ∑ (load_i − ideal_i)²
    cost_nodes = Int[]
    for i = 1:e.n_plants
        squared_deviation = [IntDecisionValue((load - e.ideal_loads[i])^2) for load = 1:e.capacity]
        deviation_node = add_invariant!(dag, ElementInvariant(i, squared_deviation); variable_parent_indexes = [i])
        push!(cost_nodes, add_invariant!(dag, ScaleInvariant(1.0); invariant_parent_indexes = [deviation_node]))
    end
    objective_node =
        add_invariant!(dag, ObjectiveInvariant(); name = "total_waste", invariant_parent_indexes = cost_nodes)

    # Constraint: ∑ load_i ≤ capacity
    load_nodes = [
        add_invariant!(dag, ScaleInvariant(1.0); variable_parent_indexes = [i], using_cp = true) for i = 1:e.n_plants
    ]
    budget_node = add_invariant!(
        dag,
        ComparatorInvariant(e.capacity);
        name = "over_budget",
        invariant_parent_indexes = load_nodes,
        using_cp = true,
    )
    constraint_node = add_invariant!(dag, StaticConstraintInvariant(e.α); invariant_parent_indexes = [budget_node])

    add_invariant!(dag, AggregatorInvariant(); invariant_parent_indexes = [constraint_node, objective_node])
    return dag
end

"""
    from_data(::Type{ProductionPlanningExperiment}, data)

Builds the experiment from a payload with `capacity`, `ideal_loads` (non-empty, each
≥ 1) and an optional `penalty`. Requires `capacity ≥ n_plants` so the problem is
feasible. See [`data_schema`](@ref).
"""
function from_data(::Type{ProductionPlanningExperiment}, data::AbstractDict)
    capacity = as_integer(data, "capacity")
    ideal_loads = as_integer_array(data, "ideal_loads")
    isempty(ideal_loads) && throw(InvalidInputError("'ideal_loads' must be non-empty"))
    all(>=(1), ideal_loads) || throw(InvalidInputError("every entry of 'ideal_loads' must be at least 1"))
    n_plants = length(ideal_loads)
    capacity >= n_plants ||
        throw(InvalidInputError("'capacity' ($capacity) must be at least the number of plants ($n_plants)"))
    α = as_number(data, "penalty", DEFAULT_PENALTY_PARAM)
    return ProductionPlanningExperiment(n_plants, capacity, ideal_loads, α)
end

data_schema(::Type{ProductionPlanningExperiment}) = [
    FieldSpec("capacity", :integer, true, "Shared production budget; also the largest load a single plant may take"),
    FieldSpec("ideal_loads", :integer_array, true, "Each plant's most efficient load (one entry per plant, each ≥ 1)"),
    FieldSpec("penalty", :number, false, "Budget-violation penalty α (default $(DEFAULT_PENALTY_PARAM))"),
]

@testitem "ProductionPlanningExperiment builds, validates and solves" begin
    # ideals sum to 18 but only 10 units of capacity -> the budget binds
    e = JuLS.build_experiment(
        "production_planning",
        Dict{String,Any}("capacity" => 10, "ideal_loads" => [6, 5, 7]),
    )
    @test e.n_plants == 3
    @test e.capacity == 10
    @test e.ideal_loads == [6, 5, 7]
    @test e.α == JuLS.DEFAULT_PENALTY_PARAM

    model = JuLS.init_model(e)
    JuLS.optimize!(model; limit = JuLS.IterationLimit(300))
    @test !isnothing(model.best_solution)

    loads = [v.value for v in model.best_solution.values]
    @test all(l -> 1 <= l <= 10, loads)   # each plant open and within capacity
    @test sum(loads) <= 10                 # budget respected
    @test model.best_solution.objective == 22  # optimum: e.g. [3, 2, 5]
end

@testitem "ProductionPlanningExperiment rejects bad payloads" begin
    # missing required field
    @test_throws JuLS.InvalidInputError JuLS.build_experiment(
        "production_planning",
        Dict{String,Any}("ideal_loads" => [1, 2]),
    )
    # not enough capacity for one unit per plant
    @test_throws JuLS.InvalidInputError JuLS.build_experiment(
        "production_planning",
        Dict{String,Any}("capacity" => 2, "ideal_loads" => [1, 1, 1]),
    )
    # non-positive ideal load
    @test_throws JuLS.InvalidInputError JuLS.build_experiment(
        "production_planning",
        Dict{String,Any}("capacity" => 5, "ideal_loads" => [0, 2]),
    )
end
