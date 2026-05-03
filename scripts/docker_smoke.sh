#!/usr/bin/env bash
# Smoke-test that every Dockerfile in the repo builds. Catches stale COPY
# paths, broken apt packages, and missing build steps; does NOT run the
# resulting containers.
#
# Usage:
#   scripts/docker_smoke.sh           # fast set (skips ML-heavy builds)
#   DOCKER_SMOKE_HEAVY=1 scripts/docker_smoke.sh  # include ml_caching
#
# Exits non-zero on the first build failure.

set -euo pipefail

if ! command -v docker >/dev/null 2>&1; then
    echo "docker not found in PATH" >&2
    exit 2
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# tag prefix for cleanup convenience
TAG_PREFIX="hornbeam-smoke"

# Each entry: name | dockerfile | build context | extra-build-args
BUILDS=(
    "root|Dockerfile|.|"
    "channels-chat|examples/channels_chat/Dockerfile|.|"
    "demo-distributed-rpc|examples/demo/distributed_rpc/Dockerfile|.|"
    "demo-multi-app|examples/demo/multi_app/Dockerfile|.|"
)

# examples/demo/Dockerfile.demo is parameterised over EXAMPLE; ml_caching
# pre-downloads sentence-transformers (~10 min build), so gate it on the
# heavy flag. multi_app and distributed_rpc are also parameterised but
# have their own Dockerfiles above, so the demo file only adds ml_caching
# coverage.
if [[ "${DOCKER_SMOKE_HEAVY:-0}" == "1" ]]; then
    BUILDS+=(
        "demo-ml-caching|examples/demo/Dockerfile.demo|.|--build-arg EXAMPLE=ml_caching"
    )
fi

failed=()

for entry in "${BUILDS[@]}"; do
    IFS='|' read -r name dockerfile context extra <<<"$entry"
    echo
    echo "::: building $name ($dockerfile)"
    # shellcheck disable=SC2086 # extra is intentionally word-split
    if docker build -q -f "$dockerfile" -t "${TAG_PREFIX}:${name}" $extra "$context"; then
        echo ":::   ok"
    else
        echo ":::   FAIL"
        failed+=("$name")
    fi
done

echo
if [[ ${#failed[@]} -gt 0 ]]; then
    echo "Docker smoke FAILED: ${failed[*]}" >&2
    exit 1
fi

echo "Docker smoke OK (${#BUILDS[@]} images built)"
