#!/bin/bash

# fail if anything wrong
set -e

# print input vars
echo "SLURM_RELTAG: ${SLURM_RELTAG}, SLURM_VERSION: ${SLURM_VERSION}"

# enable shell debug
set -x

# install deps
dnf -y install ${GITHUB_WORKSPACE}/pmix_rpms/*.rpm

# mkdir for rpmbuild and copy tarball there
mkdir -p "${HOME}/rpmbuild/SOURCES/"
SLURM_VERSION="${SLURM_VERSION:?SLURM_VERSION must be set}"
cp "${GITHUB_WORKSPACE}/slurm-${SLURM_VERSION}.tar.bz2" "$HOME/rpmbuild/SOURCES/"

# dump rpmlist for possible forensic
rpm -qa | sort > "${GITHUB_WORKSPACE}/image_slurm_rpms.txt"

SLURM_SPEC_PATH="${SLURM_SPEC_PATH:?SLURM_SPEC_PATH must be set}"

# do rpmbuild
rpmbuild_cmd=(rpmbuild)

if [ -n "${SLURM_NVML_PATH:-}" ]; then
    rpmbuild_cmd+=(--define "_with_nvml --with-nvml=${SLURM_NVML_PATH}")
fi

if [ -n "${SLURM_UCX_PATH:-}" ]; then
    rpmbuild_cmd+=(--define "_with_ucx --with-ucx=${SLURM_UCX_PATH}")
fi

if [ -n "${SLURM_PMIX_PATHS:-}" ]; then
    rpmbuild_cmd+=(--define "_with_pmix --with-pmix=${SLURM_PMIX_PATHS}")
fi

if [ "${SLURM_WITH_RPATH:-false}" = "true" ]; then
    rpmbuild_cmd+=(--define "_with_cflags --with-rpath")
fi

if [ "${SLURM_WITH_UCX:-false}" = "true" ]; then
    rpmbuild_cmd+=(--with ucx)
fi

"${rpmbuild_cmd[@]}" \
        --with pam \
        --with slurmrestd \
        --with hwloc \
        --with lua \
        --with mysql \
        --with numa \
        --with pmix \
        -ba "${SLURM_SPEC_PATH}"

mkdir -p "${GITHUB_WORKSPACE}/rpms"
cp ${HOME}/rpmbuild/RPMS/x86_64/slurm-*.rpm "${GITHUB_WORKSPACE}/rpms/"

set +x
