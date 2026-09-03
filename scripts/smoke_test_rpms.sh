#!/usr/bin/env bash

set -euo pipefail

if [ "$#" -ne 3 ]; then
    echo "Usage: $0 RPM_DIRECTORY EXPECTED_SLURM_VERSION EXPECT_PMIX" >&2
    exit 2
fi

rpm_dir="$1"
expected_slurm_version="$2"
expect_pmix="$3"

if [ ! -d "${rpm_dir}" ]; then
    echo "RPM directory does not exist: ${rpm_dir}" >&2
    exit 1
fi
if [[ ! "${expected_slurm_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Invalid expected Slurm version: ${expected_slurm_version}" >&2
    exit 2
fi
if [ "${expect_pmix}" != "true" ] && [ "${expect_pmix}" != "false" ]; then
    echo "EXPECT_PMIX must be true or false" >&2
    exit 2
fi

# Slurm's JWT support has a runtime dependency from EPEL.  The minimal Rocky
# images also omit findutils, which this validation script uses to discover the
# downloaded RPMs and installed plugins.
dnf install -y epel-release findutils

rhel_major="$(rpm -E '%{rhel}')"
if [ "${expect_pmix}" = "true" ] && [ "${rhel_major}" = "8" ]; then
    # The EL8 builders get hwloc-devel from PowerTools and UCX 1.20 from the
    # same versioned NVIDIA DOCA repository used to build Slurm.
    dnf config-manager --set-enabled powertools
    dnf config-manager --add-repo \
        https://linux.mellanox.com/public/repo/doca/3.3.0/rhel8/x86_64/
fi

mapfile -d '' -t all_rpms < <(find "${rpm_dir}" -type f -name '*.rpm' -print0)
if [ "${#all_rpms[@]}" -eq 0 ]; then
    echo "No RPMs found under ${rpm_dir}" >&2
    exit 1
fi

find_package_rpm() {
    local wanted_name="$1"
    local rpm_path
    local package_name
    local -a matches=()

    for rpm_path in "${all_rpms[@]}"; do
        package_name="$(rpm -qp --queryformat '%{NAME}' "${rpm_path}")"
        if [ "${package_name}" = "${wanted_name}" ]; then
            matches+=("${rpm_path}")
        fi
    done

    if [ "${#matches[@]}" -ne 1 ]; then
        echo "Expected exactly one ${wanted_name} RPM, found ${#matches[@]}" >&2
        return 1
    fi
    printf '%s\n' "${matches[0]}"
}

required_packages=(munge munge-libs slurm slurm-slurmctld)
if [ "${expect_pmix}" = "true" ]; then
    required_packages+=(pmix pmix3 pmix3-libpmi)
fi

install_rpms=()
for package_name in "${required_packages[@]}"; do
    install_rpms+=("$(find_package_rpm "${package_name}")")
done

printf 'Installing smoke-test RPMs:\n'
printf '  %s\n' "${install_rpms[@]}"
dnf install -y --nogpgcheck "${install_rpms[@]}"

# Without a local configuration, srun enters configless discovery before it
# processes --version/--mpi=list.  A minimal valid configuration keeps these
# smoke checks self-contained and does not require a running controller.
smoke_slurm_conf="$(mktemp)"
trap 'rm -f "${smoke_slurm_conf}"' EXIT
printf 'ClusterName=smoke-test\nSlurmctldHost=localhost\n' > "${smoke_slurm_conf}"

expected_output="slurm ${expected_slurm_version}"
for binary in slurmctld srun; do
    actual_output="$(SLURM_CONF="${smoke_slurm_conf}" "${binary}" --version)"
    printf '%s --version: %s\n' "${binary}" "${actual_output}"
    if [ "${actual_output}" != "${expected_output}" ]; then
        echo "Unexpected ${binary} version; expected ${expected_output}" >&2
        exit 1
    fi
done

mapfile -d '' -t pmix_plugins < <(
    find /usr/lib64 /usr/lib -type f -path '*/slurm/mpi_pmix*.so' -print0 2>/dev/null
)

if [ "${expect_pmix}" = "false" ]; then
    if [ "${#pmix_plugins[@]}" -ne 0 ]; then
        echo "Found PMIx plugins in a no-PMIx build:" >&2
        printf '  %s\n' "${pmix_plugins[@]}" >&2
        exit 1
    fi
    echo "No PMIx plugins present, as expected"
    exit 0
fi

if [ "${#pmix_plugins[@]}" -eq 0 ]; then
    echo "No Slurm PMIx plugin was installed" >&2
    exit 1
fi

for plugin in "${pmix_plugins[@]}"; do
    linkage="$(ldd "${plugin}")"
    printf 'Linkage for %s:\n%s\n' "${plugin}" "${linkage}"
    if grep -q 'not found' <<< "${linkage}"; then
        echo "Unresolved runtime dependency in ${plugin}" >&2
        exit 1
    fi
done

# Slurm's PMIx plugins intentionally leave PMIx API symbols for the plugin
# loader to resolve, so they do not have a direct libpmix.so DT_NEEDED entry.
# Successful plugin discovery by srun is the functional linkage check.
mpi_list="$(SLURM_CONF="${smoke_slurm_conf}" srun --mpi=list 2>&1)"
printf '%s\n' "${mpi_list}"
if ! grep -qi 'pmix' <<< "${mpi_list}"; then
    echo "srun did not report PMIx support" >&2
    exit 1
fi
