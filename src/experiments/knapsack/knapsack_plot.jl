# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

"""
    plot_solution(e::KnapsackExperiment, solution::Solution)

Plots the item selection defined by `solution` for the knapsack instance.
The top axis shows the value of each item, the bottom axis its weight, with
selected items highlighted. The capacity usage is displayed in the title.

# Returns
A CairoMakie Figure.
"""
function plot_solution(e::KnapsackExperiment, solution::Solution)
    is_selected = [v.value for v in values(solution)]
    total_value = sum(e.values[is_selected])
    total_weight = sum(e.weights[is_selected])

    bar_colors = [selected ? :seagreen : (:gray, 0.4) for selected in is_selected]

    fig = Figure()
    ax_values = Axis(
        fig[1, 1],
        title = "Knapsack - total value = $total_value, weight = $total_weight / $(e.capacity)",
        ylabel = "value",
    )
    ax_weights = Axis(fig[2, 1], xlabel = "item", ylabel = "weight")

    barplot!(ax_values, 1:e.n_items, e.values, color = bar_colors)
    barplot!(ax_weights, 1:e.n_items, e.weights, color = bar_colors)

    Legend(
        fig[1, 1],
        [PolyElement(color = :seagreen), PolyElement(color = (:gray, 0.4))],
        ["selected", "not selected"],
        tellwidth = false,
        tellheight = false,
        halign = :right,
        valign = :top,
        margin = (5, 5, 5, 5),
    )

    return fig
end

@testitem "plot_solution(::KnapsackExperiment)" begin
    e = JuLS.KnapsackExperiment(JuLS.PROJECT_ROOT * "/data/knapsack/ks_4_0", 10.0)
    model = JuLS.init_model(e)
    JuLS.optimize!(model; limit = JuLS.IterationLimit(5))

    fig = JuLS.plot_solution(e, model)
    @test fig isa JuLS.CairoMakie.Figure
end
