#!/bin/bash

# print input vars
echo "PMIX_RELTAG: ${PMIX_RELTAG}, PMIX_VERSION: ${PMIX_VERSION}, PMIX_PACKAGE_NAME: ${PMIX_PACKAGE_NAME:-pmix}"

# enable shell debug
set -x

# stop on any error
set -e

# install deps
# N/A

PMIX_RELTAG="${PMIX_RELTAG:?PMIX_RELTAG must be set}"
PMIX_VERSION="${PMIX_VERSION:?PMIX_VERSION must be set}"
PMIX_SPEC_PATH="${PMIX_SPEC_PATH:?PMIX_SPEC_PATH must be set}"

if [ ! -f "${PMIX_SPEC_PATH}" ]; then
    echo "PMIX_SPEC_PATH does not exist: ${PMIX_SPEC_PATH}" >&2
    exit 1
fi

for required_spec_marker in \
    '%{!?reltag: %define reltag ' \
    'Release: %{reltag}%{?dist}' \
    '%if "%{name}" == "pmix"'
do
    if ! grep -Fq "${required_spec_marker}" "${PMIX_SPEC_PATH}"; then
        echo "PMIX_SPEC_PATH must point to the parameterized repo spec (missing: ${required_spec_marker})" >&2
        exit 1
    fi
done

# mkdir for rpmbuild and copy tarball there
mkdir -p "${HOME}/rpmbuild/SOURCES/"
cp "${GITHUB_WORKSPACE}/pmix-${PMIX_VERSION}.tar.bz2" "${HOME}/rpmbuild/SOURCES/"

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
