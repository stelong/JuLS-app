# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

"""
    ObjectiveInvariant <: StatelessInvariant

Invariant to transform an Array of deltas in to an ObjectiveDelta
"""
struct ObjectiveInvariant <: StatelessInvariant end

InputType(::ObjectiveInvariant) = MultiType()

evaluate(::ObjectiveInvariant, δ::ScalarDelta) = convert(ObjectiveDelta, δ)
evaluate(::ObjectiveInvariant, message::ScalarFullMessage) = convert(ObjectiveFullMessage, message)

evaluate(invariant::ObjectiveInvariant, deltas::MultiTypedDAGMessages) = evaluate(invariant, sum(all_messages(deltas)))

@testitem "Test eval" begin
    invariant = JuLS.ObjectiveInvariant()

    delta1 = JuLS.FloatDelta(12.0)
    delta2 = JuLS.FloatDelta(-2.0)

    @test JuLS.evaluate(invariant, JuLS.MultiTypedDAGMessages{JuLS.Delta}([delta1, delta2])) == JuLS.ObjectiveDelta(10.0)
end

@testitem "Test eval 2" begin
    invariant = JuLS.ObjectiveInvariant()

    delta1 = JuLS.FloatDelta(12.0)
    delta2 = JuLS.FloatDelta(-12.0)

    @test iszero(JuLS.evaluate(invariant, JuLS.MultiTypedDAGMessages{JuLS.Delta}([delta1, delta2])))
end

@testitem "evaluate(::FullMessage)" begin
    invariant = JuLS.ObjectiveInvariant()

    delta1 = JuLS.FloatFullMessage(12.0)
    delta2 = JuLS.FloatFullMessage(-12.0)

    @test JuLS.evaluate(invariant, JuLS.MultiTypedDAGMessages{JuLS.FullMessage}([delta1, delta2])) ==
          JuLS.ObjectiveFullMessage(0.0)

    delta1 = JuLS.FloatFullMessage(12.0)
    delta2 = JuLS.FloatFullMessage(-2.0)

    @test JuLS.evaluate(invariant, JuLS.MultiTypedDAGMessages{JuLS.FullMessage}([delta1, delta2])) ==
          JuLS.ObjectiveFullMessage(10.0)
end

@testitem "evaluate(::MultiTypedDAGMessages)" begin
    invariant = JuLS.ObjectiveInvariant()

    delta1 = JuLS.FloatFullMessage(12.0)
    delta2 = JuLS.ObjectiveFullMessage(-12.0)

    input = JuLS.DAGMessage[]
    push!(input, delta1)
    push!(input, delta2)

    @test JuLS.evaluate(invariant, JuLS.MultiTypedDAGMessages(input)) == JuLS.ObjectiveFullMessage(0.0)

    delta1 = JuLS.FloatFullMessage(12.0)
    delta2 = JuLS.ObjectiveFullMessage(-2.0)

    input = JuLS.DAGMessage[]
    push!(input, delta1)
    push!(input, delta2)

    @test JuLS.evaluate(invariant, JuLS.MultiTypedDAGMessages(input)) == JuLS.ObjectiveFullMessage(10.0)
end

@testitem "Test commit" begin
    invariant = JuLS.ObjectiveInvariant()

    delta1 = JuLS.FloatDelta(12.0)
    delta2 = JuLS.FloatDelta(-2.0)

    JuLS.commit!(invariant, JuLS.MultiTypedDAGMessages{JuLS.Delta}([delta1, delta2]))

    @test JuLS.evaluate(invariant, JuLS.MultiTypedDAGMessages{JuLS.Delta}([delta1, delta2])) == JuLS.ObjectiveDelta(10.0)
end