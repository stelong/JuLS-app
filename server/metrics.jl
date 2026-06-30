# Copyright (c) 2026 Stefano Longobardi
# SPDX-License-Identifier: Apache-2.0
#
# Lightweight, dependency-free Prometheus metrics for the solve API, rendered in the
# text exposition format at `GET /metrics`. All state lives behind a single lock;
# contention is negligible next to solve time, and the server handles requests across
# threads (`Oxygen.serveparallel`). Included into `module App` by app.jl.

# Cumulative histogram bucket upper bounds (seconds), Prometheus-style ("le").
const _HIST_BOUNDS = Float64[0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 60, Inf]

mutable struct Metrics
    lock::ReentrantLock
    requests::Dict{Tuple{String,String},Int}  # (problem, outcome) -> count
    jobs::Dict{String,Int}                     # terminal job state -> count
    bucket_counts::Vector{Int}                 # cumulative #(duration <= bound)
    duration_sum::Float64
    duration_count::Int
end
Metrics() =
    Metrics(ReentrantLock(), Dict{Tuple{String,String},Int}(), Dict{String,Int}(), zeros(Int, length(_HIST_BOUNDS)), 0.0, 0)

const METRICS = Metrics()

"""
    record_job!(state)

Counts one async job reaching a terminal `state` (`succeeded`, `failed`, `timed_out`).
"""
function record_job!(state::AbstractString)
    lock(METRICS.lock) do
        METRICS.jobs[state] = get(METRICS.jobs, state, 0) + 1
    end
    return nothing
end

"""
    record_request!(problem, outcome, duration)

Records one finished `/solve` request: bumps the `(problem, outcome)` counter and
observes its wall-clock `duration` into the latency histogram. `problem`/`outcome`
must be low-cardinality (validated problem name or `"unknown"`; a fixed outcome set)
so they are safe to use as Prometheus labels.
"""
function record_request!(problem::AbstractString, outcome::AbstractString, duration::Real)
    lock(METRICS.lock) do
        key = (String(problem), String(outcome))
        METRICS.requests[key] = get(METRICS.requests, key, 0) + 1
        d = Float64(duration)
        METRICS.duration_sum += d
        METRICS.duration_count += 1
        @inbounds for i in eachindex(_HIST_BOUNDS)
            d <= _HIST_BOUNDS[i] && (METRICS.bucket_counts[i] += 1)
        end
    end
    return nothing
end

"""
    reset_metrics!()

Clears all counters. Called once after startup warmup so warmup solves don't show up
in the exposed metrics.
"""
function reset_metrics!()
    lock(METRICS.lock) do
        empty!(METRICS.requests)
        empty!(METRICS.jobs)
        fill!(METRICS.bucket_counts, 0)
        METRICS.duration_sum = 0.0
        METRICS.duration_count = 0
    end
    return nothing
end

"""
    render_metrics(in_flight) -> String

Serializes the current metrics in the Prometheus text exposition format (v0.0.4).
`in_flight` (the current number of admitted, executing solves) is supplied by the
caller, since admission control owns that counter.
"""
function render_metrics(in_flight::Int)
    io = IOBuffer()
    lock(METRICS.lock) do
        println(io, "# HELP juls_requests_total Total /solve requests by problem and outcome.")
        println(io, "# TYPE juls_requests_total counter")
        for (problem, outcome) in sort!(collect(keys(METRICS.requests)))
            println(io, "juls_requests_total{problem=\"$problem\",outcome=\"$outcome\"} $(METRICS.requests[(problem, outcome)])")
        end

        println(io, "# HELP juls_solves_in_flight Currently executing /solve requests.")
        println(io, "# TYPE juls_solves_in_flight gauge")
        println(io, "juls_solves_in_flight $in_flight")

        println(io, "# HELP juls_jobs_total Async jobs by terminal state.")
        println(io, "# TYPE juls_jobs_total counter")
        for state in sort!(collect(keys(METRICS.jobs)))
            println(io, "juls_jobs_total{state=\"$state\"} $(METRICS.jobs[state])")
        end

        println(io, "# HELP juls_request_duration_seconds /solve wall-clock duration in seconds.")
        println(io, "# TYPE juls_request_duration_seconds histogram")
        for i in eachindex(_HIST_BOUNDS)
            le = isinf(_HIST_BOUNDS[i]) ? "+Inf" : string(_HIST_BOUNDS[i])
            println(io, "juls_request_duration_seconds_bucket{le=\"$le\"} $(METRICS.bucket_counts[i])")
        end
        println(io, "juls_request_duration_seconds_sum $(METRICS.duration_sum)")
        println(io, "juls_request_duration_seconds_count $(METRICS.duration_count)")
    end
    return String(take!(io))
end
