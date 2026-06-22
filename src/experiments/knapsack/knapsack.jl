# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

"""
    KnapsackExperiment <: Experiment

Represents a 0-1 Knapsack Problem experiment instance.

# Fields
- `input_file::String`: Unused; retained for compatibility (always `""`)
- `α::Float64`: Penalty parameter for constraint violation
- `n_items::Int`: Number of items
- `capacity::Int`: Knapsack capacity
- `values::Vector{Int}`: Values of items
- `weights::Vector{Int}`: Weights of items

Instances are built from a decoded payload via [`from_data`](@ref); see also
[`load_sample`](@ref) for the bundled `easy`/`medium`/`hard` samples.
"""
struct KnapsackExperiment <: Experiment
    input_file::String
    α::Float64
    n_items::Int
    capacity::Int
    values::Vector{Int}
    weights::Vector{Int}

    # Raw field constructor (used by from_data)
    KnapsackExperiment(
        input_file::String,
        α::Float64,
        n_items::Int,
        capacity::Int,
        values::Vector{Int},
        weights::Vector{Int},
    ) = new(input_file, α, n_items, capacity, values, weights)
end

"""
    n_decision_variables(e::KnapsackExperiment)

The number of decision variables is equal to number of items.
"""
n_decision_variables(e::KnapsackExperiment) = e.n_items

"""
    decision_type(::KnapsackExperiment)

Decision is binary for item selection.
"""
decision_type(::KnapsackExperiment) = BinaryDecisionValue
generate_domains(e::KnapsackExperiment) = [[false, true] for _ = 1:e.n_items]

"""
    from_data(::Type{KnapsackExperiment}, data)

Builds a knapsack experiment from a payload with `capacity`, `values`, `weights`
(equal-length, non-empty) and an optional `penalty`. See [`data_schema`](@ref).
"""
function from_data(::Type{KnapsackExperiment}, data::AbstractDict)
    capacity = as_integer(data, "capacity")
    values = as_integer_array(data, "values")
    weights = as_integer_array(data, "weights")
    isempty(values) && throw(InvalidInputError("'values' must be non-empty"))
    length(values) == length(weights) || throw(
        InvalidInputError(
            "'values' and 'weights' must have the same length (got $(length(values)) and $(length(weights)))",
        ),
    )
    α = as_number(data, "penalty", DEFAULT_PENALTY_PARAM)
    return KnapsackExperiment("", α, length(values), capacity, values, weights)
end

data_schema(::Type{KnapsackExperiment}) = [
    FieldSpec("capacity", :integer, true, "Maximum total weight the knapsack can hold"),
    FieldSpec("values", :integer_array, true, "Value of each item"),
    FieldSpec("weights", :integer_array, true, "Weight of each item (same length as values)"),
    FieldSpec("penalty", :number, false, "Constraint-violation penalty α (default $(DEFAULT_PENALTY_PARAM))"),
]

include("knapsack_init.jl")
include("knapsack_dag.jl")
include("knapsack_neigh.jl")

default_init(::KnapsackExperiment) = GreedyInitialization()
default_neigh(e::KnapsackExperiment) = ExhaustiveNeighbourhood(2, e.n_items)
default_pick(::KnapsackExperiment) = GreedyMoveSelection()
default_using_cp(::KnapsackExperiment) = true
create_dag(e::KnapsackExperiment) = create_knapsack_dag(e.weights, e.values, e.capacity, e.α)


@testitem "init_model() heuristic assignment" begin
    struct MockMoveSelectionHeuristic <: JuLS.MoveSelectionHeuristic end

    # dummy heuristic to pick first evaluated move
    JuLS.pick_a_move(::MockMoveSelectionHeuristic, evaluated_moves::Vector{<:JuLS.MoveEvaluatorOutput}; rng) =
        evaluated_moves[1]

    struct MockNeighbourhoodHeuristic <: JuLS.NeighbourhoodHeuristic end

    # dummy neighbourhood generation
    function JuLS.get_neighbourhood(::MockNeighbourhoodHeuristic, model::JuLS.Model; rng)
        return [
            JuLS.Move([model.decision_variables[1]], [JuLS.BinaryDecisionValue(true)]),
            JuLS.Move([model.decision_variables[2]], [JuLS.BinaryDecisionValue(true)]),
            JuLS.Move([model.decision_variables[3]], [JuLS.BinaryDecisionValue(true)]),
            JuLS.Move([model.decision_variables[4]], [JuLS.BinaryDecisionValue(true)]),
        ]
    end

    e = JuLS.load_sample("knapsack", "easy")
    model = JuLS.init_model(
        e;
        init = JuLS.SimpleInitialization(),
        neigh = MockNeighbourhoodHeuristic(),
        pick = MockMoveSelectionHeuristic(),
    )
    JuLS.optimize!(model; limit = JuLS.IterationLimit(1))

    mock_obj = model.current_solution.objective # keep track of objective for later

    # did the first move get selected?
    @test model.current_solution.values == [
        JuLS.BinaryDecisionValue(true),
        JuLS.BinaryDecisionValue(false),
        JuLS.BinaryDecisionValue(false),
        JuLS.BinaryDecisionValue(false),
    ]

    model = JuLS.init_model(e; init = JuLS.SimpleInitialization())
    JuLS.optimize!(model; limit = JuLS.IterationLimit(1))

    @test model.current_solution.objective < mock_obj # default heuristics should default to something better than dummy
end