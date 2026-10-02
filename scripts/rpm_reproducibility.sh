#!/usr/bin/env bash
# Sourced by the build_*.sh scripts inside the builder containers.
#
# Configures rpmbuild for reproducible output when SOURCE_DATE_EPOCH is set:
# RPM BUILDTIME comes from SOURCE_DATE_EPOCH instead of the wall clock, payload
# file mtimes newer than SOURCE_DATE_EPOCH are clamped to it, and BUILDHOST is
# a constant instead of the (random) container hostname.

configure_reproducible_rpmbuild() {
    if [ -z "${SOURCE_DATE_EPOCH:-}" ]; then
        echo "SOURCE_DATE_EPOCH is not set; RPM build times and hosts will not be reproducible" >&2
        return 0
    fi
    if [[ ! "${SOURCE_DATE_EPOCH}" =~ ^[0-9]+$ ]]; then
        echo "SOURCE_DATE_EPOCH must be a non-negative integer: ${SOURCE_DATE_EPOCH}" >&2
        return 1
    fi
    export SOURCE_DATE_EPOCH

    # rpm's macro is spelled clamp_mtime_to_source_date_epoch.
    # source_date_epoch_from_changelog is disabled explicitly so the value
    # passed in from the manifest/commit time is the only source of truth.
    cat >> "${HOME}/.rpmmacros" <<'MACROS'
%use_source_date_epoch_as_buildtime 1
%clamp_mtime_to_source_date_epoch 1
%source_date_epoch_from_changelog 0
%_buildhost reproducible
MACROS
    echo "Reproducible rpmbuild: SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH}"
}
