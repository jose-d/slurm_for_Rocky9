#!/bin/bash
# Detect CUDA version in the current environment.
# Outputs version string (e.g. "12.4.0") or "unknown".

if command -v nvcc &>/dev/null; then
    version=$(nvcc --version | sed -n 's/.*release \([0-9.]*\).*/\1/p')
    if [ -n "${version}" ]; then
        echo "${version}"
        exit 0
    fi
fi

if [ -f /usr/local/cuda/version.json ]; then
    version=$(python3 -c "
import json, sys
with open('/usr/local/cuda/version.json') as f:
    d = json.load(f)
cuda = d.get('cuda', d.get('CUDA Version'))
if isinstance(cuda, dict):
    print(cuda.get('version', 'unknown'))
    sys.exit(0)
elif cuda:
    print(cuda)
    sys.exit(0)
for v in d.values():
    if isinstance(v, dict) and 'version' in v:
        print(v['version'])
        sys.exit(0)
print('unknown')
" 2>/dev/null)
    if [ -n "${version}" ] && [ "${version}" != "unknown" ]; then
        echo "${version}"
        exit 0
    fi
fi

if [ -f /usr/local/cuda/version.txt ]; then
    version=$(awk '/CUDA Version/ {print $NF; exit}' /usr/local/cuda/version.txt 2>/dev/null)
    if [ -n "${version}" ]; then
        echo "${version}"
        exit 0
    fi
fi

echo "unknown"
