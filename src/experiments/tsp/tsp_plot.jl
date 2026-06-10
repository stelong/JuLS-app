# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

"""
    read_coordinates(e::TSPExperiment)

Reads the city coordinates from the experiment's input file.

# Returns
A n_nodes x 2 matrix where row i contains the (x, y) coordinates of city i.
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
    tour_order(solution::Solution)

Returns the sequence of city indexes ordered by their position in the tour.
"""
tour_order(solution::Solution) = sortperm([v.value for v in values(solution)])

"""
    plot_solution(e::TSPExperiment, solution::Solution)

Plots the tour defined by `solution` over the city coordinates of the TSP instance.
Cities are drawn at their coordinates, connected by the closed tour. The starting
city (position 1 in the tour) is highlighted.

# Returns
A CairoMakie Figure.
"""
function plot_solution(e::TSPExperiment, solution::Solution)
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

@testitem "plot_solution(::TSPExperiment)" begin
    e = JuLS.TSPExperiment(JuLS.PROJECT_ROOT * "/data/tsp/tsp_5_1")
    model = JuLS.init_model(e)
    JuLS.optimize!(model; limit = JuLS.IterationLimit(5))

    coordinates = JuLS.read_coordinates(e)
    @test size(coordinates) == (5, 2)
    @test coordinates[4, :] == [3.0, 1.0]

    fig = JuLS.plot_solution(e, model)
    @test fig isa JuLS.CairoMakie.Figure
end
