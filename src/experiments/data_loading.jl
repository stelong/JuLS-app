# Copyright (c) 2026 Stefano Longobardi
# SPDX-License-Identifier: Apache-2.0

# Unified data-loading contract for experiments.
#
# Every Experiment type implements two methods:
#   from_data(::Type{E}, data::AbstractDict) -> E   : build an instance from a decoded payload
#   data_schema(::Type{E}) -> Vector{FieldSpec}     : self-describing schema (docs / clients)
# and is registered by name in EXPERIMENT_REGISTRY (see experiments.jl).
#
# Parsing is dict-based and carries no HTTP/JSON dependency: a server layer decodes
# the request body into a Dict and calls `build_experiment(problem, data)`. This keeps
# the solver a pure library while giving every problem the same loading protocol.

"""
    InvalidInputError(msg)

Thrown when a request payload does not match an experiment's expected schema. A
server layer is expected to map this to an HTTP 400 response carrying `msg`.
"""
struct InvalidInputError <: Exception
    msg::String
end
Base.showerror(io::IO, e::InvalidInputError) = print(io, "InvalidInputError: ", e.msg)

"""
    FieldSpec(name, kind, required, doc)

Describes one field of an experiment's `data` payload. Returned by [`data_schema`](@ref)
to document the API; validation itself is performed in `from_data`.

# Fields
- `name::String`: Field name as it appears in the `data` payload
- `kind::Symbol`: One of `:integer`, `:number`, `:integer_array`, `:number_array`, `:coordinate_array`, `:edge_array`, `:object_array`
- `required::Bool`: Whether the field must be present
- `doc::String`: Human-readable description shown by the API
"""
struct FieldSpec
    name::String
    kind::Symbol
    required::Bool
    doc::String
end

# ---------------------------------------------------------------------------
# Coercion helpers — each throws InvalidInputError with an actionable message.
# They accept any AbstractDict/AbstractVector so they work both with plain Julia
# Dicts (tests) and JSON3.Object/JSON3.Array (server).
# ---------------------------------------------------------------------------
_typename(x) = string(typeof(x))
_is_int(x) = x isa Integer || (x isa Real && isinteger(x))

_require(data::AbstractDict, key::String) =
    haskey(data, key) ? data[key] : throw(InvalidInputError("missing required field '$key'"))

"""
    as_integer(data, key) -> Int

Reads required field `key` as an integer, throwing `InvalidInputError` if it is
missing or not integer-valued.
"""
function as_integer(data::AbstractDict, key::String)
    v = _require(data, key)
    _is_int(v) || throw(InvalidInputError("field '$key' must be an integer, got $(_typename(v))"))
    return Int(v)
end

"""
    as_number(data, key) -> Float64
    as_number(data, key, default) -> Float64

Reads field `key` as a floating-point number. The three-argument form returns
`default` when the field is absent; the two-argument form requires it.
"""
function as_number(data::AbstractDict, key::String)
    v = _require(data, key)
    v isa Real || throw(InvalidInputError("field '$key' must be a number, got $(_typename(v))"))
    return Float64(v)
end
as_number(data::AbstractDict, key::String, default::Real) =
    haskey(data, key) ? as_number(data, key) : Float64(default)

"""
    as_string(data, key) -> String

Reads required field `key` as a string, throwing `InvalidInputError` otherwise.
"""
function as_string(data::AbstractDict, key::String)
    v = _require(data, key)
    v isa AbstractString || throw(InvalidInputError("field '$key' must be a string, got $(_typename(v))"))
    return String(v)
end

_elem_int(x, key::String) = _is_int(x) ? Int(x) : throw(InvalidInputError("field '$key' must contain only integers"))
_elem_num(x, key::String) = x isa Real ? Float64(x) : throw(InvalidInputError("field '$key' must contain only numbers"))

"""
    as_integer_array(data, key) -> Vector{Int}

Reads required field `key` as an array of integers.
"""
function as_integer_array(data::AbstractDict, key::String)
    v = _require(data, key)
    v isa AbstractVector || throw(InvalidInputError("field '$key' must be an array of integers"))
    return Int[_elem_int(x, key) for x in v]
end

"""
    as_number_array(data, key) -> Vector{Float64}

Reads required field `key` as an array of numbers.
"""
function as_number_array(data::AbstractDict, key::String)
    v = _require(data, key)
    v isa AbstractVector || throw(InvalidInputError("field '$key' must be an array of numbers"))
    return Float64[_elem_num(x, key) for x in v]
end

"""
    as_coordinate_array(data, key) -> Matrix{Float64}

Parses `[[x, y], ...]` into an `n x 2` matrix of coordinates.
"""
function as_coordinate_array(data::AbstractDict, key::String)
    v = _require(data, key)
    v isa AbstractVector || throw(InvalidInputError("field '$key' must be an array of [x, y] pairs"))
    coords = Array{Float64}(undef, length(v), 2)
    for (i, p) in enumerate(v)
        (p isa AbstractVector && length(p) == 2) ||
            throw(InvalidInputError("each entry of '$key' must be a 2-element [x, y] array"))
        coords[i, 1] = _elem_num(p[1], key)
        coords[i, 2] = _elem_num(p[2], key)
    end
    return coords
end

"""
    as_edge_array(data, key) -> Vector{Tuple{Int,Int}}

Parses `[[i, j], ...]` into a vector of integer node pairs.
"""
function as_edge_array(data::AbstractDict, key::String)
    v = _require(data, key)
    v isa AbstractVector || throw(InvalidInputError("field '$key' must be an array of [i, j] edges"))
    edges = Tuple{Int,Int}[]
    for p in v
        (p isa AbstractVector && length(p) == 2) ||
            throw(InvalidInputError("each entry of '$key' must be a 2-element [i, j] array"))
        push!(edges, (_elem_int(p[1], key), _elem_int(p[2], key)))
    end
    return edges
end

"""
    from_data(::Type{E}, data::AbstractDict) -> E

Builds an experiment of type `E` from a decoded `data` payload, validating it with
the coercion helpers above. Each concrete `Experiment` overrides this method; the
generic fallback throws `InvalidInputError`.
"""
from_data(::Type{E}, ::AbstractDict) where {E<:Experiment} =
    throw(InvalidInputError("loading from data is not supported for $(E)"))

"""
    data_schema(::Type{E}) -> Vector{FieldSpec}

Returns the self-describing input schema for experiment type `E`, used to document
the API. Each concrete `Experiment` overrides this method.
"""
data_schema(::Type{E}) where {E<:Experiment} =
    error("data_schema is not implemented for $(E)")

@testitem "build_experiment dispatches and validates problem name" begin
    @test Set(JuLS.available_problems()) ==
          Set(["knapsack", "tsp", "graph_coloring", "ticket_pricing", "production_planning"])
    @test JuLS.experiment_type("knapsack") == JuLS.KnapsackExperiment
    @test_throws JuLS.InvalidInputError JuLS.build_experiment("does_not_exist", Dict{String,Any}())
end

@testitem "from_data knapsack matches file and solves" begin
    file_e = JuLS.KnapsackExperiment(JuLS.PROJECT_ROOT * "/data/knapsack/ks_4_0", 5.0)
    data_e = JuLS.build_experiment(
        "knapsack",
        Dict{String,Any}("capacity" => 11, "values" => [8, 10, 15, 4], "weights" => [4, 5, 8, 3], "penalty" => 5.0),
    )
    @test data_e.n_items == file_e.n_items
    @test data_e.capacity == file_e.capacity
    @test data_e.values == file_e.values
    @test data_e.weights == file_e.weights
    @test data_e.α == 5.0

    model = JuLS.init_model(data_e)
    JuLS.optimize!(model; limit = JuLS.IterationLimit(10))
    @test !isnothing(model.best_solution)
end

@testitem "from_data knapsack rejects bad payloads" begin
    # missing required field
    @test_throws JuLS.InvalidInputError JuLS.build_experiment(
        "knapsack",
        Dict{String,Any}("values" => [1, 2], "weights" => [1, 2]),
    )
    # mismatched lengths
    @test_throws JuLS.InvalidInputError JuLS.build_experiment(
        "knapsack",
        Dict{String,Any}("capacity" => 5, "values" => [1, 2], "weights" => [1]),
    )
    # wrong type
    @test_throws JuLS.InvalidInputError JuLS.build_experiment(
        "knapsack",
        Dict{String,Any}("capacity" => "lots", "values" => [1], "weights" => [1]),
    )
    # penalty defaults when omitted
    e = JuLS.build_experiment("knapsack", Dict{String,Any}("capacity" => 5, "values" => [1], "weights" => [1]))
    @test e.α == JuLS.DEFAULT_PENALTY_PARAM
end

@testitem "from_data tsp matches file" begin
    file_e = JuLS.TSPExperiment(JuLS.PROJECT_ROOT * "/data/tsp/tsp_5_1")
    data_e = JuLS.build_experiment(
        "tsp",
        Dict{String,Any}("coordinates" => [[0, 0], [0, 0.5], [0, 2], [3, 1], [1, 0]]),
    )
    @test data_e.n_nodes == file_e.n_nodes
    @test data_e.distance_matrix == file_e.distance_matrix
end

@testitem "from_data graph_coloring matches file and validates edges" begin
    file_e = JuLS.GraphColoringExperiment(JuLS.PROJECT_ROOT * "/data/graph_coloring/gc_4_1", 4)
    data_e = JuLS.build_experiment(
        "graph_coloring",
        Dict{String,Any}("n_nodes" => 4, "max_color" => 4, "edges" => [[1, 2], [2, 3], [2, 4]]),
    )
    @test data_e.n_nodes == file_e.n_nodes
    @test data_e.edges == file_e.edges
    @test data_e.adjacency_matrix == file_e.adjacency_matrix

    # an edge referencing a missing node is rejected
    @test_throws JuLS.InvalidInputError JuLS.build_experiment(
        "graph_coloring",
        Dict{String,Any}("n_nodes" => 3, "max_color" => 3, "edges" => [[1, 9]]),
    )
end

@testitem "from_data ticket_pricing matches file and solves" begin
    file_e = JuLS.TicketPricingExperiment(JuLS.PROJECT_ROOT * "/data/ticket_pricing/tp_3_300")
    data_e = JuLS.build_experiment(
        "ticket_pricing",
        Dict{String,Any}(
            "n_tickets" => 300,
            "price_tiers" => [40, 45, 50, 55, 60, 65, 70, 75, 80],
            "retailers" => [
                Dict{String,Any}(
                    "name" => "MegaTickets",
                    "commission" => 0.15,
                    "fixed_fee" => 0.5,
                    "demands" => [320, 256, 204, 163, 130, 104, 83, 66, 53],
                ),
                Dict{String,Any}(
                    "name" => "PrimeSeats",
                    "commission" => 0.25,
                    "fixed_fee" => 1.0,
                    "demands" => [140, 132, 124, 117, 110, 104, 98, 92, 87],
                ),
                Dict{String,Any}(
                    "name" => "BudgetTix",
                    "commission" => 0.1,
                    "fixed_fee" => 0.25,
                    "demands" => [220, 140, 89, 57, 36, 23, 15, 9, 6],
                ),
            ],
        ),
    )
    @test data_e.n_retailers == file_e.n_retailers
    @test data_e.n_tickets == file_e.n_tickets
    @test data_e.price_tiers == file_e.price_tiers
    @test data_e.retailer_names == file_e.retailer_names
    @test data_e.commissions == file_e.commissions
    @test data_e.demands == file_e.demands

    model = JuLS.init_model(data_e)
    JuLS.optimize!(model; limit = JuLS.IterationLimit(10))
    @test !isnothing(model.best_solution)
end
