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

# ---------------------------------------------------------------------------
# Ready-made sample instances (data/<problem>/<tier>.json)
# ---------------------------------------------------------------------------
const SAMPLE_TIERS = ("easy", "medium", "hard")

"""
    sample_path(problem, tier="easy") -> String

Absolute path to the JSON sample instance for `problem` at difficulty `tier`
(`"easy"`, `"medium"`, or `"hard"`), under the repo's `data/` folder. These are the
exact payloads the Python client also ships (`juls.samples`), so an instance is the
same whether driven from Julia or Python.
"""
sample_path(problem::AbstractString, tier::AbstractString = "easy") =
    joinpath(PROJECT_ROOT, "data", problem, tier * ".json")

"""
    _sample_dict(problem, tier="easy") -> Dict{String,Any}

Reads the JSON sample payload for `problem`/`tier` into a mutable top-level `Dict`,
so callers (e.g. tests) can override a field such as `penalty` or `max_color`
before passing it to [`build_experiment`](@ref).
"""
function _sample_dict(problem::AbstractString, tier::AbstractString = "easy")
    path = sample_path(problem, tier)
    isfile(path) ||
        throw(InvalidInputError("no sample for problem '$problem' at tier '$tier' (looked in $path)"))
    # JSON3.read yields a JSON3.Object with Symbol keys; rebuild a mutable Dict with
    # String keys so it matches the from_data coercion helpers (which look up String
    # keys) and lets callers override a top-level field before building.
    return Dict{String,Any}(String(k) => v for (k, v) in pairs(JSON3.read(read(path, String))))
end

"""
    load_sample(problem, tier="easy") -> Experiment

Builds an experiment from the bundled JSON sample for `problem` at difficulty
`tier`, reusing the same validated `from_data` path as the HTTP API:

    model = init_model(load_sample("knapsack", "hard"))
"""
load_sample(problem::AbstractString, tier::AbstractString = "easy") =
    build_experiment(problem, _sample_dict(problem, tier))

@testitem "build_experiment dispatches and validates problem name" begin
    @test Set(JuLS.available_problems()) ==
          Set(["knapsack", "tsp", "graph_coloring", "ticket_pricing", "production_planning"])
    @test JuLS.experiment_type("knapsack") == JuLS.KnapsackExperiment
    @test_throws JuLS.InvalidInputError JuLS.build_experiment("does_not_exist", Dict{String,Any}())
end

@testitem "load_sample builds and solves every bundled sample" begin
    for problem in JuLS.available_problems(), tier in JuLS.SAMPLE_TIERS
        @test isfile(JuLS.sample_path(problem, tier))
        e = JuLS.load_sample(problem, tier)
        @test JuLS.n_decision_variables(e) >= 1
        model = JuLS.init_model(e)
        JuLS.optimize!(model; limit = JuLS.IterationLimit(10))
        @test model.run_metrics.current_iteration > 1
    end

    @test_throws JuLS.InvalidInputError JuLS.load_sample("knapsack", "impossible")
end

@testitem "from_data knapsack reads fields and penalty" begin
    data_e = JuLS.build_experiment(
        "knapsack",
        Dict{String,Any}("capacity" => 11, "values" => [8, 10, 15, 4], "weights" => [4, 5, 8, 3], "penalty" => 5.0),
    )
    @test data_e.n_items == 4
    @test data_e.capacity == 11
    @test data_e.values == [8, 10, 15, 4]
    @test data_e.weights == [4, 5, 8, 3]
    @test data_e.α == 5.0
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

@testitem "from_data graph_coloring validates edges" begin
    # an edge referencing a missing node is rejected
    @test_throws JuLS.InvalidInputError JuLS.build_experiment(
        "graph_coloring",
        Dict{String,Any}("n_nodes" => 3, "max_color" => 3, "edges" => [[1, 9]]),
    )
end
