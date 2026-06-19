# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Container / local entry point. Run from the repo root with:
#   julia --project=. server/main.jl
# Honors the PORT and HOST environment variables (defaults 8080 / 0.0.0.0).

include(joinpath(@__DIR__, "JuLSServer.jl"))
using .JuLSServer

JuLSServer.start_server(;
    host = get(ENV, "HOST", "0.0.0.0"),
    port = parse(Int, get(ENV, "PORT", "8080")),
)
