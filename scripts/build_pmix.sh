#!/bin/bash

# print input vars
echo "PMIX_RELTAG: ${PMIX_RELTAG}, PMIX_VERSION: ${PMIX_VERSION}, PMIX_SRCRPM_RELEASE: ${PMIX_SRCRPM_RELEASE}, PMIX_PACKAGE_NAME: ${PMIX_PACKAGE_NAME:-pmix}"

# enable shell debug
set -x

# stop on any error
set -e

# install deps
# N/A

PMIX_RELTAG="${PMIX_RELTAG:?PMIX_RELTAG must be set}"
PMIX_VERSION="${PMIX_VERSION:?PMIX_VERSION must be set}"
PMIX_SRCRPM_RELEASE="${PMIX_SRCRPM_RELEASE:?PMIX_SRCRPM_RELEASE must be set}"

PMIX_SRCRPM="${GITHUB_WORKSPACE}/pmix-${PMIX_VERSION}-${PMIX_SRCRPM_RELEASE}.src.rpm"

if [ ! -f "${PMIX_SRCRPM}" ]; then
    echo "src.rpm not found: ${PMIX_SRCRPM}" >&2
    exit 1
fi

# Install the src.rpm; this populates ~/rpmbuild/SOURCES with the tarball
# and ~/rpmbuild/SPECS with the upstream spec file.
rpm -i "${PMIX_SRCRPM}"

PMIX_SPEC_PATH="${HOME}/rpmbuild/SPECS/pmix.spec"

# Patch the upstream spec to support the shared opt_prefix_base layout,
# the datetime-based reltag, and the conditional Provides used when the
# package is renamed (e.g. pmix3).
# Note: sed address delimiters are '|' when the pattern itself contains '/'
# to avoid escaping, and '/' otherwise.

# 1. Insert opt_prefix_base default after the install_in_opt default line
sed -i '/^%{!?install_in_opt: %define install_in_opt 0}/a %{!?opt_prefix_base: %define opt_prefix_base /opt/pmix}' "${PMIX_SPEC_PATH}"
grep -Fq '%{!?opt_prefix_base: %define opt_prefix_base' "${PMIX_SPEC_PATH}" \
    || { echo "Spec patch failed: opt_prefix_base default not inserted (upstream spec may have changed)" >&2; exit 1; }

# 2. Insert reltag default after the opt_prefix_base default line
sed -i '/^%{!?opt_prefix_base: %define opt_prefix_base \/opt\/pmix}/a %{!?reltag: %define reltag 1}' "${PMIX_SPEC_PATH}"

# 3. Override Release to use the datetime reltag
sed -i 's/^Release: .*$/Release: %{reltag}%{?dist}/' "${PMIX_SPEC_PATH}"

# 4. Replace hardcoded /opt/%{name} paths with the configurable %{opt_prefix_base}
sed -i 's|/opt/%{name}|%{opt_prefix_base}|g' "${PMIX_SPEC_PATH}"

# 5. Wrap 'Provides: pmix' lines in a conditional so renamed packages
#    (e.g. pmix3) do not emit those provides
sed -i '/^Provides: pmix$/i %if "%{name}" == "pmix"' "${PMIX_SPEC_PATH}"
sed -i '/^Provides: pmix = %{version}$/a %endif' "${PMIX_SPEC_PATH}"

# Validate that all required patches were applied
for required_spec_marker in \
    '%{!?reltag: %define reltag ' \
    'Release: %{reltag}%{?dist}' \
    '%{opt_prefix_base}' \
    '%if "%{name}" == "pmix"' \
    '%endif'
do
    if ! grep -Fq "${required_spec_marker}" "${PMIX_SPEC_PATH}"; then
        echo "Spec patch failed (missing: ${required_spec_marker})" >&2
        exit 1
    fi
done

# Verify that no hardcoded /opt/%{name} path remains after patch #4
if grep -Fq '/opt/%{name}' "${PMIX_SPEC_PATH}"; then
    echo "Spec patch failed: hardcoded /opt/%{name} path still present after substitution" >&2
    exit 1
fi

# dump rpmlist for possible forensic
rpm -qa | sort > "${GITHUB_WORKSPACE}/image_pmix_rpms.txt"

# do rpmbuild
rpmbuild_cmd=(rpmbuild)

if [ -n "${PMIX_PACKAGE_NAME:-}" ] && [ "${PMIX_PACKAGE_NAME}" != "pmix" ]; then
    rpmbuild_cmd+=(--define "_name ${PMIX_PACKAGE_NAME}")
fi

"${rpmbuild_cmd[@]}" \
         --define 'build_all_in_one_rpm 0' \
         --define 'install_in_opt 1' \
         --define 'install_modulefile 1' \
         --define "reltag ${PMIX_RELTAG}" \
         --define "opt_prefix_base ${PMIX_OPT_PREFIX_BASE:-/opt/pmix}" \
         --define "configure_options ${PMIX_CONFIGURE_OPTIONS:---with-tests-examples --disable-per-user-config-files --with-munge=no --enable-pmix-binaries }" \
         -ba "${PMIX_SPEC_PATH}"

mkdir -p "${GITHUB_WORKSPACE}/rpms"
cp ${HOME}/rpmbuild/RPMS/x86_64/*.rpm ${GITHUB_WORKSPACE}/rpms/
