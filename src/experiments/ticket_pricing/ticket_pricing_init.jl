# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

"""
    (::SimpleInitialization)(e::TicketPricingExperiment)

Initial solution for the ticket pricing problem: tickets are split evenly across
retailers (the remainder going to the first ones, so that Σ x_j = N holds and the
solution is feasible from the start) and every retailer starts at the middle price
tier.
"""
function (::SimpleInitialization)(e::TicketPricingExperiment)
    base, remainder = divrem(e.n_tickets, e.n_retailers)
    allocations = [base + (j <= remainder ? 1 : 0) for j = 1:e.n_retailers]
    tiers = fill((length(e.price_tiers) + 1) ÷ 2, e.n_retailers)
    return vcat(allocations, tiers)
end

@testitem "SimpleInitialization(::TicketPricingExperiment)" begin
    e = JuLS.TicketPricingExperiment(JuLS.PROJECT_ROOT * "/data/ticket_pricing/tp_3_300")
    init_solution = JuLS.SimpleInitialization()(e)

    @test length(init_solution) == 6
    @test init_solution[1:3] == [100, 100, 100]
    @test sum(init_solution[1:3]) == e.n_tickets
    @test init_solution[4:6] == [5, 5, 5]
end
