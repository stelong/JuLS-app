# Copyright (c) 2026 Stefano Longobardi
# SPDX-License-Identifier: Apache-2.0

"""
    App

A thin HTTP layer exposing the JuLS solver over a RESTful JSON API. Defined as a
plain module inside the JuLS-app project (not a separate package); the web stack
(Oxygen/HTTP/JSON3) is declared in the project's root Project.toml.

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
module App

using JuLS
using Oxygen
using JSON3
using HTTP
using Dates
using Random
using UUIDs
using TestItems  # provides the @testitem macro (a no-op outside the test runner)

export start_server

# ---------------------------------------------------------------------------
# Resource limits
# ---------------------------------------------------------------------------
# Bounds that protect the server from unbounded or abusive requests. Read once at
# module load and overridable via environment variables so they can be tuned per
# deployment without a rebuild.
#   JULS_MAX_BODY_BYTES     largest accepted request body            (default 1 MB)
#   JULS_MAX_ITERATIONS     cap on a request's iteration budget      (default 100k)
#   JULS_MAX_SOLVE_SECONDS  hard wall-clock ceiling on a single solve (default 60s)
const MAX_BODY_BYTES = parse(Int, get(ENV, "JULS_MAX_BODY_BYTES", "1000000"))
const MAX_ITERATIONS = parse(Int, get(ENV, "JULS_MAX_ITERATIONS", "100000"))
const MAX_SOLVE_SECONDS = parse(Float64, get(ENV, "JULS_MAX_SOLVE_SECONDS", "60.0"))

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

function error_response(status::Int, message::AbstractString, id = nothing)
    payload = Dict{String,Any}("error" => message)
    isnothing(id) || (payload["id"] = id)
    return json_response(payload, status)
end

# ---------------------------------------------------------------------------
# Solve-option parsing
# ---------------------------------------------------------------------------
# Reject (rather than silently clamp) requests asking for more work than the
# configured ceilings allow, so callers get an explicit, actionable 400.
function _checked_iterations(n::Int)
    n >= 1 || throw(JuLS.InvalidInputError("solve.limit iterations must be >= 1"))
    n <= MAX_ITERATIONS ||
        throw(JuLS.InvalidInputError("solve.limit iterations ($n) exceeds the maximum of $MAX_ITERATIONS"))
    return n
end

function _checked_seconds(t::Float64)
    t > 0 || throw(JuLS.InvalidInputError("solve.limit time must be > 0"))
    t <= MAX_SOLVE_SECONDS ||
        throw(JuLS.InvalidInputError("solve.limit time ($t s) exceeds the maximum of $MAX_SOLVE_SECONDS s"))
    return t
end

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
            n = _checked_iterations(Int(l))
            limit = JuLS.IterationLimit(n)
            limit_echo = Dict{String,Any}("type" => "iterations", "value" => n)
        elseif l isa AbstractDict
            if haskey(l, "iterations")
                n = _checked_iterations(Int(l["iterations"]))
                limit = JuLS.IterationLimit(n)
                limit_echo = Dict{String,Any}("type" => "iterations", "value" => n)
            elseif haskey(l, "time")
                t = _checked_seconds(Float64(l["time"]))
                limit = JuLS.TimeLimit(t)
                limit_echo = Dict{String,Any}("type" => "time", "seconds" => t)
            elseif haskey(l, "stagnation")
                patience = Int(l["stagnation"])
                patience >= 1 || throw(JuLS.InvalidInputError("solve.limit.stagnation must be >= 1"))
                max_it = _checked_iterations(haskey(l, "max_iterations") ? Int(l["max_iterations"]) : 10_000)
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
    summarize(experiment, id, problem, model, solve_echo, elapsed) -> Dict

Builds the comprehensive JSON-ready solution summary returned by `POST /solve`. `id`
is echoed straight back to the caller so concurrent requests can be matched to their
responses regardless of completion order.
"""
function summarize(
    experiment,
    id,
    problem::AbstractString,
    model,
    solve_echo,
    elapsed::Float64,
    time_budget_exceeded::Bool = false,
)
    metrics = model.run_metrics
    n_records = metrics.current_iteration
    feasible = !isnothing(model.best_solution)
    solution = feasible ? model.best_solution : model.current_solution

    t0 = metrics.iteration_time[1]
    relative_times = [Dates.value(metrics.iteration_time[i] - t0) / 1000 for i = 1:n_records]

    return Dict{String,Any}(
        "id" => id,
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
            # true when the wall-clock budget stopped the solve before its limit;
            # the returned solution is the best found within that budget
            "time_budget_exceeded" => time_budget_exceeded,
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
"""
    health_handler(::HTTP.Request)

Liveness probe for `GET /health`; returns `ok` plus the registered problem names.
"""
health_handler(::HTTP.Request) = Dict("status" => "ok", "problems" => JuLS.available_problems())

"""
    problems_handler(::HTTP.Request)

Handles `GET /problems`, returning the input schema ([`FieldSpec`](@ref) fields) of
every registered problem.
"""
function problems_handler(::HTTP.Request)
    return Dict(
        problem => [
            Dict("name" => f.name, "kind" => String(f.kind), "required" => f.required, "doc" => f.doc) for
            f in JuLS.data_schema(JuLS.experiment_type(problem))
        ] for problem in JuLS.available_problems()
    )
end

"""
    solve_handler(req::HTTP.Request)

Handles `POST /solve`: decodes the JSON body, builds the experiment, runs the
solver, and returns the comprehensive solution summary. Malformed input yields
HTTP 400; an oversized body 413; and an unexpected solver failure 500 (details
logged, not returned). A solve that hits the wall-clock budget still returns 200
with the best solution found and `metrics.time_budget_exceeded = true`. Error
responses echo the request `id` when one was supplied.
"""
function solve_handler(req::HTTP.Request)
    if length(req.body) > MAX_BODY_BYTES
        return error_response(413, "request body exceeds the maximum of $MAX_BODY_BYTES bytes")
    end

    local body
    try
        body = to_native(JSON3.read(req.body))
    catch
        return error_response(400, "request body must be valid JSON")
    end

    body isa AbstractDict || return error_response(400, "request body must be a JSON object")
    # Optional client-supplied correlation id, echoed back verbatim so callers can
    # join responses to requests when solving many concurrently. A string or number
    # is accepted; absent, a UUID is generated.
    id = get(body, "id", nothing)
    if isnothing(id)
        id = string(uuid4())
    elseif !(id isa AbstractString || id isa Number)
        return error_response(400, "'id' must be a string or number")
    end
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
        # Per-request RNG (never the shared global) so concurrent solves on
        # different threads stay independent and reproducible when a seed is given.
        rng = isnothing(seed) ? Random.MersenneTwister() : Random.MersenneTwister(seed)
        t0 = time()
        time_budget_exceeded = JuLS.optimize!(model; limit = limit, rng = rng, max_seconds = MAX_SOLVE_SECONDS)
        elapsed = time() - t0
        time_budget_exceeded &&
            @warn "solve hit time budget; returning best-so-far" id problem seconds = MAX_SOLVE_SECONDS
        return json_response(summarize(experiment, id, problem, model, solve_echo, elapsed, time_budget_exceeded))
    catch err
        err isa JuLS.InvalidInputError && return error_response(400, err.msg, id)
        # Log the full error server-side (with a correlation id) but never leak
        # internal details to the caller.
        @error "solve failed" id problem exception = (err, catch_backtrace())
        return error_response(500, "internal solver error", id)
    end
end

# ---------------------------------------------------------------------------
# Warmup
# ---------------------------------------------------------------------------
# Minimal valid payloads, one per problem, used to exercise the full solve path
# on startup so the first real user request doesn't pay the JIT cost. The same
# routine is the PackageCompiler precompile workload (see server/precompile.jl).
const WARMUP_PAYLOADS = Dict{String,Any}(
    "knapsack" => Dict("capacity" => 5, "values" => [3, 4, 2], "weights" => [2, 3, 1]),
    "tsp" => Dict("coordinates" => [[0, 0], [1, 0], [1, 1], [0, 1]]),
    "graph_coloring" => Dict("n_nodes" => 3, "edges" => [[1, 2], [2, 3]], "max_color" => 3),
    "production_planning" => Dict("capacity" => 6, "ideal_loads" => [3, 4]),
    "ticket_pricing" => Dict(
        "n_tickets" => 4,
        "price_tiers" => [10, 20],
        "retailers" => [Dict("name" => "A", "commission" => 0.1, "fixed_fee" => 1, "demands" => [2, 1])],
    ),
)

"""
    warmup(; verbose=false)

Runs one tiny solve per registered problem through the real `solve_handler`, so
the solver, JSON (de)serialization and response building are all compiled before
the server accepts traffic. Also reused as the PackageCompiler precompile
workload to bake these paths into the sysimage.
"""
function warmup(; verbose::Bool = false)
    for problem in JuLS.available_problems()
        haskey(WARMUP_PAYLOADS, problem) || continue
        body = JSON3.write(
            Dict(
                "problem" => problem,
                "data" => WARMUP_PAYLOADS[problem],
                "solve" => Dict("limit" => 20, "seed" => 0),
            ),
        )
        req = HTTP.Request("POST", "/solve", ["Content-Type" => "application/json"], Vector{UInt8}(body))
        resp = solve_handler(req)
        verbose && println("warmup ", problem, " -> HTTP ", resp.status)
    end
    return nothing
end

# ---------------------------------------------------------------------------
# Server entry point
# ---------------------------------------------------------------------------
"""
    start_server(; host="0.0.0.0", port=8080, parallel=true, warmup_on_start=true, kwargs...)

Registers the routes and starts the HTTP server (blocking). With `parallel`,
requests are handled across threads (`Oxygen.serveparallel`) so independent
solves run concurrently — start Julia with multiple threads to benefit. Extra
keyword arguments are forwarded to the underlying serve call.
"""
function start_server(;
    host::String = "0.0.0.0",
    port::Int = 8080,
    parallel::Bool = true,
    warmup_on_start::Bool = true,
    kwargs...,
)
    Oxygen.get(health_handler, "/health")
    Oxygen.get(problems_handler, "/problems")
    Oxygen.post(solve_handler, "/solve")

    if warmup_on_start
        @info "warming up solver"
        warmup()
        @info "warmup complete; serving" host port parallel threads = Threads.nthreads()
    end

    serve_fn = parallel ? Oxygen.serveparallel : Oxygen.serve
    serve_fn(; host = host, port = port, kwargs...)
end

@testitem "solve request guards (caps, body size, error hygiene)" begin
    using JSON3, HTTP
    include(joinpath(pkgdir(JuLS), "server", "app.jl"))

    post(body) = App.solve_handler(
        HTTP.Request("POST", "/solve", ["Content-Type" => "application/json"], Vector{UInt8}(body)),
    )
    decode(resp) = JSON3.read(resp.body)

    # parse_solve rejects out-of-bounds budgets
    @test_throws JuLS.InvalidInputError App.parse_solve(Dict("limit" => 0))
    @test_throws JuLS.InvalidInputError App.parse_solve(Dict("limit" => App.MAX_ITERATIONS + 1))
    @test_throws JuLS.InvalidInputError App.parse_solve(Dict("limit" => Dict("time" => App.MAX_SOLVE_SECONDS + 1)))
    @test_throws JuLS.InvalidInputError App.parse_solve(Dict("limit" => Dict("time" => 0)))
    # within bounds parses and echoes
    limit, using_cp, seed, echo = App.parse_solve(Dict("limit" => 50))
    @test limit == JuLS.IterationLimit(50)
    @test echo["limit"]["value"] == 50

    # oversized body -> 413, no solve attempted
    big = repeat("a", App.MAX_BODY_BYTES + 1)
    @test post(big).status == 413

    # invalid-input error carries the client's correlation id and a clean message
    resp = post(JSON3.write(Dict("id" => "req-42", "problem" => "knapsack", "data" => Dict("capacity" => 5))))
    @test resp.status == 400
    body = decode(resp)
    @test body.id == "req-42"
    @test !occursin("backtrace", lowercase(String(body.error)))

    # a normal solve still succeeds through the deadline-bounded runner
    ok = post(
        JSON3.write(
            Dict(
                "id" => 7,
                "problem" => "knapsack",
                "data" => Dict("capacity" => 5, "values" => [3, 4, 2], "weights" => [2, 3, 1]),
                "solve" => Dict("limit" => 20, "seed" => 0),
            ),
        ),
    )
    @test ok.status == 200
    okbody = decode(ok)
    @test okbody.id == 7
    @test okbody.metrics.time_budget_exceeded == false
end

end # module JuLSServer
