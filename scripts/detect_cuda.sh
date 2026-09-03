#!/usr/bin/env bash

set -euo pipefail

normalize_version() {
    sed -nE '/[0-9]+\.[0-9]+/ { s/[^0-9]*([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/; p; q; }'
}

if [ -n "${CUDA_VERSION:-}" ]; then
    version="$(printf '%s\n' "${CUDA_VERSION}" | normalize_version)"
    if [ -n "${version}" ]; then
        printf '%s\n' "${version}"
        exit 0
    fi
fi

if command -v nvcc >/dev/null 2>&1; then
    if version="$(nvcc --version 2>/dev/null | normalize_version)" && [ -n "${version}" ]; then
        printf '%s\n' "${version}"
        exit 0
    fi
fi

if [ -f /usr/local/cuda/version.json ] && command -v python3 >/dev/null 2>&1; then
    if version="$(python3 - <<'PY' 2>/dev/null
import json
from pathlib import Path

data = json.loads(Path("/usr/local/cuda/version.json").read_text())
cuda = data.get("cuda", data.get("CUDA Version"))
if isinstance(cuda, dict):
    cuda = cuda.get("version")
if cuda:
    print(cuda)
PY
)"; then
        version="$(printf '%s\n' "${version}" | normalize_version)"
    else
        version=""
    fi
    if [ -n "${version}" ]; then
        printf '%s\n' "${version}"
        exit 0
    fi
fi

if [ -f /usr/local/cuda/version.txt ]; then
    version="$(normalize_version < /usr/local/cuda/version.txt)"
    if [ -n "${version}" ]; then
        printf '%s\n' "${version}"
        exit 0
    fi
fi

cuda_target="$(readlink -f /usr/local/cuda 2>/dev/null || true)"
version="$(printf '%s\n' "${cuda_target##*/}" | normalize_version)"
if [ -n "${version}" ]; then
    printf '%s\n' "${version}"
    exit 0
fi

printf '%s\n' unknown
