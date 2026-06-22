# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

"""
    GraphColoringExperiment <: Experiment

Represents a Graph Coloring Problem experiment instance.

# Fields
- `input_file::String`: Unused; retained for compatibility (always `""`)
- `max_color::Int`: Maximum number of color for this problem
- `α::Float64`: Penalty parameter for constraint violation
- `n_nodes::Int`: Number of nodes
- `n_edges::Int`: Number of edges
- `greedy_coloring::Vector{Int}`: Coloration with greedy algorithm
- `edges::Vector{Tuple{Int,Int}}`: List of edges

Instances are built from a decoded payload via [`from_data`](@ref); see also
[`load_sample`](@ref) for the bundled `easy`/`medium`/`hard` samples.
"""
struct GraphColoringExperiment <: Experiment
    input_file::String
    max_color::Int
    α::Float64
    n_nodes::Int
    edges::Vector{Tuple{Int,Int}}
    adjacency_matrix::BitMatrix

    # Raw field constructor (used by from_data)
    GraphColoringExperiment(
        input_file::String,
        max_color::Int,
        α::Float64,
        n_nodes::Int,
        edges::Vector{Tuple{Int,Int}},
        adjacency_matrix::BitMatrix,
    ) = new(input_file, max_color, α, n_nodes, edges, adjacency_matrix)
end

"""
    n_decision_variables(e::GraphColoringExperiment)

The number of decision variables is equal to number of nodes.
"""
n_decision_variables(e::GraphColoringExperiment) = e.n_nodes

"""
    decision_type(::GraphColoringExperiment)

Decision is the color selected for each node (indexed by Int)
"""
decision_type(::GraphColoringExperiment) = IntDecisionValue
generate_domains(e::GraphColoringExperiment) = [collect(1:e.max_color) for _ = 1:e.n_nodes]

"""
    from_data(::Type{GraphColoringExperiment}, data)

Builds a graph-coloring experiment from a payload with `n_nodes`, `max_color`,
`edges` (each `[i, j]` within `1..n_nodes`) and an optional `penalty`. See
[`data_schema`](@ref).
"""
function from_data(::Type{GraphColoringExperiment}, data::AbstractDict)
    n_nodes = as_integer(data, "n_nodes")
    max_color = as_integer(data, "max_color")
    edges = as_edge_array(data, "edges")
    n_nodes >= 1 || throw(InvalidInputError("'n_nodes' must be at least 1"))
    max_color >= 1 || throw(InvalidInputError("'max_color' must be at least 1"))
    adjacency_matrix = falses(n_nodes, n_nodes)
    for (a, b) in edges
        (1 <= a <= n_nodes && 1 <= b <= n_nodes) ||
            throw(InvalidInputError("edge ($a, $b) references a node outside 1..$n_nodes"))
        adjacency_matrix[a, b] = true
        adjacency_matrix[b, a] = true
    end
    α = as_number(data, "penalty", DEFAULT_PENALTY_PARAM)
    return GraphColoringExperiment("", max_color, α, n_nodes, edges, adjacency_matrix)
end

data_schema(::Type{GraphColoringExperiment}) = [
    FieldSpec("n_nodes", :integer, true, "Number of nodes (nodes are indexed 1..n_nodes)"),
    FieldSpec("edges", :edge_array, true, "Edges as [[i, j], ...] with i, j in 1..n_nodes"),
    FieldSpec("max_color", :integer, true, "Maximum number of colors available"),
    FieldSpec("penalty", :number, false, "Constraint-violation penalty α (default $(DEFAULT_PENALTY_PARAM))"),
]

include("graph_coloring_init.jl")
include("graph_coloring_dag.jl")
include("graph_coloring_neigh.jl")

default_init(::GraphColoringExperiment) = GreedyInitialization()
default_neigh(e::GraphColoringExperiment) = coloring_neighbourhood(e, 3)
default_pick(::GraphColoringExperiment) = GreedyMoveSelection()
default_using_cp(::GraphColoringExperiment) = true
create_dag(e::GraphColoringExperiment) = create_graph_coloring_dag(e.n_nodes, e.edges, e.max_color, e.α)

@testitem "init_model(::GraphColoringExperiment)" begin
    data = JuLS._sample_dict("graph_coloring", "easy")
    data["max_color"] = 4
    e = JuLS.build_experiment("graph_coloring", data)
    model = JuLS.init_model(e; init = JuLS.SimpleInitialization())
    JuLS.optimize!(model; limit = JuLS.IterationLimit(1))

    @test model.current_solution.objective < model.run_metrics.objective[1]
end