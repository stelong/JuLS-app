# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

"""
    JuLSServer

A thin HTTP layer exposing the JuLS solver over a RESTful JSON API. Kept as a
separate environment (depends on JuLS + Oxygen) so the web stack lives only in
the deployable app, not in the core solver library.

Endpoints:
- `GET  /health`   — liveness probe
- `GET  /problems` — registered problems and their input schema
- `POST /solve`    — solve a problem synchronously, returning the solution as JSON

Request body for `POST /solve`:

    {
      "problem": "knapsack",
      "data":    { ...problem-specific fields (see GET /problems)... },
      "solve":   { "limit": {"iterations": 100}, "using_cp": true, "seed": 0 }
    }

`solve` is optional. `limit` may be an integer (iterations), `"auto"`, or one of
`{"iterations": n}`, `{"time": seconds}`, `{"stagnation": patience, "max_iterations": n}`.
"""
module JuLSServer

using JuLS
using Oxygen
using JSON3
using HTTP
using Dates
using Random
using UUIDs

export start_server

# ---------------------------------------------------------------------------
# JSON helpers
# ---------------------------------------------------------------------------
# Convert parsed JSON3 values into plain Julia containers so the core
# JuLS.build_experiment helpers receive exactly Dict{String,Any}/Vector{Any}.
to_native(x::JSON3.Object) = Dict{String,Any}(String(k) => to_native(v) for (k, v) in pairs(x))
to_native(x::JSON3.Array) = Any[to_native(v) for v in x]
to_native(x) = x

json_response(obj, status::Int = 200) =
    HTTP.Response(status, ["Content-Type" => "application/json"]; body = JSON3.write(obj))

error_response(status::Int, message::AbstractString) =
    json_response(Dict("error" => message), status)

# ---------------------------------------------------------------------------
# Solve-option parsing
# ---------------------------------------------------------------------------
"""
    parse_solve(opts) -> (limit, using_cp, seed, echo)

Translates the optional `solve` block into arguments for `init_model`/`optimize!`
and an `echo` dict describing what was actually used. Throws `InvalidInputError`
on malformed options.
"""
function parse_solve(opts::AbstractDict)
    limit = JuLS.IterationLimit(100)
    limit_echo = Dict{String,Any}("type" => "iterations", "value" => 100)

    if haskey(opts, "limit")
        l = opts["limit"]
        if l isa AbstractString
            l == "auto" || throw(JuLS.InvalidInputError("solve.limit string must be \"auto\""))
            limit = :auto
            limit_echo = Dict{String,Any}("type" => "auto")
        elseif l isa Integer
            limit = JuLS.IterationLimit(Int(l))
            limit_echo = Dict{String,Any}("type" => "iterations", "value" => Int(l))
        elseif l isa AbstractDict
            if haskey(l, "iterations")
                n = Int(l["iterations"])
                limit = JuLS.IterationLimit(n)
                limit_echo = Dict{String,Any}("type" => "iterations", "value" => n)
            elseif haskey(l, "time")
                t = Float64(l["time"])
                limit = JuLS.TimeLimit(t)
                limit_echo = Dict{String,Any}("type" => "time", "seconds" => t)
            elseif haskey(l, "stagnation")
                patience = Int(l["stagnation"])
                max_it = haskey(l, "max_iterations") ? Int(l["max_iterations"]) : 10_000
                limit = JuLS.StagnationLimit(patience; max_iterations = max_it)
                limit_echo = Dict{String,Any}("type" => "stagnation", "patience" => patience, "max_iterations" => max_it)
            else
                throw(JuLS.InvalidInputError("solve.limit object must have 'iterations', 'time', or 'stagnation'"))
            end
        else
            throw(JuLS.InvalidInputError("solve.limit must be an integer, \"auto\", or an object"))
        end
    end

    using_cp = true
    if haskey(opts, "using_cp")
        opts["using_cp"] isa Bool || throw(JuLS.InvalidInputError("solve.using_cp must be a boolean"))
        using_cp = opts["using_cp"]
    end

    seed = nothing
    if haskey(opts, "seed")
        JuLS._is_int(opts["seed"]) || throw(JuLS.InvalidInputError("solve.seed must be an integer"))
        seed = Int(opts["seed"])
    end

    echo = Dict{String,Any}("limit" => limit_echo, "using_cp" => using_cp, "seed" => seed)
    return limit, using_cp, seed, echo
end

# ---------------------------------------------------------------------------
# Response building
# ---------------------------------------------------------------------------
"""
    summarize(experiment, problem, model, solve_echo, elapsed) -> Dict

Builds the comprehensive JSON-ready solution summary returned by `POST /solve`.
"""
function summarize(experiment, problem::AbstractString, model, solve_echo, elapsed::Float64)
    metrics = model.run_metrics
    n_records = metrics.current_iteration
    feasible = !isnothing(model.best_solution)
    solution = feasible ? model.best_solution : model.current_solution

    t0 = metrics.iteration_time[1]
    relative_times = [Dates.value(metrics.iteration_time[i] - t0) / 1000 for i = 1:n_records]

    return Dict{String,Any}(
        "id" => string(uuid4()),
        "problem" => problem,
        "status" => feasible ? "feasible" : "infeasible",
        "solve" => solve_echo,
        "result" => Dict{String,Any}(
            "objective" => solution.objective,
            "feasible" => feasible,
            "variables" => [v.value for v in solution.values],
            "n_decision_variables" => JuLS.n_decision_variables(experiment),
            "decision_type" => string(nameof(JuLS.decision_type(experiment))),
            "objective_sense" => "minimize",
        ),
        "metrics" => Dict{String,Any}(
            "iterations" => n_records - 1,
            "solve_time_seconds" => elapsed,
            "initial_objective" => metrics.objective[1],
            "objective_history" => metrics.objective[1:n_records],
            "feasible_history" => metrics.feasible[1:n_records],
            "iteration_time_seconds" => relative_times,
            "improving_iterations" => JuLS.best_solution_indexes(metrics),
        ),
    )
end

# ---------------------------------------------------------------------------
# Handlers
# ---------------------------------------------------------------------------
health_handler(::HTTP.Request) = Dict("status" => "ok", "problems" => JuLS.available_problems())

function problems_handler(::HTTP.Request)
    return Dict(
        problem => [
            Dict("name" => f.name, "kind" => String(f.kind), "required" => f.required, "doc" => f.doc) for
            f in JuLS.data_schema(JuLS.experiment_type(problem))
        ] for problem in JuLS.available_problems()
    )
end

function solve_handler(req::HTTP.Request)
    local body
    try
        body = to_native(JSON3.read(req.body))
    catch
        return error_response(400, "request body must be valid JSON")
    end

    body isa AbstractDict || return error_response(400, "request body must be a JSON object")
    problem = get(body, "problem", nothing)
    problem isa AbstractString || return error_response(400, "'problem' (string) is required")
    data = get(body, "data", nothing)
    data isa AbstractDict || return error_response(400, "'data' (object) is required")
    solve_opts = get(body, "solve", Dict{String,Any}())
    solve_opts isa AbstractDict || return error_response(400, "'solve' must be an object")

    try
        experiment = JuLS.build_experiment(problem, data)
        limit, using_cp, seed, solve_echo = parse_solve(solve_opts)
        model = JuLS.init_model(experiment; using_cp = using_cp)
        rng = isnothing(seed) ? Random.GLOBAL_RNG : Random.MersenneTwister(seed)
        elapsed = @elapsed JuLS.optimize!(model; limit = limit, rng = rng)
        return json_response(summarize(experiment, problem, model, solve_echo, elapsed))
    catch err
        err isa JuLS.InvalidInputError && return error_response(400, err.msg)
        @error "solve failed" exception = (err, catch_backtrace())
        return error_response(500, "internal solver error: " * sprint(showerror, err))
    end
end

# ---------------------------------------------------------------------------
# Server entry point
# ---------------------------------------------------------------------------
"""
    start_server(; host="0.0.0.0", port=8080, kwargs...)

Registers the routes and starts the HTTP server (blocking). Extra keyword
arguments are forwarded to `Oxygen.serve`.
"""
function start_server(; host::String = "0.0.0.0", port::Int = 8080, kwargs...)
    Oxygen.get(health_handler, "/health")
    Oxygen.get(problems_handler, "/problems")
    Oxygen.post(solve_handler, "/solve")
    Oxygen.serve(; host = host, port = port, kwargs...)
end

end # module JuLSServer
