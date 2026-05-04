#!/bin/bash

# fail if anything wrong
set -e

SLURM_RELTAG="${SLURM_RELTAG:?SLURM_RELTAG must be set}"
SLURM_VERSION="${SLURM_VERSION:?SLURM_VERSION must be set}"

# print input vars
echo "SLURM_RELTAG: ${SLURM_RELTAG}, SLURM_VERSION: ${SLURM_VERSION}"

# enable shell debug
set -x

if [ "${SLURM_WITH_PMIX:-true}" = "true" ]; then
    # install deps
    cat > /etc/yum.repos.d/pmix-local.repo << EOF
[pmix-local]
name=Local PMIx RPMs
baseurl=file://${GITHUB_WORKSPACE}/pmix_rpms
enabled=1
gpgcheck=0
EOF

    dnf -y install pmix pmix-devel pmix3 pmix3-devel
fi

# mkdir for rpmbuild and copy tarball there
mkdir -p "${HOME}/rpmbuild/SOURCES/"
cp "${GITHUB_WORKSPACE}/slurm-${SLURM_VERSION}.tar.bz2" "$HOME/rpmbuild/SOURCES/"

# dump rpmlist for possible forensic
rpm -qa | sort > "${GITHUB_WORKSPACE}/image_slurm_rpms.txt"

SLURM_SPEC_PATH="${SLURM_SPEC_PATH:?SLURM_SPEC_PATH must be set}"

prepare_nvml_prefix() {
    local requested_path="$1"
    local -a header_candidates=()
    local -a library_candidates=()
    local header_path=""
    local library_path=""
    local versioned_cuda_root

    if [ -n "${requested_path}" ]; then
        header_candidates+=(
            "${requested_path%/}/include/nvml.h"
            "${requested_path%/}/targets/x86_64-linux/include/nvml.h"
        )
        library_candidates+=(
            "${requested_path%/}/lib64/libnvidia-ml.so"
            "${requested_path%/}/lib/libnvidia-ml.so"
            "${requested_path%/}/lib/stubs/libnvidia-ml.so"
            "${requested_path%/}/targets/x86_64-linux/lib64/libnvidia-ml.so"
            "${requested_path%/}/targets/x86_64-linux/lib/libnvidia-ml.so"
            "${requested_path%/}/targets/x86_64-linux/lib/stubs/libnvidia-ml.so"
        )
    fi

    header_candidates+=(
        /usr/local/cuda/targets/x86_64-linux/include/nvml.h
        /usr/include/nvml.h
    )
    library_candidates+=(
        /usr/local/cuda/targets/x86_64-linux/lib64/libnvidia-ml.so
        /usr/local/cuda/targets/x86_64-linux/lib/libnvidia-ml.so
        /usr/local/cuda/targets/x86_64-linux/lib/stubs/libnvidia-ml.so
        /usr/lib64/libnvidia-ml.so
    )

    for versioned_cuda_root in /usr/local/cuda-*; do
        [ -d "${versioned_cuda_root}" ] || continue
        header_candidates+=(
            "${versioned_cuda_root}/targets/x86_64-linux/include/nvml.h"
        )
        library_candidates+=(
            "${versioned_cuda_root}/targets/x86_64-linux/lib64/libnvidia-ml.so"
            "${versioned_cuda_root}/targets/x86_64-linux/lib/libnvidia-ml.so"
            "${versioned_cuda_root}/targets/x86_64-linux/lib/stubs/libnvidia-ml.so"
        )
    done

    for candidate in "${header_candidates[@]}"; do
        if [ -f "${candidate}" ]; then
            header_path="${candidate}"
            break
        fi
    done

    for candidate in "${library_candidates[@]}"; do
        if [ -f "${candidate}" ]; then
            library_path="${candidate}"
            break
        fi
    done

    if [ -z "${header_path}" ] || [ -z "${library_path}" ]; then
        echo "Unable to resolve NVML header/library paths" >&2
        echo "Requested NVML path: ${requested_path}" >&2
        echo "Resolved header: ${header_path:-missing}" >&2
        echo "Resolved library: ${library_path:-missing}" >&2
        return 1
    fi

    local nvml_prefix
    nvml_prefix="$(mktemp -d /tmp/slurm-nvml.XXXXXX)"
    mkdir -p "${nvml_prefix}/include" "${nvml_prefix}/lib64"
    ln -sf "${header_path}" "${nvml_prefix}/include/nvml.h"
    ln -sf "${library_path}" "${nvml_prefix}/lib64/libnvidia-ml.so"
    echo "${nvml_prefix}"
}

# do rpmbuild
rpmbuild_cmd=(rpmbuild)

if [ -n "${SLURM_NVML_PATH:-}" ]; then
    SLURM_NVML_PREFIX="$(prepare_nvml_prefix "${SLURM_NVML_PATH}")"
    trap 'if [ -n "${SLURM_NVML_PREFIX:-}" ] && [ -d "${SLURM_NVML_PREFIX}" ]; then rm -rf "${SLURM_NVML_PREFIX}"; fi' EXIT
    rpmbuild_cmd+=(--define "_with_nvml --with-nvml=${SLURM_NVML_PREFIX}")
fi

if [ -n "${SLURM_UCX_PATH:-}" ]; then
    rpmbuild_cmd+=(--define "_with_ucx --with-ucx=${SLURM_UCX_PATH}")
fi

if [ "${SLURM_WITH_RPATH:-false}" = "true" ]; then
    rpmbuild_cmd+=(--define "_with_cflags --with-rpath")
fi

if [ "${SLURM_WITH_UCX:-false}" = "true" ]; then
    rpmbuild_cmd+=(--with ucx)
fi

# Build the pmix path define separately so it can be placed after --with pmix.
# RPM's --with pmix sets _with_pmix to "--with-pmix" (no path), which would
# override an earlier --define. Placing the path define after --with pmix
# ensures configure receives --with-pmix=<paths> pointing to the opt installs.
pmix_args=()
if [ "${SLURM_WITH_PMIX:-true}" = "true" ]; then
    pmix_args+=(--with pmix)
    if [ -n "${SLURM_PMIX_PATHS:-}" ]; then
        pmix_args+=(--define "_with_pmix --with-pmix=${SLURM_PMIX_PATHS}")
    fi
fi

rpmbuild_args=(
        --with pam
        --with slurmrestd
        --with hwloc
        --with lua
        --with mysql
        --with numa
)

if [ "${#pmix_args[@]}" -gt 0 ]; then
    rpmbuild_args+=("${pmix_args[@]}")
fi

"${rpmbuild_cmd[@]}" \
        "${rpmbuild_args[@]}" \
        -ba "${SLURM_SPEC_PATH}"

mkdir -p "${GITHUB_WORKSPACE}/rpms"
cp ${HOME}/rpmbuild/RPMS/x86_64/slurm-*.rpm "${GITHUB_WORKSPACE}/rpms/"

set +x
