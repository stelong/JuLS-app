# Copyright (c) 2026 Stefano Longobardi
# SPDX-License-Identifier: Apache-2.0
#
# Builds a custom Julia sysimage that bakes JuLS + the Oxygen web stack and the
# solve hot path (via server/precompile.jl) into native code, removing the
# first-request JIT latency. PackageCompiler is loaded from a throwaway
# environment so it never pollutes the project's Manifest or the runtime depot.
#
# Run from the repo root:
#   julia server/build_sysimage.jl
# Output path overridable with SYSIMAGE_PATH (default <root>/juls_sysimage.so).

import Pkg

const ROOT = dirname(@__DIR__)

# Load PackageCompiler in a temporary env, not the project, so the project's
# Manifest is untouched.
Pkg.activate(; temp = true)
Pkg.add("PackageCompiler")
using PackageCompiler

create_sysimage(
    [:JuLS, :Oxygen, :HTTP, :JSON3];
    project = ROOT,
    sysimage_path = get(ENV, "SYSIMAGE_PATH", joinpath(ROOT, "juls_sysimage.so")),
    precompile_execution_file = joinpath(@__DIR__, "precompile.jl"),
)
