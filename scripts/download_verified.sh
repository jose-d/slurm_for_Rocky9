#!/usr/bin/env bash

set -euo pipefail

if [ "$#" -ne 3 ]; then
    echo "Usage: $0 URL DESTINATION SHA256" >&2
    exit 2
fi

url="$1"
destination="$2"
expected_sha256="$3"

if [[ ! "${expected_sha256}" =~ ^[[:xdigit:]]{64}$ ]]; then
    echo "Expected SHA-256 must contain exactly 64 hexadecimal characters" >&2
    exit 2
fi

verify() {
    printf '%s  %s\n' "${expected_sha256}" "$1" | sha256sum --check --strict -
}

if [ -f "${destination}" ] && verify "${destination}"; then
    echo "Using verified cached source: ${destination}"
    exit 0
fi

partial="${destination}.part"
trap 'rm -f "${partial}"' EXIT

curl --fail --location --retry 3 --output "${partial}" "${url}"
verify "${partial}"
mv -f "${partial}" "${destination}"
trap - EXIT
