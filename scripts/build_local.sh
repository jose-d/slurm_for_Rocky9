#!/usr/bin/env bash
# Build one manifest tuple locally with podman, in the same sequence as
# .github/workflows/build_slurm.yml: PMIx builds, Munge, Slurm, then the
# fresh-container smoke test. Produces rpm_tarball_<distro>_<RELTAG>.tar.gz
# with the workflow's rpms/{pmix,munge,slurm}/ layout.
#
# Usage: scripts/build_local.sh DISTRO
#
# Environment (all optional):
#   RELTAG             RPM release tag. Default: UTC timestamp (%Y%m%d%H%M%S)
#                      of SOURCE_DATE_EPOCH, i.e. the workflow's format.
#   SOURCE_DATE_EPOCH  Default: committer time of the repository's HEAD.
#   OUTPUT_DIR         Default: <repo>/local-build
#   SOURCE_CACHE       Verified source downloads. Default: $OUTPUT_DIR/sources
#   IMAGES_REPO        jose-d/images checkout used to build builder images
#                      locally. Default: <repo>/../images
#   LOCAL_IMAGES       auto (default): use the pinned image when it is
#                      digest-pinned and pullable, else build it locally;
#                      always: always build locally; never: never build.
#   REBUILD_IMAGES     1 to rebuild local builder images even if present.
#   CONTAINER_ENGINE   Default: podman.
#   SKIP_SMOKE_TEST    1 to skip the smoke test (not recommended).

set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 DISTRO" >&2
    exit 2
fi

distro="$1"
if [[ ! "${distro}" =~ ^[A-Za-z0-9_-]+$ ]]; then
    echo "Invalid distro name: ${distro}" >&2
    exit 2
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
manifest="${repo_root}/build-manifest.json"
engine="${CONTAINER_ENGINE:-podman}"
output_dir="${OUTPUT_DIR:-${repo_root}/local-build}"
source_cache="${SOURCE_CACHE:-${output_dir}/sources}"
images_repo="${IMAGES_REPO:-${repo_root}/../images}"
local_images="${LOCAL_IMAGES:-auto}"
local_image_repository="localhost/jose-d/images"
local_image_tag="local"
# Fixed in-container workspace path and hostname so nothing host-specific
# leaks into the build.
container_workspace="/workspace"
container_hostname="reproducible"

log() {
    printf '\n==> %s\n' "$*"
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

command -v "${engine}" >/dev/null 2>&1 || die "${engine} is not installed"
command -v python3 >/dev/null 2>&1 || die "python3 is required to read the manifest"

case "${local_images}" in
    auto|always|never) ;;
    *) die "LOCAL_IMAGES must be auto, always or never" ;;
esac

# --- Manifest -----------------------------------------------------------------

manifest_get() {
    # Print one field of the selected tuple; lists are printed space-separated
    # and booleans as true/false, matching the workflow's environment values.
    python3 - "${manifest}" "${distro}" "$1" "${2-}" <<'PY'
import json
import sys

manifest_path, distro, key, default = sys.argv[1:5]
builds = [b for b in json.load(open(manifest_path))["builds"] if b["distro"] == distro]
if len(builds) != 1:
    sys.exit(f"Expected exactly one manifest build for {distro!r}, found {len(builds)}")
value = builds[0].get(key, default)
if isinstance(value, bool):
    value = "true" if value else "false"
elif isinstance(value, list):
    value = " ".join(str(item) for item in value)
print(value)
PY
}

pmix_builds_tsv() {
    python3 - "${manifest}" "${distro}" <<'PY'
import json
import sys

manifest_path, distro = sys.argv[1:3]
build = [b for b in json.load(open(manifest_path))["builds"] if b["distro"] == distro][0]
for item in build["pmix_builds"]:
    print("\t".join([
        item["version"],
        item.get("pmix_srcrpm_release", "1"),
        item["sha256"],
        item.get("package_name", "pmix"),
        item["install_path"],
    ]))
PY
}

manifest_get distro >/dev/null

script_dir="$(manifest_get script_dir)"
slurm_version="$(manifest_get slurm_version)"
slurm_sha256="$(manifest_get slurm_sha256)"
munge_version="$(manifest_get munge_version)"
munge_sha256="$(manifest_get munge_sha256)"
pmix_builder_ref="$(manifest_get pmix_builder_image)"
slurm_builder_ref="$(manifest_get slurm_builder_image)"
runtime_image="$(manifest_get runtime_image)"
nvml_version="$(manifest_get nvml_version)"
slurm_nvml_path="$(manifest_get slurm_nvml_path)"
slurm_ucx_path="$(manifest_get slurm_ucx_path)"
slurm_with_ucx="$(manifest_get slurm_with_ucx false)"
slurm_with_rpath="$(manifest_get slurm_with_rpath false)"
slurm_with_slurmrestd="$(manifest_get slurm_with_slurmrestd true)"
expected_slurm_plugins="$(manifest_get expected_slurm_plugins)"
mapfile -t pmix_builds < <(pmix_builds_tsv)
pmix_paths="$(printf '%s\n' "${pmix_builds[@]}" | cut -f5 | paste -sd:)"

[ "${script_dir}" = "scripts" ] || die "Only script_dir=scripts is supported locally"

# --- Deterministic release tag and timestamps ---------------------------------

if [ -z "${SOURCE_DATE_EPOCH:-}" ]; then
    SOURCE_DATE_EPOCH="$(git -C "${repo_root}" log -1 --format=%ct HEAD)" \
        || die "Cannot derive SOURCE_DATE_EPOCH from git; set it explicitly"
    if [ -n "$(git -C "${repo_root}" status --porcelain --untracked-files=no)" ]; then
        echo "WARNING: uncommitted changes; SOURCE_DATE_EPOCH/RELTAG come from HEAD" >&2
    fi
fi
[[ "${SOURCE_DATE_EPOCH}" =~ ^[0-9]+$ ]] || die "SOURCE_DATE_EPOCH must be an integer"
export SOURCE_DATE_EPOCH
RELTAG="${RELTAG:-$(date -u -d "@${SOURCE_DATE_EPOCH}" +%Y%m%d%H%M%S)}"
[[ "${RELTAG}" =~ ^[0-9A-Za-z_.+]+$ ]] || die "Invalid RELTAG: ${RELTAG}"

work_root="${output_dir}/${distro}/work"
log_dir="${output_dir}/${distro}/logs"
tarball="${output_dir}/rpm_tarball_${distro}_${RELTAG}.tar.gz"

echo "distro:            ${distro}"
echo "slurm:             ${slurm_version}"
echo "munge:             ${munge_version}"
echo "pmix:              $(printf '%s\n' "${pmix_builds[@]}" | awk -F'\t' '{printf "%s-%s ", $4, $1}')"
echo "RELTAG:            ${RELTAG}"
echo "SOURCE_DATE_EPOCH: ${SOURCE_DATE_EPOCH} ($(date -u -d "@${SOURCE_DATE_EPOCH}" --iso-8601=seconds))"
echo "engine:            ${engine} ($("${engine}" --version))"
echo "output:            ${tarball}"

# --- Builder images -------------------------------------------------------------

declare -A built_local_images=()

build_local_image() {
    # Build <dist>_<image> (e.g. rocky10_slurm-build) from
    # ${images_repo}/docker/<dist>/<image>/Dockerfile, building any parent
    # image of the same repository first.
    local name="$1"
    local dist="${name%%_*}"
    local image="${name#*_}"
    local context="${images_repo}/docker/${dist}/${image}"
    local target="${local_image_repository}/${name}:${local_image_tag}"
    local parent
    local -a build_args=()

    if [ -n "${built_local_images[${name}]:-}" ]; then
        return 0
    fi
    [ -f "${context}/Dockerfile" ] \
        || die "No Dockerfile for ${name} at ${context} (set IMAGES_REPO)"

    parent="$(sed -nE 's|^FROM[[:space:]]+\$\{IMAGE_REPOSITORY\}/([^:]+):.*|\1|p' "${context}/Dockerfile" | head -n 1)"
    if [ -n "${parent}" ]; then
        build_local_image "${parent}"
    fi

    if [ "${REBUILD_IMAGES:-0}" != "1" ] && "${engine}" image inspect "${target}" >/dev/null 2>&1; then
        echo "Using existing local image ${target}" >&2
    else
        build_args=(
            --build-arg "IMAGE_REPOSITORY=${local_image_repository}"
            --build-arg "IMAGE_TAG=${local_image_tag}"
        )
        if [ -n "${nvml_version}" ] && grep -q '^ARG NVML_VERSION' "${context}/Dockerfile"; then
            build_args+=(--build-arg "NVML_VERSION=${nvml_version}")
        fi
        log "Building local image ${target} from ${context}" >&2
        "${engine}" build "${build_args[@]}" -t "${target}" -f "${context}/Dockerfile" "${context}" \
            2>&1 | tee "${log_dir}/image_${name}.log" >&2
    fi
    built_local_images[${name}]=1
}

resolve_builder_image() {
    # resolve_builder_image REF VARIABLE: store the image reference to use for
    # a manifest builder image in VARIABLE. Runs in the main shell so local
    # builds are memoised across images.
    local ref="$1"
    local name

    if [ "${local_images}" != "always" ] && [[ "${ref}" =~ @sha256:[0-9a-f]{64}$ ]]; then
        if "${engine}" image inspect "${ref}" >/dev/null 2>&1 \
            || "${engine}" pull "${ref}" >&2; then
            printf -v "$2" '%s' "${ref}"
            return 0
        fi
        echo "Pinned image ${ref} is not available" >&2
    fi
    if [ "${local_images}" = "never" ]; then
        die "Image ${ref} is unavailable and LOCAL_IMAGES=never"
    fi
    name="${ref##*/}"
    name="${name%%@*}"
    name="${name%%:*}"
    build_local_image "${name}"
    printf -v "$2" '%s' "${local_image_repository}/${name}:${local_image_tag}"
}

# --- Helpers --------------------------------------------------------------------

new_workspace() {
    # Each workflow job starts from a clean checkout; mirror that.
    local workspace="${work_root}/$1"
    rm -rf "${workspace}"
    mkdir -p "${workspace}"
    cp -r "${repo_root}/scripts" "${workspace}/scripts"
    printf '%s\n' "${workspace}"
}

fetch() {
    # fetch URL FILENAME SHA256 DESTINATION_DIR
    mkdir -p "${source_cache}"
    (cd "${source_cache}" && "${repo_root}/scripts/download_verified.sh" "$1" "$2" "$3")
    cp "${source_cache}/$2" "$4/$2"
}

run_in() {
    # run_in WORKSPACE IMAGE LOGFILE [--env K=V ...] -- COMMAND...
    local workspace="$1" image="$2" logfile="$3"
    shift 3
    local -a env_args=()
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
        env_args+=("$1")
        shift
    done
    shift
    "${engine}" run --rm \
        --hostname "${container_hostname}" \
        --env "SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH}" \
        --env "GITHUB_WORKSPACE=${container_workspace}" \
        "${env_args[@]}" \
        -v "${workspace}:${container_workspace}:Z" \
        -w "${container_workspace}" \
        "${image}" \
        "$@" 2>&1 | tee "${logfile}"
}

createrepo_in() {
    # createrepo_in IMAGE DIRECTORY
    "${engine}" run --rm -v "$2:/repo:Z" "$1" createrepo_c /repo >/dev/null
}

# --- Build ----------------------------------------------------------------------

mkdir -p "${work_root}" "${log_dir}"
rpm_out="${output_dir}/${distro}/rpms"
rm -rf "${rpm_out}"
mkdir -p "${rpm_out}/pmix" "${rpm_out}/munge" "${rpm_out}/slurm"

log "Resolving builder images"
resolve_builder_image "${pmix_builder_ref}" pmix_image
resolve_builder_image "${slurm_builder_ref}" slurm_image
echo "PMIx builder:  ${pmix_image}"
echo "Slurm builder: ${slurm_image}"
echo "Runtime:       ${runtime_image}"

for pmix_build in "${pmix_builds[@]}"; do
    IFS=$'\t' read -r pmix_version pmix_release pmix_sha256 pmix_package pmix_install_path <<< "${pmix_build}"
    log "Building PMIx ${pmix_package} ${pmix_version}"
    ws="$(new_workspace "pmix-${pmix_package}-${pmix_version}")"
    srcrpm="pmix-${pmix_version}-${pmix_release}.src.rpm"
    fetch "https://github.com/openpmix/openpmix/releases/download/v${pmix_version}/${srcrpm}" \
        "${srcrpm}" "${pmix_sha256}" "${ws}"
    run_in "${ws}" "${pmix_image}" "${log_dir}/pmix_build_${distro}_${pmix_version}.log" \
        --env "DISTRO=${distro}" \
        --env "PMIX_RELTAG=${RELTAG}" \
        --env "PMIX_VERSION=${pmix_version}" \
        --env "PMIX_SRCRPM_RELEASE=${pmix_release}" \
        --env "PMIX_PACKAGE_NAME=${pmix_package}" \
        --env "PMIX_OPT_PREFIX_BASE=$(dirname "${pmix_install_path}")" \
        -- /bin/bash "${script_dir}/build_pmix.sh"
    cp "${ws}"/rpms/*.rpm "${rpm_out}/pmix/"
    cp "${ws}"/image_pmix_rpms_*.txt "${ws}"/rpmbuild_pmix_*.txt "${log_dir}/"
done

log "Building Munge ${munge_version}"
ws="$(new_workspace munge)"
fetch "https://github.com/dun/munge/releases/download/munge-${munge_version}/munge-${munge_version}.tar.xz" \
    "munge-${munge_version}.tar.xz" "${munge_sha256}" "${ws}"
run_in "${ws}" "${slurm_image}" "${log_dir}/munge_build_${distro}.log" \
    --env "DISTRO=${distro}" \
    --env "MUNGE_RELTAG=${RELTAG}" \
    --env "MUNGE_VERSION=${munge_version}" \
    -- /bin/bash "${script_dir}/build_munge.sh"
cp "${ws}"/rpms/*.rpm "${rpm_out}/munge/"
cp "${ws}"/image_munge_rpms_*.txt "${ws}"/rpmbuild_munge_*.txt "${log_dir}/"

log "Building Slurm ${slurm_version}"
ws="$(new_workspace slurm)"
mkdir -p "${ws}/pmix_rpms" "${ws}/munge_rpms"
cp "${rpm_out}"/pmix/*.rpm "${ws}/pmix_rpms/"
cp "${rpm_out}"/munge/*.rpm "${ws}/munge_rpms/"
createrepo_in "${slurm_image}" "${ws}/pmix_rpms"
createrepo_in "${slurm_image}" "${ws}/munge_rpms"
fetch "https://download.schedmd.com/slurm/slurm-${slurm_version}.tar.bz2" \
    "slurm-${slurm_version}.tar.bz2" "${slurm_sha256}" "${ws}"
(cd "${ws}" && "${repo_root}/scripts/prepare_slurm_spec.sh" "${slurm_version}" "${RELTAG}")
run_in "${ws}" "${slurm_image}" "${log_dir}/slurm_build_${distro}.log" \
    --env "DISTRO=${distro}" \
    --env "SLURM_RELTAG=${RELTAG}" \
    --env "SLURM_VERSION=${slurm_version}" \
    --env "SLURM_SPEC_PATH=./slurm-${slurm_version}/slurm.spec" \
    --env "SLURM_PMIX_PATHS=${pmix_paths}" \
    --env "SLURM_NVML_PATH=${slurm_nvml_path}" \
    --env "SLURM_UCX_PATH=${slurm_ucx_path}" \
    --env "SLURM_WITH_UCX=${slurm_with_ucx}" \
    --env "SLURM_WITH_RPATH=${slurm_with_rpath}" \
    --env "SLURM_WITH_SLURMRESTD=${slurm_with_slurmrestd}" \
    -- /bin/bash "${script_dir}/build_slurm.sh"
cp "${ws}"/rpms/slurm-*.rpm "${rpm_out}/slurm/"
cp "${ws}"/image_slurm_rpms_*.txt "${ws}"/rpmbuild_slurm_*.txt "${log_dir}/"

cuda_version="$("${engine}" run --rm -v "${repo_root}/scripts:/scripts:ro,Z" "${slurm_image}" \
    /bin/bash /scripts/detect_cuda.sh 2>/dev/null | tail -n 1 || echo unknown)"
printf '%s\n' "${cuda_version}" > "${log_dir}/cuda_version_${distro}.txt"
echo "CUDA/NVML version in Slurm builder: ${cuda_version}"

if [ "${SKIP_SMOKE_TEST:-0}" = "1" ]; then
    echo "WARNING: smoke test skipped" >&2
else
    log "Smoke testing ${distro} RPMs in a fresh ${runtime_image} container"
    ws="$(new_workspace smoke)"
    mkdir -p "${ws}/smoke_rpms"
    cp -r "${rpm_out}/pmix" "${rpm_out}/munge" "${rpm_out}/slurm" "${ws}/smoke_rpms/"
    run_in "${ws}" "${runtime_image}" "${log_dir}/smoke_test_${distro}.log" \
        --env "EXPECT_SLURM_PLUGINS=${expected_slurm_plugins}" \
        -- /bin/bash "${container_workspace}/scripts/smoke_test_rpms.sh" \
        "${container_workspace}/smoke_rpms" "${slurm_version}" true "${slurm_with_ucx}"
fi

log "Creating ${tarball}"
# Deterministic archive: sorted names, fixed owner and mtime, no gzip timestamp.
staging="$(mktemp -d)"
trap 'rm -rf "${staging}"' EXIT
mkdir -p "${staging}/rpms"
cp -r "${rpm_out}/pmix" "${rpm_out}/munge" "${rpm_out}/slurm" "${staging}/rpms/"
tar --sort=name --mtime="@${SOURCE_DATE_EPOCH}" --owner=0 --group=0 --numeric-owner \
    --format=gnu -C "${staging}" -cf - rpms | gzip -9 -n > "${tarball}"

log "Done"
tar -tzf "${tarball}"
echo "Tarball: ${tarball}"
echo "Logs:    ${log_dir}"
