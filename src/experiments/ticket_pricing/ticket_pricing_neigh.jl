# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

"""
    TicketTransferNeighbourhood <: NeighbourhoodHeuristic

Neighbourhood for the ticket pricing problem. Since any move changing the total
number of allocated tickets is infeasible (the full-allocation constraint Σ x_j = N
must hold), all generated moves preserve the allocation sum:

1. Transfer moves: move k tickets from retailer a to retailer b, for every ordered
   pair (a, b) and every k in `transfer_sizes`.
2. Tier moves: change the price tier of one retailer to any other tier.
3. Combined moves: a tier change for one retailer together with a ticket transfer
   involving that retailer, allowing price and volume to be adjusted jointly
   (escaping local optima where neither change improves alone).

# Fields
- `n_retailers::Int`: Number of retailers M
- `n_tiers::Int`: Number of price tiers T
- `transfer_sizes::Vector{Int}`: Ticket batch sizes used for transfer moves
"""
struct TicketTransferNeighbourhood <: NeighbourhoodHeuristic
    n_retailers::Int
    n_tiers::Int
    transfer_sizes::Vector{Int}
end
TicketTransferNeighbourhood(e::TicketPricingExperiment, transfer_sizes::Vector{Int} = [1, 5, 10, 25, 50]) =
    TicketTransferNeighbourhood(e.n_retailers, length(e.price_tiers), transfer_sizes)

_allocation_value(model::AbstractModel, j::Int) = current_value(decision_variables(model)[j]).value
_tier_variable(model::AbstractModel, h::TicketTransferNeighbourhood, j::Int) =
    decision_variables(model)[h.n_retailers+j]

function _transfer_move(model::AbstractModel, a::Int, b::Int, k::Int)
    variables = decision_variables(model)[[a, b]]
    new_values = [IntDecisionValue(_allocation_value(model, a) - k), IntDecisionValue(_allocation_value(model, b) + k)]
    return Move(variables, new_values)
end

function get_neighbourhood(h::TicketTransferNeighbourhood, model::AbstractModel; rng = Random.GLOBAL_RNG)
    moves = [NO_MOVE]

    for a = 1:h.n_retailers, b = 1:h.n_retailers
        a == b && continue
        for k in h.transfer_sizes
            _allocation_value(model, a) - k >= 0 || continue
            push!(moves, _transfer_move(model, a, b, k))
        end
    end

    for j = 1:h.n_retailers
        tier_var = _tier_variable(model, h, j)
        current_tier = current_value(tier_var).value
        for t = 1:h.n_tiers
            t == current_tier && continue
            tier_move = Move([tier_var], [IntDecisionValue(t)])
            push!(moves, tier_move)

            # Combined moves: change retailer j's tier while moving tickets in or out
            for other = 1:h.n_retailers
                other == j && continue
                for k in h.transfer_sizes
                    if _allocation_value(model, other) - k >= 0
                        push!(moves, _transfer_move(model, other, j, k) * tier_move)
                    end
                    if _allocation_value(model, j) - k >= 0
                        push!(moves, _transfer_move(model, j, other, k) * tier_move)
                    end
                end
            end
        end
    end

    return moves
end

@testitem "get_neighbourhood(::TicketTransferNeighbourhood)" begin
    e = JuLS.load_sample("ticket_pricing", "hard")
    model = JuLS.init_model(e)

    moves = JuLS.get_neighbourhood(JuLS.TicketTransferNeighbourhood(e, [10]), model)

    @test moves[1] == JuLS.NO_MOVE

    # All moves must preserve the total allocation over allocation variables (1..3)
    for move in moves[2:end]
        delta_sum = 0
        for (var, new_value) in zip(move.variables, move.new_values)
            if var.index <= 3
                delta_sum += new_value.value - JuLS.current_value(model.decision_variables[var.index]).value
            end
        end
        @test delta_sum == 0
    end

    # Transfer moves: 6 ordered pairs x 1 size. Tier moves: 3 retailers x 8 tiers.
    # Combined moves: 3 x 8 x 2 directions x 2 other retailers x 1 size.
    @test length(moves) == 1 + 6 + 24 + 96
end
