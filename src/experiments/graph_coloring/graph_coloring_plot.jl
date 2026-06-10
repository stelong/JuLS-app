# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

"""
    plot_solution(e::GraphColoringExperiment, solution::Solution)

Plots the coloring defined by `solution` for the graph coloring instance.
Nodes are laid out on a circle and colored according to their assigned color.
Edges connecting two nodes with the same color (conflicts) are drawn in red.

# Returns
A CairoMakie Figure.
"""
function plot_solution(e::GraphColoringExperiment, solution::Solution)
    node_colors = [v.value for v in values(solution)]
    n_colors_used = length(unique(node_colors))
    conflicts = [(i, j) for (i, j) in e.edges if node_colors[i] == node_colors[j]]

    # Circular node layout
    angles = [2π * (i - 1) / e.n_nodes for i = 1:e.n_nodes]
    node_x = cos.(angles)
    node_y = sin.(angles)

    palette = get(cgrad(:rainbow), e.max_color == 1 ? [0.0] : range(0, 1, length = e.max_color))

    fig = Figure()
    ax = Axis(
        fig[1, 1],
        title = "Graph coloring - $n_colors_used colors used, $(length(conflicts)) conflicts",
        aspect = DataAspect(),
    )
    hidedecorations!(ax)
    hidespines!(ax)

    valid_edges = setdiff(e.edges, conflicts)
    edge_segments(edges) = [(Point2f(node_x[i], node_y[i]), Point2f(node_x[j], node_y[j])) for (i, j) in edges]
    if !isempty(valid_edges)
        linesegments!(ax, edge_segments(valid_edges), color = (:gray, 0.6))
    end
    if !isempty(conflicts)
        linesegments!(ax, edge_segments(conflicts), color = :red, linewidth = 3, label = "conflict")
        axislegend(ax)
    end

    scatter!(ax, node_x, node_y, color = palette[node_colors], markersize = 25, strokewidth = 1)
    text!(
        ax,
        node_x,
        node_y,
        text = string.(1:e.n_nodes),
        align = (:center, :center),
        fontsize = 10,
        color = :white,
    )

    return fig
end

@testitem "plot_solution(::GraphColoringExperiment)" begin
    e = JuLS.GraphColoringExperiment(JuLS.PROJECT_ROOT * "/data/graph_coloring/gc_4_1", 4)
    model = JuLS.init_model(e; init = JuLS.SimpleInitialization())
    JuLS.optimize!(model; limit = JuLS.IterationLimit(5))

    fig = JuLS.plot_solution(e, model)
    @test fig isa JuLS.CairoMakie.Figure
end
