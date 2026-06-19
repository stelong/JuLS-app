# Copyright (c) 2026 Stefano Longobardi
# SPDX-License-Identifier: Apache-2.0
#
# PackageCompiler precompile workload. Loaded by build_sysimage.jl as the
# `precompile_execution_file`: running it traces the full solve path (JSON decode
# -> build_experiment -> optimize! -> JSON encode) for every problem so that
# native code for those paths is baked into the sysimage.

include(joinpath(@__DIR__, "app.jl"))
using .App

App.warmup(; verbose = true)
