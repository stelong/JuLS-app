# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

abstract type Limit end

struct IterationLimit <: Limit
    n_iterations::Int
end

"""
    StagnationLimit <: Limit

Early stopping criterion: the optimization stops once the best feasible objective
has not improved for `patience` consecutive iterations, or after `max_iterations`
iterations, whichever comes first.

# Fields
- `patience::Int`: Number of consecutive non-improving iterations tolerated before stopping
- `max_iterations::Int`: Safety cap on the total number of iterations
"""
struct StagnationLimit <: Limit
    patience::Int
    max_iterations::Int
end
StagnationLimit(patience::Int = 50; max_iterations::Int = 10_000) = StagnationLimit(patience, max_iterations)

"""
    Limit(limit)

Normalizes the `limit` keyword of `optimize!`:
- a `Limit` object is passed through unchanged;
- an integer `n` becomes `IterationLimit(n)`;
- the flag `:auto` becomes `StagnationLimit()` (early stopping with default patience).
"""
Limit(limit::Limit) = limit
Limit(n_iterations::Int) = IterationLimit(n_iterations)
function Limit(flag::Symbol)
    flag == :auto && return StagnationLimit()
    error("Unknown limit flag :$flag. Use an integer, :auto or a Limit object.")
end

mutable struct TimeLimit <: Limit
    start_time::Float64
    limit::Float64
end
TimeLimit() = TimeLimit(0, typemax(Float64))
TimeLimit(limit::Number) = TimeLimit(0, limit)

init!(time_limit::TimeLimit, limit::Number) = time_limit.limit = limit
start!(time_limit::TimeLimit) = time_limit.start_time = time()
is_above(time_limit::TimeLimit) = time() - time_limit.start_time > time_limit.limit


@testitem "Limit normalization" begin
    @test JuLS.Limit(JuLS.TimeLimit(5)) isa JuLS.TimeLimit
    @test JuLS.Limit(100) == JuLS.IterationLimit(100)
    @test JuLS.Limit(:auto) == JuLS.StagnationLimit()
    @test JuLS.Limit(:auto).patience == 50
    @test JuLS.Limit(:auto).max_iterations == 10_000
    @test JuLS.StagnationLimit(20; max_iterations = 500) == JuLS.StagnationLimit(20, 500)
    @test_throws ErrorException JuLS.Limit(:fast)
end

@testitem "TimeLimit" begin
    time_limit = JuLS.TimeLimit()
    JuLS.init!(time_limit, 0.1)
    JuLS.start!(time_limit)
    @test !JuLS.is_above(time_limit)
    sleep(0.1)
    @test JuLS.is_above(time_limit)
end

