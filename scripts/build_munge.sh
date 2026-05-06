#!/bin/bash

# fail if anything wrong
set -e

MUNGE_VERSION="${MUNGE_VERSION:?MUNGE_VERSION must be set}"
MUNGE_RELTAG="${MUNGE_RELTAG:?MUNGE_RELTAG must be set}"

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

# dump rpmlist for possible forensic
rpm -qa | sort > "${GITHUB_WORKSPACE}/image_munge_rpms.txt"

# do rpmbuild
rpmbuild -ba "${MUNGE_SPEC_PATH}"

mkdir -p "${GITHUB_WORKSPACE}/rpms"
mapfile -t munge_rpms < <(find "${HOME}/rpmbuild/RPMS/x86_64" -name 'munge*.rpm')
if [ "${#munge_rpms[@]}" -eq 0 ]; then
    echo "No Munge RPMs found after build" >&2
    exit 1
fi
cp "${munge_rpms[@]}" "${GITHUB_WORKSPACE}/rpms/"
