# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

"""
    RetailerMarginInvariant <: Invariant

Black-box invariant computing (the negation of) the margin obtained from a single
retailer, as a function of its two parent decision variables: the ticket allocation
x and the price tier t.

y = -(unit_margins[t] * min(x, demands[t]))

The negation makes the DAG objective a minimization target, consistent with the
other experiments. The min(x, demand) coupling between the two variables is what
makes this invariant a black box: it is not expressible with the generic CP
invariants and is evaluated through CBLS propagation only.

# Fields
- `alloc_index::Int`: Global index of the allocation decision variable x
- `tier_index::Int`: Global index of the price tier decision variable t
- `unit_margins::Vector{Float64}`: Net margin per ticket sold at each price tier
- `demands::Vector{Int}`: Retailer demand at each price tier
- `current_alloc::Int`: State, current value of x
- `current_tier::Int`: State, current value of t
"""
mutable struct RetailerMarginInvariant <: Invariant
    alloc_index::Int
    tier_index::Int
    unit_margins::Vector{Float64}
    demands::Vector{Int}
    current_alloc::Int
    current_tier::Int
end
RetailerMarginInvariant(alloc_index::Int, tier_index::Int, unit_margins::Vector{Float64}, demands::Vector{Int}) =
    RetailerMarginInvariant(alloc_index, tier_index, unit_margins, demands, 0, 1)

_retailer_margin(invariant::RetailerMarginInvariant, alloc::Int, tier::Int) =
    -invariant.unit_margins[tier] * min(alloc, invariant.demands[tier])

function _new_alloc_and_tier(
    invariant::RetailerMarginInvariant,
    deltas::DAGMessagesVector{SingleVariableMoveDelta{IntDecisionValue}},
)
    new_alloc, new_tier = invariant.current_alloc, invariant.current_tier
    for δ in deltas
        if δ.index == invariant.alloc_index
            new_alloc = δ.new_value.value
        elseif δ.index == invariant.tier_index
            new_tier = δ.new_value.value
        end
    end
    return new_alloc, new_tier
end

evaluate(invariant::RetailerMarginInvariant, deltas::DAGMessagesVector{SingleVariableMoveDelta{IntDecisionValue}}) =
    FloatDelta(
        _retailer_margin(invariant, _new_alloc_and_tier(invariant, deltas)...) -
        _retailer_margin(invariant, invariant.current_alloc, invariant.current_tier),
    )

function evaluate(
    invariant::RetailerMarginInvariant,
    messages::DAGMessagesVector{SingleVariableMessage{IntDecisionValue}},
)
    alloc, tier = 0, 1
    for m in messages
        if m.index == invariant.alloc_index
            alloc = m.value.value
        elseif m.index == invariant.tier_index
            tier = m.value.value
        end
    end
    return FloatFullMessage(_retailer_margin(invariant, alloc, tier))
end

function commit!(
    invariant::RetailerMarginInvariant,
    deltas::DAGMessagesVector{SingleVariableMoveDelta{IntDecisionValue}},
)
    invariant.current_alloc, invariant.current_tier = _new_alloc_and_tier(invariant, deltas)
end

function init!(
    invariant::RetailerMarginInvariant,
    messages::DAGMessagesVector{SingleVariableMessage{IntDecisionValue}},
)
    for m in messages
        if m.index == invariant.alloc_index
            invariant.current_alloc = m.value.value
        elseif m.index == invariant.tier_index
            invariant.current_tier = m.value.value
        end
    end
    return evaluate(invariant, messages)
end

"""
    AllocationBudgetInvariant <: Invariant

Invariant representing the violation of the full-allocation business constraint:
all N tickets must be distributed across the retailers.

y = |Σ x_j - N|

# Fields
- `n_tickets::Int`: Total number of tickets N
- `current_sum::Int`: State, current value of Σ x_j
"""
mutable struct AllocationBudgetInvariant <: Invariant
    n_tickets::Int
    current_sum::Int
end
AllocationBudgetInvariant(n_tickets::Int) = AllocationBudgetInvariant(n_tickets, 0)

function evaluate(
    invariant::AllocationBudgetInvariant,
    deltas::DAGMessagesVector{SingleVariableMoveDelta{IntDecisionValue}},
)
    new_sum = invariant.current_sum + sum(δ.new_value.value - δ.current_value.value for δ in deltas)
    return FloatDelta(abs(new_sum - invariant.n_tickets) - abs(invariant.current_sum - invariant.n_tickets))
end

evaluate(invariant::AllocationBudgetInvariant, messages::DAGMessagesVector{SingleVariableMessage{IntDecisionValue}}) =
    FloatFullMessage(abs(sum(m.value.value for m in messages) - invariant.n_tickets))

function commit!(
    invariant::AllocationBudgetInvariant,
    deltas::DAGMessagesVector{SingleVariableMoveDelta{IntDecisionValue}},
)
    invariant.current_sum += sum(δ.new_value.value - δ.current_value.value for δ in deltas)
end

function init!(
    invariant::AllocationBudgetInvariant,
    messages::DAGMessagesVector{SingleVariableMessage{IntDecisionValue}},
)
    invariant.current_sum = sum(m.value.value for m in messages)
    return evaluate(invariant, messages)
end

"""
    create_ticket_pricing_dag(e::TicketPricingExperiment)

Creates the invariant DAG for the ticket pricing problem.

# DAG Structure
1. Margin per retailer:
   - One RetailerMarginInvariant per retailer with parents (x_j, t_j)
2. Objective Function:
   - ObjectiveInvariant summing all (negated) retailer margins
3. Full Allocation Constraint:
   - AllocationBudgetInvariant over all allocation variables, violation |Σ x_j - N|
4. Penalty for Constraint Violation:
   - StaticConstraintInvariant applying penalty α for violations
5. Final Aggregator:
   - Combines objective and penalized constraint
"""
function create_ticket_pricing_dag(e::TicketPricingExperiment)
    dag = DAG(n_decision_variables(e))

    margin_nodes = zeros(Int, e.n_retailers)
    for j = 1:e.n_retailers
        margins = [unit_margin(e, j, t) for t in eachindex(e.price_tiers)]
        margin_nodes[j] = add_invariant!(
            dag,
            RetailerMarginInvariant(allocation_index(e, j), tier_index(e, j), margins, e.demands[j, :]);
            variable_parent_indexes = [allocation_index(e, j), tier_index(e, j)],
            name = "margin_$(e.retailer_names[j])",
        )
    end

    obj_node = add_invariant!(dag, ObjectiveInvariant(); name = "objective_value", invariant_parent_indexes = margin_nodes)

    budget_node = add_invariant!(
        dag,
        AllocationBudgetInvariant(e.n_tickets);
        name = "constraint_violation",
        variable_parent_indexes = [allocation_index(e, j) for j = 1:e.n_retailers],
    )

    constraint_node = add_invariant!(dag, StaticConstraintInvariant(e.α); invariant_parent_indexes = [budget_node])

    add_invariant!(dag, AggregatorInvariant(); invariant_parent_indexes = [constraint_node, obj_node])

    return dag
end

@testitem "RetailerMarginInvariant eval/commit" begin
    # margins per tier: 10, 20 ; demands per tier: 100, 50
    invariant = JuLS.RetailerMarginInvariant(1, 2, [10.0, 20.0], [100, 50])

    messages = JuLS.DAGMessagesVector([
        JuLS.SingleVariableMessage(1, JuLS.IntDecisionValue(80)),
        JuLS.SingleVariableMessage(2, JuLS.IntDecisionValue(1)),
    ])
    output = JuLS.init!(invariant, messages)
    @test output.value == -800.0 # 10 * min(80, 100)
    @test invariant.current_alloc == 80
    @test invariant.current_tier == 1

    # Move to tier 2: margin = 20 * min(80, 50) = 1000
    delta = JuLS.DAGMessagesVector([JuLS.SingleVariableMoveDelta(2, JuLS.IntDecisionValue(1), JuLS.IntDecisionValue(2))])
    @test JuLS.evaluate(invariant, delta) == JuLS.FloatDelta(-200.0)

    # Move both: alloc 40, tier 2: margin = 20 * min(40, 50) = 800
    delta = JuLS.DAGMessagesVector([
        JuLS.SingleVariableMoveDelta(1, JuLS.IntDecisionValue(80), JuLS.IntDecisionValue(40)),
        JuLS.SingleVariableMoveDelta(2, JuLS.IntDecisionValue(1), JuLS.IntDecisionValue(2)),
    ])
    @test JuLS.evaluate(invariant, delta) == JuLS.FloatDelta(0.0)

    JuLS.commit!(invariant, delta)
    @test invariant.current_alloc == 40
    @test invariant.current_tier == 2

    # Full evaluation must not depend on state
    messages = JuLS.DAGMessagesVector([
        JuLS.SingleVariableMessage(1, JuLS.IntDecisionValue(200)),
        JuLS.SingleVariableMessage(2, JuLS.IntDecisionValue(2)),
    ])
    @test JuLS.evaluate(invariant, messages).value == -1000.0 # 20 * min(200, 50)
end

@testitem "AllocationBudgetInvariant eval/commit" begin
    invariant = JuLS.AllocationBudgetInvariant(100)

    messages = JuLS.DAGMessagesVector([
        JuLS.SingleVariableMessage(1, JuLS.IntDecisionValue(60)),
        JuLS.SingleVariableMessage(2, JuLS.IntDecisionValue(40)),
    ])
    output = JuLS.init!(invariant, messages)
    @test output.value == 0.0
    @test invariant.current_sum == 100

    # Transfer keeps the sum: no violation
    transfer = JuLS.DAGMessagesVector([
        JuLS.SingleVariableMoveDelta(1, JuLS.IntDecisionValue(60), JuLS.IntDecisionValue(50)),
        JuLS.SingleVariableMoveDelta(2, JuLS.IntDecisionValue(40), JuLS.IntDecisionValue(50)),
    ])
    @test iszero(JuLS.evaluate(invariant, transfer))

    # Single-sided change breaks the budget
    increase = JuLS.DAGMessagesVector([JuLS.SingleVariableMoveDelta(1, JuLS.IntDecisionValue(60), JuLS.IntDecisionValue(70))])
    @test JuLS.evaluate(invariant, increase) == JuLS.FloatDelta(10.0)

    JuLS.commit!(invariant, transfer)
    @test invariant.current_sum == 100
end

@testitem "Ticket pricing DAG eval and commit" begin
    e = JuLS.TicketPricingExperiment(JuLS.PROJECT_ROOT * "/data/ticket_pricing/tp_3_300")
    dag = JuLS.create_ticket_pricing_dag(e)

    # 100 tickets each, all at the lowest tier (demands 320/140/220 all exceed 100)
    decision_variables = vcat(
        [JuLS.DecisionVariable(j, JuLS.IntDecisionValue(100)) for j = 1:3],
        [JuLS.DecisionVariable(3 + j, JuLS.IntDecisionValue(1)) for j = 1:3],
    )
    JuLS.init!(dag, JuLS.DecisionVariablesArray(decision_variables))

    solution = JuLS.Solution(JuLS.evaluate(dag, JuLS.DecisionVariablesArray(decision_variables)))
    expected = -100 * (JuLS.unit_margin(e, 1, 1) + JuLS.unit_margin(e, 2, 1) + JuLS.unit_margin(e, 3, 1))
    @test solution.objective ≈ expected
    @test solution.feasible

    # Transferring 50 tickets from retailer 1 to retailer 2 stays feasible
    move = JuLS.Move(
        decision_variables[[1, 2]],
        [JuLS.IntDecisionValue(50), JuLS.IntDecisionValue(150)],
    )
    evaluated_move = JuLS.evaluate(dag, move)
    @test JuLS.isfeasible(evaluated_move)
    # Retailer 1 loses 50 sales; retailer 2 only gains 40 because its demand caps at 140
    @test JuLS.delta_obj(evaluated_move) ≈ 50 * JuLS.unit_margin(e, 1, 1) - 40 * JuLS.unit_margin(e, 2, 1)

    # Dropping tickets from retailer 1 only is infeasible (budget violated)
    bad_move = JuLS.Move([decision_variables[1]], [JuLS.IntDecisionValue(50)])
    evaluated_bad_move = JuLS.evaluate(dag, bad_move)
    @test !JuLS.isfeasible(evaluated_bad_move)
    @test JuLS.delta_obj(evaluated_bad_move) == Inf

    # Raising BudgetTix to the top tier caps sales at its demand (6 tickets)
    JuLS.commit!(dag, JuLS.evaluate(dag, move))
    tier_move = JuLS.Move([decision_variables[6]], [JuLS.IntDecisionValue(9)])
    evaluated_tier_move = JuLS.evaluate(dag, tier_move)
    @test JuLS.isfeasible(evaluated_tier_move)
    @test JuLS.delta_obj(evaluated_tier_move) ≈ -6 * JuLS.unit_margin(e, 3, 9) + 100 * JuLS.unit_margin(e, 3, 1)
end
