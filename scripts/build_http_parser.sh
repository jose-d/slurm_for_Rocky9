#!/usr/bin/env bash
# Rebuild http-parser from a signed distribution source RPM (Rocky 9 AppStream)
# for tuples whose distribution no longer ships it (EL10). Slurm needs it for
# slurmrestd. Runs inside the Slurm builder image, like build_munge.sh.

set -euo pipefail

HTTP_PARSER_RELTAG="${HTTP_PARSER_RELTAG:?HTTP_PARSER_RELTAG must be set}"
HTTP_PARSER_VERSION="${HTTP_PARSER_VERSION:?HTTP_PARSER_VERSION must be set}"
HTTP_PARSER_SRPM="${HTTP_PARSER_SRPM:?HTTP_PARSER_SRPM (file name) must be set}"
GITHUB_WORKSPACE="${GITHUB_WORKSPACE:?GITHUB_WORKSPACE must be set}"
DISTRO="${DISTRO:?DISTRO must be set}"

# shellcheck source=scripts/rpm_reproducibility.sh
source "$(dirname "${BASH_SOURCE[0]}")/rpm_reproducibility.sh"
configure_reproducible_rpmbuild

echo "HTTP_PARSER_RELTAG: ${HTTP_PARSER_RELTAG}, HTTP_PARSER_VERSION: ${HTTP_PARSER_VERSION}, HTTP_PARSER_SRPM: ${HTTP_PARSER_SRPM}"

set -x

srpm="${GITHUB_WORKSPACE}/${HTTP_PARSER_SRPM}"
if [ ! -f "${srpm}" ]; then
    echo "http-parser source RPM not found: ${srpm}" >&2
    exit 1
fi

# Optional OpenPGP check of the source RPM, in a throw-away rpm database so
# the builder image's keyring is neither used nor modified. The key file is
# downloaded (and SHA-256 verified) by the caller; the expected fingerprint
# comes from the manifest.
if [ -n "${HTTP_PARSER_SIGNING_KEY:-}" ]; then
    expected_fingerprint="${HTTP_PARSER_SIGNING_KEY_FINGERPRINT:?HTTP_PARSER_SIGNING_KEY_FINGERPRINT must be set with HTTP_PARSER_SIGNING_KEY}"
    expected_fingerprint="$(tr -d '[:space:]' <<< "${expected_fingerprint}" | tr '[:upper:]' '[:lower:]')"
    expected_keyid="${expected_fingerprint: -8}"
    keyring="$(mktemp -d)"
    rpmdb --dbpath "${keyring}" --initdb
    rpmkeys --dbpath "${keyring}" --import "${GITHUB_WORKSPACE}/${HTTP_PARSER_SIGNING_KEY}"
    imported="$(rpm --dbpath "${keyring}" -q gpg-pubkey --qf '%{VERSION}\n' | tr '[:upper:]' '[:lower:]')"
    if [ "$(wc -l <<< "${imported}")" -ne 1 ] \
        || { [ "${imported}" != "${expected_fingerprint}" ] && [ "${imported}" != "${expected_keyid}" ]; }; then
        echo "Signing key file does not contain exactly the expected key ${expected_fingerprint} (got: ${imported})" >&2
        exit 1
    fi
    checksig="$(rpmkeys --dbpath "${keyring}" --checksig --verbose "${srpm}" 2>&1)"
    printf '%s\n' "${checksig}"
    if grep -Eqi 'NOKEY|NOT OK|BAD' <<< "${checksig}" \
        || ! grep -Eqi "(key ID|key fingerprint:?) *(${expected_keyid}|${expected_fingerprint}):? *OK" <<< "${checksig}"; then
        echo "Signature check of ${HTTP_PARSER_SRPM} against ${expected_fingerprint} failed" >&2
        exit 1
    fi
    rm -rf "${keyring}"
fi

spec_name="$(rpm -qp --nosignature --qf '[%{FILENAMES}\n]' "${srpm}" | awk '/\.spec$/')"
if [ "$(wc -l <<< "${spec_name}")" -ne 1 ] || [ -z "${spec_name}" ]; then
    echo "Expected exactly one spec file in ${srpm}" >&2
    exit 1
fi
srpm_version="$(rpm -qp --nosignature --qf '%{VERSION}' "${srpm}")"
if [ "${srpm_version}" != "${HTTP_PARSER_VERSION}" ]; then
    echo "Source RPM version ${srpm_version} does not match manifest ${HTTP_PARSER_VERSION}" >&2
    exit 1
fi

# The spec BuildRequires meson. Builder images that predate this script do
# not contain it, so install it from the distribution repositories if needed.
if ! rpm -q meson >/dev/null 2>&1; then
    dnf -y install meson
fi

# Populates ~/rpmbuild/SOURCES and ~/rpmbuild/SPECS with the files' recorded
# modes and mtimes.
rpm -i --nosignature "${srpm}"
spec_path="${HOME}/rpmbuild/SPECS/${spec_name}"

# Keep the upstream release number and append the build's release tag, e.g.
# 6.20261002015628.el10, so the package is distinguishable from the
# distribution build it was rebuilt from.
sed -i -E "s/^(Release:[[:space:]]*)([0-9][0-9.]*)%\{\?dist\}[[:space:]]*$/\1\2.${HTTP_PARSER_RELTAG}%{?dist}/" "${spec_path}"
grep -Eq "^Release:[[:space:]]*[0-9][0-9.]*\.${HTTP_PARSER_RELTAG}%\{\?dist\}$" "${spec_path}" \
    || { echo "Spec patch failed: release tag not set in ${spec_path}" >&2; exit 1; }

# The rebuilt source RPM records every source's mode and mtime (and each binary
# RPM records the source RPM's digest); the spec was just rewritten under the
# caller's umask, so fix all of them.
mapfile -t source_files < <(rpm -qp --nosignature --qf '[%{FILENAMES}\n]' "${srpm}" | grep -v '\.spec$')
chmod 0644 "${spec_path}" "${source_files[@]/#/${HOME}/rpmbuild/SOURCES/}"
if [ -n "${SOURCE_DATE_EPOCH:-}" ]; then
    touch -d "@${SOURCE_DATE_EPOCH}" "${spec_path}" "${source_files[@]/#/${HOME}/rpmbuild/SOURCES/}"
fi

rpm -qa | sort > "${GITHUB_WORKSPACE}/image_http_parser_rpms_${DISTRO}.txt"

rpmbuild_cmd=(rpmbuild -ba "${spec_path}")
printf '%q ' "${rpmbuild_cmd[@]}" > "${GITHUB_WORKSPACE}/rpmbuild_http_parser_${DISTRO}.txt"
printf '\n' >> "${GITHUB_WORKSPACE}/rpmbuild_http_parser_${DISTRO}.txt"
"${rpmbuild_cmd[@]}"

# Record the rebuilt source RPM's file metadata and identity in the build log,
# so builds from different hosts can be compared.
for src_rpm in "${HOME}"/rpmbuild/SRPMS/http-parser-*.src.rpm; do
    rpm -qp --dump "${src_rpm}"
    rpm -qp --qf 'SRPM %{NEVR} buildhost=%{BUILDHOST} buildtime=%{BUILDTIME} cookie=%{COOKIE} sha256header=%{SHA256HEADER} payloaddigest=%{PAYLOADDIGEST}\n' "${src_rpm}"
    md5sum "${src_rpm}"
done

mkdir -p "${GITHUB_WORKSPACE}/rpms"
mapfile -d '' -t http_parser_rpms < <(find "${HOME}/rpmbuild/RPMS" -type f -name 'http-parser*.rpm' -print0)
if [ "${#http_parser_rpms[@]}" -eq 0 ]; then
    echo "No http-parser RPMs found after build" >&2
    exit 1
fi
cp "${http_parser_rpms[@]}" "${GITHUB_WORKSPACE}/rpms/"
