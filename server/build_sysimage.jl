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

# By default create_sysimage uses cpu_target = "native", which bakes in the exact
# microarchitecture of the build machine (e.g. the GitHub Actions runner's AMD
# Zen 4 / "znver4"). Such a sysimage is rejected at startup on any host whose CPU
# lacks those features — including amd64 images run under QEMU on Apple Silicon.
# default_app_cpu_target() returns a portable, multi-versioned target for the
# current architecture, so the sysimage runs on any CPU of that arch.
create_sysimage(
    [:JuLS, :Oxygen, :HTTP, :JSON3];
    project = ROOT,
    sysimage_path = get(ENV, "SYSIMAGE_PATH", joinpath(ROOT, "juls_sysimage.so")),
    precompile_execution_file = joinpath(@__DIR__, "precompile.jl"),
    cpu_target = get(ENV, "JULIA_CPU_TARGET", PackageCompiler.default_app_cpu_target()),
)
