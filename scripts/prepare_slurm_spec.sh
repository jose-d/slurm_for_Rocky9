#!/usr/bin/env bash
# Unpack a verified Slurm tarball and patch its spec file with the release tag.
# Shared by the GitHub Actions workflow and scripts/build_local.sh.

set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 SLURM_VERSION RELTAG" >&2
    exit 2
fi

slurm_version="$1"
reltag="$2"

if [[ ! "${reltag}" =~ ^[0-9A-Za-z_.+]+$ ]]; then
    echo "Invalid RELTAG for an RPM release: ${reltag}" >&2
    exit 2
fi

tarball="slurm-${slurm_version}.tar.bz2"
spec_path="./slurm-${slurm_version}/slurm.spec"

tar -xf "${tarball}"
sed -i "s/^%define rel.*$/%define rel     ${reltag}/g" "${spec_path}"
sed -i "s/^%global slurm_source_dir.*$/%global slurm_source_dir %{name}-%{version}/g" "${spec_path}"
grep -q "^%define rel     ${reltag}$" "${spec_path}" \
    || { echo "Spec patch failed: release tag not set in ${spec_path}" >&2; exit 1; }
