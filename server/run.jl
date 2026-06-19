# Copyright (c) 2026 Stefano Longobardi
# SPDX-License-Identifier: Apache-2.0
#
# Container / local entry point. Run from the repo root with:
#   julia --project=. server/run.jl
# For real request-level parallelism, start Julia with threads:
#   julia --project=. --threads=auto server/run.jl
#
# Environment variables (all optional):
#   HOST     bind address          (default 0.0.0.0)
#   PORT     bind port             (default 8080)
#   PARALLEL multi-threaded serve  (default true; set "false" to disable)
#   WARMUP   warm solver on start  (default true; set "false" to disable)

include(joinpath(@__DIR__, "app.jl"))
using .App

App.start_server(;
    host = get(ENV, "HOST", "0.0.0.0"),
    port = parse(Int, get(ENV, "PORT", "8080")),
    parallel = get(ENV, "PARALLEL", "true") != "false",
    warmup_on_start = get(ENV, "WARMUP", "true") != "false",
)
