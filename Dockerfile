# syntax=docker/dockerfile:1

# --- Stage 1: build -----------------------------------------------------------
# Instantiates the Julia environment and precompiles JuLS into a clean depot.
# PackageCompiler.jl (custom sysimage / app) will be added to this stage once
# the HTTP server entrypoint lands.
FROM julia:1.12-bookworm AS builder

ENV JULIA_DEPOT_PATH=/opt/julia-depot \
    JULIA_PROJECT=/app

WORKDIR /app

# Dependency layer: only re-runs when the manifest changes
COPY Project.toml Manifest.toml ./
RUN julia -e 'using Pkg; Pkg.instantiate()'

# Source layer: precompile the package itself
COPY src/ src/
RUN julia -e 'using Pkg; Pkg.precompile(); using JuLS'

# --- Stage 2: runtime ----------------------------------------------------------
FROM julia:1.12-bookworm AS runtime

ENV JULIA_DEPOT_PATH=/opt/julia-depot \
    JULIA_PROJECT=/app

COPY --from=builder /opt/julia-depot /opt/julia-depot
COPY --from=builder /app /app

WORKDIR /app

# Port the Oxygen.jl REST API will listen on
EXPOSE 8080

# Placeholder entrypoint until the Oxygen.jl server is implemented:
# proves the image contains a loadable, precompiled JuLS
CMD ["julia", "-e", "using JuLS; println(\"JuLS $(pkgversion(JuLS)) image OK — HTTP server coming next\")"]
