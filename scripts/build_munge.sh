#!/bin/bash

set -euo pipefail

MUNGE_VERSION="${MUNGE_VERSION:?MUNGE_VERSION must be set}"
MUNGE_RELTAG="${MUNGE_RELTAG:?MUNGE_RELTAG must be set}"
GITHUB_WORKSPACE="${GITHUB_WORKSPACE:?GITHUB_WORKSPACE must be set}"
DISTRO="${DISTRO:?DISTRO must be set}"

# print input vars
echo "MUNGE_RELTAG: ${MUNGE_RELTAG}, MUNGE_VERSION: ${MUNGE_VERSION}"

# enable shell debug
set -x

MUNGE_TARBALL="${GITHUB_WORKSPACE}/munge-${MUNGE_VERSION}.tar.xz"

if [ ! -f "${MUNGE_TARBALL}" ]; then
    echo "Munge tarball not found: ${MUNGE_TARBALL}" >&2
    exit 1
fi

# Set up rpmbuild dirs
mkdir -p "${HOME}/rpmbuild/SOURCES" "${HOME}/rpmbuild/SPECS"

# Copy tarball to SOURCES
cp "${MUNGE_TARBALL}" "${HOME}/rpmbuild/SOURCES/"

# Extract the spec file from the tarball
tar -xOf "${MUNGE_TARBALL}" "munge-${MUNGE_VERSION}/munge.spec" > "${HOME}/rpmbuild/SPECS/munge.spec"

MUNGE_SPEC_PATH="${HOME}/rpmbuild/SPECS/munge.spec"

if [ ! -f "${MUNGE_SPEC_PATH}" ]; then
    echo "Munge spec file not found after extraction: ${MUNGE_SPEC_PATH}" >&2
    exit 1
fi

# Patch Release: line to use datetime reltag
sed -i "s/^Release:.*$/Release: ${MUNGE_RELTAG}%{?dist}/" "${MUNGE_SPEC_PATH}"

# Validate patch was applied
grep -Fq "${MUNGE_RELTAG}" "${MUNGE_SPEC_PATH}" \
    || { echo "Spec patch failed: reltag not found in Release line" >&2; exit 1; }

# dump rpmlist for build provenance
rpm -qa | sort > "${GITHUB_WORKSPACE}/image_munge_rpms_${DISTRO}.txt"

# do rpmbuild
rpmbuild_cmd=(rpmbuild -ba "${MUNGE_SPEC_PATH}")
printf '%q ' "${rpmbuild_cmd[@]}" > "${GITHUB_WORKSPACE}/rpmbuild_munge_${DISTRO}.txt"
printf '\n' >> "${GITHUB_WORKSPACE}/rpmbuild_munge_${DISTRO}.txt"
"${rpmbuild_cmd[@]}"

mkdir -p "${GITHUB_WORKSPACE}/rpms"
mapfile -d '' -t munge_rpms < <(find "${HOME}/rpmbuild/RPMS" -type f -name 'munge*.rpm' -print0)
if [ "${#munge_rpms[@]}" -eq 0 ]; then
    echo "No Munge RPMs found after build" >&2
    exit 1
fi
cp "${munge_rpms[@]}" "${GITHUB_WORKSPACE}/rpms/"
