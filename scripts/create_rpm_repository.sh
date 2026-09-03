#!/usr/bin/env bash

set -euo pipefail

if [ "$#" -ne 3 ]; then
    echo "Usage: $0 RPM_SOURCE_DIR OUTPUT_DIR BASE_URL" >&2
    exit 2
fi

rpm_source_dir="$1"
output_dir="$2"
base_url="${3%/}"
createrepo_command="${CREATEREPO_C:-createrepo_c}"

if [ ! -d "${rpm_source_dir}" ]; then
    echo "RPM source directory does not exist: ${rpm_source_dir}" >&2
    exit 1
fi
if [ -z "${output_dir}" ] || [ "${output_dir}" = "/" ]; then
    echo "Refusing unsafe output directory: ${output_dir}" >&2
    exit 1
fi
if [ -e "${output_dir}" ] && find "${output_dir}" -mindepth 1 -print -quit | grep -q .; then
    echo "Output directory must be empty: ${output_dir}" >&2
    exit 1
fi
if [[ ! "${base_url}" =~ ^https?://[^/]+(/.*)?$ ]]; then
    echo "Base URL must be an HTTP or HTTPS URL: ${base_url}" >&2
    exit 1
fi
if ! command -v "${createrepo_command}" >/dev/null 2>&1; then
    echo "createrepo_c is required: ${createrepo_command}" >&2
    exit 1
fi

mapfile -t distros < <(
    find "${rpm_source_dir}" -type f -name '*.rpm' -exec basename '{}' ';' \
        | awk -F. '{for (i = 1; i <= NF; i++) if ($i ~ /^el[0-9]+$/) print $i}' \
        | sort -u
)

if [ "${#distros[@]}" -eq 0 ]; then
    echo "No RPM filenames with an .elN distribution suffix were found" >&2
    exit 1
fi

mkdir -p "${output_dir}"
touch "${output_dir}/.nojekyll"

index_entries=""
for distro in "${distros[@]}"; do
    if [[ ! "${distro}" =~ ^el[0-9]+$ ]]; then
        echo "Invalid distribution identifier: ${distro}" >&2
        exit 1
    fi

    repo_dir="${output_dir}/${distro}"
    mkdir -p "${repo_dir}"
    rpm_count=0

    while IFS= read -r -d '' rpm; do
        destination="${repo_dir}/$(basename "${rpm}")"
        if [ -e "${destination}" ]; then
            if ! cmp -s "${rpm}" "${destination}"; then
                echo "Conflicting RPMs have the same filename: ${destination}" >&2
                exit 1
            fi
        else
            cp "${rpm}" "${destination}"
            rpm_count=$((rpm_count + 1))
        fi
    done < <(find "${rpm_source_dir}" -type f -name "*.${distro}.*.rpm" -print0)

    if [ "${rpm_count}" -eq 0 ]; then
        echo "No RPMs copied for ${distro}" >&2
        exit 1
    fi

    "${createrepo_command}" --quiet "${repo_dir}"

    package_entries=""
    while IFS= read -r rpm_name; do
        package_entries+="<li><a href=\"${rpm_name}\">${rpm_name}</a></li>"
    done < <(find "${repo_dir}" -maxdepth 1 -type f -name '*.rpm' -printf '%f\n' | sort)

    cat > "${repo_dir}/index.html" <<EOF
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Slurm packages for ${distro}</title></head>
<body><h1>Slurm packages for ${distro}</h1><ul>${package_entries}</ul></body>
</html>
EOF

    repo_id="slurm-for-rocky-${distro}"
    cat > "${output_dir}/${repo_id}.repo" <<EOF
[${repo_id}]
name=Slurm packages for ${distro}
baseurl=${base_url}/${distro}
enabled=1
gpgcheck=0
metadata_expire=1h
EOF

    index_entries+="<li><a href=\"${distro}/\">${distro} repository</a> &mdash; <a href=\"${repo_id}.repo\">DNF configuration</a></li>"
done

cat > "${output_dir}/index.html" <<EOF
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Slurm RPM repositories</title>
</head>
<body>
  <h1>Slurm RPM repositories</h1>
  <p>Packages from the latest successful build of slurm_for_Rocky9.</p>
  <ul>${index_entries}</ul>
  <p>RPM signatures are not currently verified by these repository configurations.</p>
</body>
</html>
EOF
