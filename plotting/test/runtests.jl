# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

using Test
using JuLS
using JuLSPlots
using CairoMakie

@testset "JuLSPlots" begin
    @testset "knapsack" begin
        e = JuLS.KnapsackExperiment(JuLS.PROJECT_ROOT * "/data/knapsack/ks_4_0", 10.0)
        model = JuLS.init_model(e)
        JuLS.optimize!(model; limit = JuLS.IterationLimit(5))

        fig = JuLSPlots.plot_solution(e, model)
        @test fig isa CairoMakie.Figure
    end

    @testset "tsp" begin
        e = JuLS.TSPExperiment(JuLS.PROJECT_ROOT * "/data/tsp/tsp_5_1")
        model = JuLS.init_model(e)
        JuLS.optimize!(model; limit = JuLS.IterationLimit(5))

        coordinates = JuLSPlots.read_coordinates(e)
        @test size(coordinates) == (5, 2)
        @test coordinates[4, :] == [3.0, 1.0]

        fig = JuLSPlots.plot_solution(e, model)
        @test fig isa CairoMakie.Figure
    end

    @testset "graph coloring" begin
        e = JuLS.GraphColoringExperiment(JuLS.PROJECT_ROOT * "/data/graph_coloring/gc_4_1", 4)
        model = JuLS.init_model(e; init = JuLS.SimpleInitialization())
        JuLS.optimize!(model; limit = JuLS.IterationLimit(5))

        fig = JuLSPlots.plot_solution(e, model)
        @test fig isa CairoMakie.Figure
    end

    @testset "ticket pricing" begin
        e = JuLS.TicketPricingExperiment(JuLS.PROJECT_ROOT * "/data/ticket_pricing/tp_3_300")
        model = JuLS.init_model(e)
        JuLS.optimize!(model; limit = JuLS.IterationLimit(10))

        s = JuLSPlots.solution_summary(e, model.best_solution)
        @test sum(s.allocations) == e.n_tickets
        @test s.total_margin ≈ -model.best_solution.objective
        @test all(s.sales .== min.(s.allocations, s.demands))

        fig = JuLSPlots.plot_solution(e, model)
        @test fig isa CairoMakie.Figure
    end

    @testset "objective" begin
        metrics = JuLS.RunMetrics(JuLS.Solution([], 10, false))
        JuLS.resize_metrics!(metrics, 10)
        JuLS.record_solution!(metrics, JuLS.Solution([], 12, true))
        JuLS.record_solution!(metrics, JuLS.Solution([], 8, true))

        fig = JuLSPlots.plot_objective(metrics)
        @test fig isa CairoMakie.Figure
    end
end
