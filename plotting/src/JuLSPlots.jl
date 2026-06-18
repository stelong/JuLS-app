# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

"""
    JuLSPlots

Plotting companion for the JuLS solver. This is a separate, local-only Julia
environment so that CairoMakie (and its heavy dependency tree) stays out of the
deployable JuLS image. The functions here are the reference for what a solution
"looks like" — API clients are expected to plot the JSON response themselves.

Usage from the repo root:

    julia --project=plotting -e 'using Pkg; Pkg.instantiate()'
    julia --project=plotting

then in the REPL:

    using JuLS, JuLSPlots
    e = KnapsackExperiment(JuLS.PROJECT_ROOT * "/data/knapsack/ks_4_0")
    model = init_model(e); optimize!(model; limit = IterationLimit(50))
    save("knapsack.png", plot_solution(e, model))
"""
module JuLSPlots

using JuLS
using CairoMakie

export plot_solution, plot_objective

"""
    plot_solution(e::Experiment, model)

Plots the best feasible solution found by the model for the given experiment.
Falls back to the current solution (with a warning) if no feasible solution was found.

Each experiment implements `plot_solution(e::YourExperiment, solution::JuLS.Solution)`
returning a CairoMakie `Figure`.
"""
function plot_solution(e::JuLS.Experiment, model::JuLS.AbstractModel)
    solution = model.best_solution
    if isnothing(solution)
        @warn "No feasible solution was found, plotting the current solution instead."
        solution = model.current_solution
    end
    return plot_solution(e, solution)
end
plot_solution(::JuLS.Experiment, ::JuLS.Solution) =
    error("You must implement the function plot_solution() for your experiment.")

"""
    plot_objective(m::JuLS.RunMetrics)

Creates a plot showing the evolution of the objective function and best solutions.
Returns a CairoMakie `Figure`.
"""
function plot_objective(m::JuLS.RunMetrics)
    best_solutions = JuLS.best_solution_indexes(m)

    fig = Figure()
    ax = Axis(fig[1, 1], xlabel = "iteration", ylabel = "objective")
    lines!(ax, 1:m.current_iteration, m.objective[1:m.current_iteration], label = "objective")
    scatter!(ax, best_solutions, m.objective[best_solutions], color = :crimson, label = "best solutions")
    axislegend(ax)

    return fig
end

# ---------------------------------------------------------------------------
# Knapsack
# ---------------------------------------------------------------------------
function plot_solution(e::KnapsackExperiment, solution::JuLS.Solution)
    is_selected = [v.value for v in JuLS.values(solution)]
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

# ---------------------------------------------------------------------------
# TSP
# ---------------------------------------------------------------------------
"""
    read_coordinates(e::TSPExperiment)

Reads the city coordinates from the experiment's input file. Returns an
n_nodes x 2 matrix where row i contains the (x, y) coordinates of city i.
"""
read_coordinates(e::TSPExperiment) =
    open(e.input_file, "r") do f
        lines = readlines(f)[2:end]
        n = length(lines)
        coordinates = Array{Float64}(undef, (n, 2))
        for i = 1:n
            coordinates[i, :] = parse.(Float64, split(lines[i]))
        end
        return coordinates
    end

"""
    tour_order(solution::JuLS.Solution)

Returns the sequence of city indexes ordered by their position in the tour.
"""
tour_order(solution::JuLS.Solution) = sortperm([v.value for v in JuLS.values(solution)])

function plot_solution(e::TSPExperiment, solution::JuLS.Solution)
    coordinates = read_coordinates(e)
    order = tour_order(solution)

    closed_tour = vcat(order, order[1])
    tour_length = sum(e.distance_matrix[closed_tour[k], closed_tour[k+1]] for k = 1:e.n_nodes)

    fig = Figure()
    ax = Axis(
        fig[1, 1],
        title = "TSP tour - $(e.n_nodes) cities, tour length = $tour_length",
        xlabel = "x",
        ylabel = "y",
    )

    scatterlines!(
        ax,
        coordinates[closed_tour, 1],
        coordinates[closed_tour, 2],
        color = :steelblue,
        markercolor = :black,
        markersize = 8,
    )
    scatter!(
        ax,
        [coordinates[order[1], 1]],
        [coordinates[order[1], 2]],
        color = :crimson,
        markersize = 14,
        label = "start city",
    )
    axislegend(ax)

    return fig
end

# ---------------------------------------------------------------------------
# Graph coloring
# ---------------------------------------------------------------------------
function plot_solution(e::GraphColoringExperiment, solution::JuLS.Solution)
    node_colors = [v.value for v in JuLS.values(solution)]
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

# ---------------------------------------------------------------------------
# Ticket pricing
# ---------------------------------------------------------------------------
"""
    solution_summary(e::TicketPricingExperiment, solution::JuLS.Solution)

Extracts the business quantities of a solution: per retailer the allocation,
chosen price, demand at that price, expected sales and margin contribution.
Returns a NamedTuple (allocations, tiers, prices, demands, sales, margins, total_margin).
"""
function solution_summary(e::TicketPricingExperiment, solution::JuLS.Solution)
    vals = [v.value for v in JuLS.values(solution)]
    allocations = vals[1:e.n_retailers]
    tiers = vals[e.n_retailers+1:2*e.n_retailers]
    prices = [e.price_tiers[t] for t in tiers]
    demands = [e.demands[j, tiers[j]] for j = 1:e.n_retailers]
    sales = min.(allocations, demands)
    margins = [JuLS.unit_margin(e, j, tiers[j]) * sales[j] for j = 1:e.n_retailers]
    return (; allocations, tiers, prices, demands, sales, margins, total_margin = sum(margins))
end

function plot_solution(e::TicketPricingExperiment, solution::JuLS.Solution)
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

end # module JuLSPlots
