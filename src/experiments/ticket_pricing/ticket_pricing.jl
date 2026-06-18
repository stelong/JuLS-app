# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

"""
    TicketPricingExperiment <: Experiment

Represents a dynamic pricing and allocation problem for event tickets sold through
third-party retailers.

An event organizer holds `n_tickets` tickets and must allocate all of them across
`n_retailers` sales channels, while choosing for each channel a price from a shared
grid of `price_tiers`. Each retailer charges a commission (percentage of the ticket
price) and a fixed fee per ticket sold, and faces its own price-dependent demand.
Tickets allocated beyond a retailer's demand at the chosen price remain unsold.

The objective is to maximize the total margin:

    margin = Σ_j unit_margin_j(t_j) * min(x_j, demand_j(t_j))

where `unit_margin_j(t) = price_t * (1 - commission_j) - fixed_fee_j`, `x_j` is the
allocation and `t_j` the price tier chosen for retailer j.

# Fields
- `input_file::String`: Path to file containing problem data
- `α::Float64`: Penalty parameter for constraint violation
- `n_retailers::Int`: Number of retailers (M)
- `n_tickets::Int`: Total number of tickets to allocate (N)
- `price_tiers::Vector{Float64}`: Available prices (shared grid of T tiers)
- `retailer_names::Vector{String}`: Display name of each retailer
- `commissions::Vector{Float64}`: Commission rate of each retailer (in [0, 1))
- `fixed_fees::Vector{Float64}`: Fixed fee per ticket sold for each retailer
- `demands::Matrix{Int}`: `demands[j, t]` is retailer j's demand at price tier t

# File Format
Expected input file format:

n_retailers n_tickets n_tiers
price_1 price_2 ... price_T
name_1 commission_1 fixed_fee_1 demand_1_1 ... demand_1_T
...
name_M commission_M fixed_fee_M demand_M_1 ... demand_M_T

# Decision Variables
2M integer variables: variables 1..M are the allocations x_j ∈ {0, ..., N},
variables M+1..2M are the price tier indexes t_j ∈ {1, ..., T}.
"""
struct TicketPricingExperiment <: Experiment
    input_file::String
    α::Float64
    n_retailers::Int
    n_tickets::Int
    price_tiers::Vector{Float64}
    retailer_names::Vector{String}
    commissions::Vector{Float64}
    fixed_fees::Vector{Float64}
    demands::Matrix{Int}

    TicketPricingExperiment(input_file::String, α::Float64 = DEFAULT_PENALTY_PARAM) =
        open(input_file, "r") do f
            lines = readlines(f)
            n_retailers, n_tickets, n_tiers = parse.(Int, split(lines[1]))
            price_tiers = parse.(Float64, split(lines[2]))
            @assert length(price_tiers) == n_tiers "The price grid must contain n_tiers prices"
            names = Vector{String}(undef, n_retailers)
            commissions, fixed_fees = zeros(n_retailers), zeros(n_retailers)
            demands = zeros(Int, n_retailers, n_tiers)
            for j = 1:n_retailers
                fields = split(lines[j+2])
                names[j] = fields[1]
                commissions[j] = parse(Float64, fields[2])
                fixed_fees[j] = parse(Float64, fields[3])
                demands[j, :] = parse.(Int, fields[4:end])
            end
            return new(input_file, α, n_retailers, n_tickets, price_tiers, names, commissions, fixed_fees, demands)
        end
end

"""
    n_decision_variables(e::TicketPricingExperiment)

Two decision variables per retailer: its ticket allocation and its price tier.
"""
n_decision_variables(e::TicketPricingExperiment) = 2 * e.n_retailers

"""
    decision_type(::TicketPricingExperiment)

Allocations and price tier indexes are both integers.
"""
decision_type(::TicketPricingExperiment) = IntDecisionValue

"""
    generate_domains(e::TicketPricingExperiment)

Allocation variables range over {0, ..., N}, tier variables over {1, ..., T}.
"""
generate_domains(e::TicketPricingExperiment) = vcat(
    [collect(0:e.n_tickets) for _ = 1:e.n_retailers],
    [collect(1:length(e.price_tiers)) for _ = 1:e.n_retailers],
)

allocation_index(::TicketPricingExperiment, j::Int) = j
tier_index(e::TicketPricingExperiment, j::Int) = e.n_retailers + j

"""
    unit_margin(e::TicketPricingExperiment, j::Int, tier::Int)

Net margin the organizer makes on one ticket sold through retailer j at the given
price tier: `price * (1 - commission_j) - fixed_fee_j`.
"""
unit_margin(e::TicketPricingExperiment, j::Int, tier::Int) =
    e.price_tiers[tier] * (1 - e.commissions[j]) - e.fixed_fees[j]

include("ticket_pricing_dag.jl")
include("ticket_pricing_init.jl")
include("ticket_pricing_neigh.jl")

default_init(::TicketPricingExperiment) = SimpleInitialization()
default_neigh(e::TicketPricingExperiment) = TicketTransferNeighbourhood(e)
default_pick(::TicketPricingExperiment) = GreedyMoveSelection()
default_using_cp(::TicketPricingExperiment) = false
create_dag(e::TicketPricingExperiment) = create_ticket_pricing_dag(e)

@testitem "TicketPricingExperiment initialization" begin
    e = JuLS.TicketPricingExperiment(JuLS.PROJECT_ROOT * "/data/ticket_pricing/tp_3_300")

    @test e.n_retailers == 3
    @test e.n_tickets == 300
    @test e.price_tiers == collect(40.0:5.0:80.0)
    @test e.retailer_names == ["MegaTickets", "PrimeSeats", "BudgetTix"]
    @test e.commissions == [0.15, 0.25, 0.1]
    @test e.fixed_fees == [0.5, 1.0, 0.25]
    @test e.demands[1, 1] == 320
    @test e.demands[3, 9] == 6
    @test e.α == JuLS.DEFAULT_PENALTY_PARAM

    @test JuLS.n_decision_variables(e) == 6
    @test JuLS.decision_type(e) == JuLS.IntDecisionValue

    domains = JuLS.generate_domains(e)
    @test length(domains) == 6
    @test domains[1] == collect(0:300)
    @test domains[4] == collect(1:9)

    # unit_margin = price * (1 - commission) - fixed_fee
    @test JuLS.unit_margin(e, 1, 1) ≈ 40 * 0.85 - 0.5
    @test JuLS.unit_margin(e, 3, 9) ≈ 80 * 0.9 - 0.25
end
