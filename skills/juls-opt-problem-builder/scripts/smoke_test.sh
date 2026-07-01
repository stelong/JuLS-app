#!/usr/bin/env bash
# Build the JuLS image and verify a newly registered problem end to end:
# GET /problems lists it, and POST /solve solves its bundled easy sample.
#
#   scripts/smoke_test.sh <problem> [port]
#
# Requires: docker (or colima), and data/<problem>/easy.json to exist.
set -euo pipefail

PROBLEM="${1:?usage: smoke_test.sh <problem> [port]}"
PORT="${2:-8080}"
IMAGE="juls-app-dev"
NAME="juls-smoke-$$"

REPO_ROOT="$(git rev-parse --show-toplevel)"
SAMPLE="$REPO_ROOT/data/$PROBLEM/easy.json"
[ -f "$SAMPLE" ] || { echo "missing sample: $SAMPLE" >&2; exit 1; }

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "==> building image ($IMAGE)"
docker build -t "$IMAGE" "$REPO_ROOT"

echo "==> starting container on :$PORT"
docker run -d --rm --name "$NAME" -p "$PORT:8080" "$IMAGE" >/dev/null

echo "==> waiting for /health"
for _ in $(seq 1 120); do
  curl -fs "localhost:$PORT/health" >/dev/null 2>&1 && break
  sleep 1
done

echo "==> GET /problems (expecting '$PROBLEM')"
if curl -s "localhost:$PORT/problems" | grep -q "\"$PROBLEM\""; then
  echo "    [ok] $PROBLEM is registered"
else
  echo "    [FAIL] $PROBLEM not listed by /problems" >&2
  curl -s "localhost:$PORT/problems" >&2
  exit 1
fi

echo "==> POST /solve with data/$PROBLEM/easy.json"
DATA="$(cat "$SAMPLE")"
BODY="{\"problem\":\"$PROBLEM\",\"data\":$DATA,\"solve\":{\"limit\":\"auto\",\"seed\":0}}"
RESP="$(curl -s -X POST "localhost:$PORT/solve" -H 'Content-Type: application/json' -d "$BODY")"
echo "$RESP"
echo "$RESP" | grep -q '"feasible"' || { echo "    [FAIL] no solution in response" >&2; exit 1; }

echo "==> smoke test passed for '$PROBLEM'"
