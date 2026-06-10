# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

"""
    solution_summary(e::TicketPricingExperiment, solution::Solution)

Extracts the business quantities of a solution: per retailer the allocation,
chosen price, demand at that price, expected sales and margin contribution.

# Returns
A NamedTuple (allocations, tiers, prices, demands, sales, margins, total_margin).
"""
function solution_summary(e::TicketPricingExperiment, solution::Solution)
    vals = [v.value for v in values(solution)]
    allocations = vals[1:e.n_retailers]
    tiers = vals[e.n_retailers+1:2*e.n_retailers]
    prices = [e.price_tiers[t] for t in tiers]
    demands = [e.demands[j, tiers[j]] for j = 1:e.n_retailers]
    sales = min.(allocations, demands)
    margins = [unit_margin(e, j, tiers[j]) * sales[j] for j = 1:e.n_retailers]
    return (; allocations, tiers, prices, demands, sales, margins, total_margin = sum(margins))
end

"""
    plot_solution(e::TicketPricingExperiment, solution::Solution)

Plots the ticket allocation defined by `solution`. The left axis shows, per
retailer, the allocated tickets, the demand at the chosen price and the expected
sales; the chosen price is annotated above each group. The right axis shows the
margin contribution of each retailer.

# Returns
A CairoMakie Figure.
"""
function plot_solution(e::TicketPricingExperiment, solution::Solution)
    s = solution_summary(e, solution)
    js = 1:e.n_retailers

    fig = Figure(size = (950, 420))
    ax_alloc = Axis(
        fig[1, 1],
        title = "Allocation & demand - $(e.n_tickets) tickets, total margin = $(round(s.total_margin, digits = 2))",
        xticks = (js, e.retailer_names),
        ylabel = "tickets",
    )

    barplot!(ax_alloc, js .- 0.2, Float64.(s.allocations), width = 0.35, color = :steelblue, label = "allocated")
    barplot!(ax_alloc, js .+ 0.2, Float64.(s.demands), width = 0.35, color = (:orange, 0.8), label = "demand at price")
    scatter!(ax_alloc, js .- 0.2, Float64.(s.sales), color = :black, marker = :hline, markersize = 20, label = "expected sales")
    text!(
        ax_alloc,
        Float64.(js),
        max.(Float64.(s.allocations), Float64.(s.demands)),
        text = ["price = $(p)" for p in s.prices],
        align = (:center, :bottom),
        offset = (0, 6),
        fontsize = 12,
    )
    ylims!(ax_alloc, 0, 1.25 * max(maximum(s.allocations), maximum(s.demands)))
    axislegend(ax_alloc)

    ax_margin = Axis(
        fig[1, 2],
        title = "Margin contribution",
        xticks = (js, e.retailer_names),
        ylabel = "margin",
    )
    barplot!(ax_margin, js, Float64.(s.margins), color = :seagreen)
    text!(
        ax_margin,
        Float64.(js),
        Float64.(s.margins),
        text = string.(round.(s.margins, digits = 1)),
        align = (:center, :bottom),
        offset = (0, 4),
        fontsize = 12,
    )
    ylims!(ax_margin, 0, 1.15 * maximum(s.margins))

    return fig
end

@testitem "plot_solution(::TicketPricingExperiment)" begin
    e = JuLS.TicketPricingExperiment(JuLS.PROJECT_ROOT * "/data/ticket_pricing/tp_3_300")
    model = JuLS.init_model(e)
    JuLS.optimize!(model; limit = JuLS.IterationLimit(10))

    s = JuLS.solution_summary(e, model.best_solution)
    @test sum(s.allocations) == e.n_tickets
    @test s.total_margin ≈ -model.best_solution.objective
    @test all(s.sales .== min.(s.allocations, s.demands))

    fig = JuLS.plot_solution(e, model)
    @test fig isa JuLS.CairoMakie.Figure
end
