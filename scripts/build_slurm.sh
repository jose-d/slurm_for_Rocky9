#!/bin/bash

# fail if anything wrong
set -e

# print input vars
echo "SLURM_RELTAG: ${SLURM_RELTAG}"

# enable shell debug
set -x

# install deps
dnf -y install tree

tree ${GITHUB_WORKSPACE}

dnf -y install ${GITHUB_WORKSPACE}/pmix_rpms/*.rpm

# mkdir for rpmbuild and copy tarball there
mkdir -p "${HOME}/rpmbuild/SOURCES/"
cp ${GITHUB_WORKSPACE}/slurm-*.tar.bz2 $HOME/rpmbuild/SOURCES/

# dump rpmlist for possible forensic
rpm -qa | sort > "${GITHUB_WORKSPACE}/image_slurm_rpms.txt"

# do rpmbuild
rpmbuild_args=()

if [ -n "${SLURM_NVML_PATH:-}" ]; then
    rpmbuild_args+=(--define "_with_nvml --with-nvml=${SLURM_NVML_PATH}")
fi

if [ -n "${SLURM_UCX_PATH:-}" ]; then
    rpmbuild_args+=(--define "_with_ucx --with_ucx=${SLURM_UCX_PATH}")
fi

if [ "${SLURM_WITH_UCX:-false}" = "true" ]; then
    rpmbuild_args+=(--with ucx)
fi

rpmbuild "${rpmbuild_args[@]}" \
         --with pam \
         --with slurmrestd \
         --with hwloc \
         --with lua \
         --with mysql \
         --with numa \
         --with pmix \
         -ba ./slurm-*/slurm.spec

mkdir -p "${GITHUB_WORKSPACE}/rpms"
cp ${HOME}/rpmbuild/RPMS/x86_64/slurm-*.rpm "${GITHUB_WORKSPACE}/rpms/"

set +x
