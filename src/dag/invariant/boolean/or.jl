# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

"""
    OrInvariant <: Invariant

Represents an invariant for the logical OR constraint.
y = x_1 ∪ x_2 ∪ ... ∪ x_n

# Fields
- `nb_trues::Int`: Number of variables currently true.
"""
mutable struct OrInvariant <: Invariant
    nb_trues::Int
end
OrInvariant() = OrInvariant(0)

evaluate(::OrInvariant, messages::DAGMessagesVector{SingleVariableMessage{BinaryDecisionValue}}) =
    SingleVariableMessage(any(m.value.value for m in messages))

function evaluate(invariant::OrInvariant, deltas::DAGMessagesVector{SingleVariableMoveDelta{BinaryDecisionValue}})
    current_value = invariant.nb_trues > 0
    new_value = invariant.nb_trues + sum(δ.new_value.value - δ.current_value.value for δ in deltas) > 0
    if current_value == new_value
        return NoMessage()
    end
    return SingleVariableMoveDelta(current_value, new_value)
end

commit!(invariant::OrInvariant, deltas::DAGMessagesVector{SingleVariableMoveDelta{BinaryDecisionValue}}) =
    invariant.nb_trues += sum(δ.new_value.value - δ.current_value.value for δ in deltas)

function init!(invariant::OrInvariant, messages::DAGMessagesVector{SingleVariableMessage{BinaryDecisionValue}})
    invariant.nb_trues = sum(m.value.value for m in messages)
    return evaluate(invariant, messages)
end

@testitem "evaluate(::OrInvariant, ::SingleVariableMessage)" begin
    m1 = JuLS.SingleVariableMessage(true)
    m2 = JuLS.SingleVariableMessage(false)
    m3 = JuLS.SingleVariableMessage(false)

    invariant = JuLS.OrInvariant()

    @test JuLS.evaluate(invariant, JuLS.DAGMessagesVector([m1])) == JuLS.SingleVariableMessage(true)
    @test JuLS.evaluate(invariant, JuLS.DAGMessagesVector([m2])) == JuLS.SingleVariableMessage(false)
    @test JuLS.evaluate(invariant, JuLS.DAGMessagesVector([m3])) == JuLS.SingleVariableMessage(false)

    @test JuLS.evaluate(invariant, JuLS.DAGMessagesVector([m1, m2])) == JuLS.SingleVariableMessage(true)
    @test JuLS.evaluate(invariant, JuLS.DAGMessagesVector([m2, m3])) == JuLS.SingleVariableMessage(false)

    @test JuLS.evaluate(invariant, JuLS.DAGMessagesVector([m1, m2, m3])) == JuLS.SingleVariableMessage(true)
end

@testitem "evaluate(::OrInvariant, ::SingleVariableMoveDelta)" begin
    δ1 = JuLS.SingleVariableMoveDelta(true, false)
    δ2 = JuLS.SingleVariableMoveDelta(false, true)

    invariant = JuLS.OrInvariant(1)

    @test JuLS.evaluate(invariant, JuLS.DAGMessagesVector([δ1])) == JuLS.SingleVariableMoveDelta(true, false)
    @test JuLS.evaluate(invariant, JuLS.DAGMessagesVector([δ2])) == JuLS.NoMessage()

    @test JuLS.evaluate(invariant, JuLS.DAGMessagesVector([δ2, δ1])) == JuLS.NoMessage()
    @test JuLS.evaluate(invariant, JuLS.DAGMessagesVector([δ2, δ1, δ1])) == JuLS.SingleVariableMoveDelta(true, false)
end

@testitem "commit!(::OrInvariant)" begin
    δ1 = JuLS.SingleVariableMoveDelta(true, false)
    δ2 = JuLS.SingleVariableMoveDelta(false, true)

    invariant = JuLS.OrInvariant(1)
    JuLS.commit!(invariant, JuLS.DAGMessagesVector([δ1]))

    @test invariant.nb_trues == 0

    JuLS.commit!(invariant, JuLS.DAGMessagesVector([δ2, δ2]))
    @test invariant.nb_trues == 2
end

@testitem "init!(::OrInvariant)" begin
    invariant = JuLS.OrInvariant()

    m1 = JuLS.SingleVariableMessage(1, true)
    m2 = JuLS.SingleVariableMessage(2, true)
    m3 = JuLS.SingleVariableMessage(3, false)

    messages = JuLS.DAGMessagesVector([m1, m2, m3])

    @test JuLS.init!(invariant, messages) == JuLS.SingleVariableMessage(true)
    @test invariant.nb_trues == 2
end