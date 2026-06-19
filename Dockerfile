# syntax=docker/dockerfile:1

# --- Stage 1: build -----------------------------------------------------------
# Instantiates the Julia environment and precompiles JuLS + the web stack into a
# clean depot. PackageCompiler.jl (custom sysimage / app) can be added here later
# to slim the runtime and cut startup time.
FROM julia:1.12-bookworm AS builder

ENV JULIA_DEPOT_PATH=/opt/julia-depot \
    JULIA_PROJECT=/app

WORKDIR /app

# Dependency layer: only re-runs when the manifest changes
COPY Project.toml Manifest.toml ./
RUN julia -e 'using Pkg; Pkg.instantiate()'

# Source layer: precompile the package and load the server module so Oxygen and
# the HTTP stack are precompiled into the depot too
COPY src/ src/
COPY server/ server/
RUN julia -e 'using Pkg; Pkg.precompile()' \
    && julia -e 'include("server/JuLSServer.jl"); using .JuLSServer'

# --- Stage 2: runtime ----------------------------------------------------------
FROM julia:1.12-bookworm AS runtime

ENV JULIA_DEPOT_PATH=/opt/julia-depot \
    JULIA_PROJECT=/app \
    HOST=0.0.0.0 \
    PORT=8080

COPY --from=builder /opt/julia-depot /opt/julia-depot
COPY --from=builder /app /app

WORKDIR /app

# Port the Oxygen.jl REST API listens on
EXPOSE 8080

# Launch the synchronous JSON solve API (honors HOST/PORT)
CMD ["julia", "server/main.jl"]
