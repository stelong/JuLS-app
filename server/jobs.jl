# Copyright (c) 2026 Stefano Longobardi
# SPDX-License-Identifier: Apache-2.0
#
# Phase 1 of the async solve API (see docs/async-design.md): an in-process job model,
# a pluggable queue/store behind small interfaces, and a worker that runs the same
# `JuLS.optimize!` path as the synchronous handler. Local (in-memory) backends keep the
# whole flow testable without AWS; SQS/DynamoDB/S3 adapters come in Phase 2.
# Included into `module App` by app.jl (after parse_solve/summarize/log_json exist).

const TERMINAL_STATES = ("succeeded", "failed", "timed_out")
is_terminal(status::AbstractString) = status in TERMINAL_STATES

"""
    Job

A single async solve request and its evolving state. Mutated only through a `JobStore`.
"""
mutable struct Job
    id::String
    problem::String
    data::Dict{String,Any}
    solve_opts::Dict{String,Any}
    status::String                          # queued | running | <terminal>
    result::Union{Nothing,Dict{String,Any}} # solution summary once finished
    error::Union{Nothing,String}
    submitted_at::DateTime
    started_at::Union{Nothing,DateTime}
    finished_at::Union{Nothing,DateTime}
end
Job(id, problem, data, solve_opts) =
    Job(id, problem, data, solve_opts, "queued", nothing, nothing, now(UTC), nothing, nothing)

_iso(::Nothing) = nothing
_iso(t::DateTime) = Dates.format(t, dateformat"yyyy-mm-ddTHH:MM:SS.sssZ")

"""
    job_to_response(job) -> Dict

JSON-ready view of a job for `GET /jobs/{id}`.
"""
function job_to_response(job::Job)
    out = Dict{String,Any}(
        "job_id" => job.id,
        "problem" => job.problem,
        "status" => job.status,
        "submitted_at" => _iso(job.submitted_at),
        "started_at" => _iso(job.started_at),
        "finished_at" => _iso(job.finished_at),
    )
    isnothing(job.result) || (out["result"] = job.result)
    isnothing(job.error) || (out["error"] = job.error)
    return out
end

# ---------------------------------------------------------------------------
# Store interface + in-memory implementation
# ---------------------------------------------------------------------------
abstract type JobStore end

"""
    LocalStore <: JobStore

Thread-safe in-process job store (Phase 1). The DynamoDB/S3-backed store arrives in
Phase 2 behind this same interface.
"""
struct LocalStore <: JobStore
    lock::ReentrantLock
    jobs::Dict{String,Job}
end
LocalStore() = LocalStore(ReentrantLock(), Dict{String,Job}())

save_job!(s::LocalStore, job::Job) = lock(() -> (s.jobs[job.id] = job; nothing), s.lock)
load_job(s::LocalStore, id::AbstractString) = lock(() -> get(s.jobs, id, nothing), s.lock)

"""
    update_job!(store, id; fields...) -> Union{Job,Nothing}

Atomically patches the named fields of job `id` (no-op + `nothing` if it's gone).
"""
function update_job!(s::LocalStore, id::AbstractString; fields...)
    lock(s.lock) do
        job = get(s.jobs, id, nothing)
        isnothing(job) && return nothing
        for (k, v) in fields
            setproperty!(job, k, v)
        end
        return job
    end
end

# ---------------------------------------------------------------------------
# Queue interface + in-memory implementation
# ---------------------------------------------------------------------------
abstract type JobQueue end

"""
    LocalQueue <: JobQueue

In-process FIFO of job ids backed by a `Channel` (Phase 1). The SQS adapter (Phase 2)
implements the same `enqueue!`/`dequeue` surface, plus ack/visibility for at-least-once.
"""
struct LocalQueue <: JobQueue
    ch::Channel{String}
end
LocalQueue(capacity::Int = 1024) = LocalQueue(Channel{String}(capacity))

enqueue!(q::LocalQueue, id::AbstractString) = (put!(q.ch, String(id)); nothing)
# Blocks until an id is available or the queue is closed (returns `nothing` when closed).
dequeue(q::LocalQueue) = try
    take!(q.ch)
catch err
    err isa InvalidStateException ? nothing : rethrow()
end
close_queue!(q::LocalQueue) = close(q.ch)

# ---------------------------------------------------------------------------
# Worker
# ---------------------------------------------------------------------------
"""
    process_job!(store, id; max_seconds=MAX_SOLVE_SECONDS)

Runs one job to a terminal state through the same validated solve path as `/solve`,
writing status/result back to `store`. Idempotent: a job already terminal is skipped
(handles at-least-once redelivery). Records metrics and a structured log line.
"""
function process_job!(store::JobStore, id::AbstractString; max_seconds::Real = MAX_SOLVE_SECONDS)
    job = load_job(store, id)
    isnothing(job) && return nothing
    is_terminal(job.status) && return job  # already done; ignore redelivery
    update_job!(store, id; status = "running", started_at = now(UTC))

    local status, logfields
    try
        experiment = JuLS.build_experiment(job.problem, job.data)
        limit, using_cp, seed, solve_echo = parse_solve(job.solve_opts)
        model = JuLS.init_model(experiment; using_cp = using_cp)
        rng = isnothing(seed) ? Random.MersenneTwister() : Random.MersenneTwister(seed)
        t0 = time()
        time_budget_exceeded = JuLS.optimize!(model; limit = limit, rng = rng, max_seconds = max_seconds)
        elapsed = time() - t0
        summary = summarize(experiment, id, job.problem, model, solve_echo, elapsed, time_budget_exceeded)
        status = time_budget_exceeded ? "timed_out" : "succeeded"
        update_job!(store, id; status, result = summary, finished_at = now(UTC))
        logfields = (
            iterations = summary["metrics"]["iterations"],
            feasible = summary["result"]["feasible"],
            time_budget_exceeded,
        )
    catch err
        status = "failed"
        message = err isa JuLS.InvalidInputError ? err.msg : "internal solver error"
        err isa JuLS.InvalidInputError || @error "job failed" job_id = id problem = job.problem exception =
            (err, catch_backtrace())
        update_job!(store, id; status, error = message, finished_at = now(UTC))
        logfields = (error = message,)
    end

    record_job!(status)
    log_json(status == "failed" ? "error" : "info", "job"; job_id = id, problem = job.problem, status, logfields...)
    return load_job(store, id)
end

"""
    run_worker(queue, store; max_seconds=MAX_SOLVE_SECONDS)

Blocking worker loop: pulls job ids off `queue` and processes them until the queue is
closed. Spawn several of these for concurrency (see `start_server`).
"""
function run_worker(queue::JobQueue, store::JobStore; max_seconds::Real = MAX_SOLVE_SECONDS)
    while true
        id = dequeue(queue)
        isnothing(id) && break  # queue closed
        try
            process_job!(store, id; max_seconds)
        catch err
            @error "worker loop error" job_id = id exception = (err, catch_backtrace())
        end
    end
    return nothing
end
