# syntax=docker/dockerfile:1

# --- Stage 1: build -----------------------------------------------------------
# Instantiates the Julia environment and precompiles JuLS + the web stack into a
# clean depot (no build tooling lands here, so it can be copied as-is to runtime).
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
    && julia -e 'include("server/app.jl"); using .App'

# --- Stage 2: sysimage ---------------------------------------------------------
# Builds a custom sysimage that bakes JuLS + Oxygen + the solve hot path into
# native code. PackageCompiler and the C toolchain (gcc/g++ + libc dev files,
# needed to link the sysimage) live only in this throwaway stage.
FROM builder AS sysimage

RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential \
    && rm -rf /var/lib/apt/lists/*

RUN SYSIMAGE_PATH=/app/juls_sysimage.so julia server/build_sysimage.jl

# --- Stage 3: runtime ----------------------------------------------------------
FROM julia:1.12-bookworm AS runtime

ENV JULIA_DEPOT_PATH=/opt/julia-depot \
    JULIA_PROJECT=/app \
    JULIA_NUM_THREADS=auto \
    HOST=0.0.0.0 \
    PORT=8080

# Clean depot + app from the builder; only the sysimage from the build stage
COPY --from=builder /opt/julia-depot /opt/julia-depot
COPY --from=builder /app /app
COPY --from=sysimage /app/juls_sysimage.so /app/juls_sysimage.so

WORKDIR /app

# Port the Oxygen.jl REST API listens on
EXPOSE 8080

# Launch the synchronous JSON solve API on the custom sysimage (honors HOST/PORT,
# PARALLEL, WARMUP; threads come from JULIA_NUM_THREADS)
CMD ["julia", "--sysimage=/app/juls_sysimage.so", "server/run.jl"]
