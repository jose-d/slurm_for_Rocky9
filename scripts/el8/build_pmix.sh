#!/bin/bash

# print input vars
echo "PMIX_RELTAG: ${PMIX_RELTAG}, PMIX_VERSION: ${PMIX_VERSION}, PMIX_PACKAGE_NAME: ${PMIX_PACKAGE_NAME:-pmix}"

# enable shell debug
set -x

# stop on any error
set -e

# install deps
# N/A

# mkdir for rpmbuild and copy tarball there
mkdir -p "${HOME}/rpmbuild/SOURCES/"
cp "${GITHUB_WORKSPACE}/pmix-${PMIX_VERSION}.tar.bz2" "${HOME}/rpmbuild/SOURCES/"

# dump rpmlist for possible forensic
rpm -qa | sort > "${GITHUB_WORKSPACE}/image_pmix_rpms.txt"

# patch the spec for opt-prefix installs and parallel package names
python3 <<'PY'
import os
from pathlib import Path

spec_path = Path(f"./pmix-{os.environ['PMIX_VERSION']}/contrib/pmix.spec")
text = spec_path.read_text()

text = text.replace(
    "Release: 1%{?dist}",
    f"Release: {os.environ['PMIX_RELTAG']}%{{?dist}}",
    1,
)

if "%{!?opt_prefix_base: %define opt_prefix_base /opt/pmix}" not in text:
    text = text.replace(
        "%{!?install_in_opt: %define install_in_opt 0}\n",
        "%{!?install_in_opt: %define install_in_opt 0}\n%{!?opt_prefix_base: %define opt_prefix_base /opt/pmix}\n",
        1,
    )

for original in (
    "%define _prefix /opt/%{name}/%{version}",
    "%define _sysconfdir /opt/%{name}/%{version}/etc",
    "%define _libdir /opt/%{name}/%{version}/lib",
    "%define _includedir /opt/%{name}/%{version}/include",
    "%define _mandir /opt/%{name}/%{version}/man",
    "%define _pkgdatadir /opt/%{name}/%{version}/share/pmix",
    "%define _defaultdocdir /opt/%{name}/%{version}/doc",
    "%define modulefile_path /opt/%{name}/%{version}/share/pmixmodulefiles",
):
    text = text.replace(original, original.replace("/opt/%{name}", "%{opt_prefix_base}"))

if '%if "%{name}" == "pmix"\nProvides: pmix\nProvides: pmix = %{version}\n%endif' not in text:
    text = text.replace(
        "Provides: pmix\nProvides: pmix = %{version}",
        '%if "%{name}" == "pmix"\nProvides: pmix\nProvides: pmix = %{version}\n%endif',
        1,
    )

spec_path.write_text(text)
PY

# do rpmbuild
rpmbuild_cmd=(rpmbuild)

if [ -n "${PMIX_PACKAGE_NAME:-}" ] && [ "${PMIX_PACKAGE_NAME}" != "pmix" ]; then
    rpmbuild_cmd+=(--define "_name ${PMIX_PACKAGE_NAME}")
fi

"${rpmbuild_cmd[@]}" \
         --define 'build_all_in_one_rpm 0' \
         --define 'install_in_opt 1' \
         --define 'install_modulefile 1' \
         --define "opt_prefix_base ${PMIX_OPT_PREFIX_BASE:-/opt/pmix}" \
         --define "configure_options ${PMIX_CONFIGURE_OPTIONS:---with-tests-examples --disable-per-user-config-files --with-munge=no}" \
         -ba "./pmix-${PMIX_VERSION}/contrib/pmix.spec"

mkdir -p "${GITHUB_WORKSPACE}/rpms"
cp ${HOME}/rpmbuild/RPMS/x86_64/*.rpm ${GITHUB_WORKSPACE}/rpms/
