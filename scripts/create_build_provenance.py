#!/usr/bin/env python3

import argparse
import copy
import json
import os
import re
from datetime import datetime, timezone
from pathlib import Path


def parse_args():
    parser = argparse.ArgumentParser(description="Create a consolidated build provenance manifest")
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--fragments", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--commit-sha", required=True)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--workflow", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--run-attempt", required=True)
    parser.add_argument("--server-url", required=True)
    parser.add_argument("--distro")
    parser.add_argument("--build-label")
    parser.add_argument("--exclude-pmix", action="store_true")
    parser.add_argument("--helper-image")
    return parser.parse_args()


def require_sha256(value, label):
    if not re.fullmatch(r"[0-9a-fA-F]{64}", value):
        raise ValueError(f"Invalid SHA-256 for {label}: {value!r}")
    return value.lower()


def require_digest_reference(value, label):
    if not re.search(r"@sha256:[0-9a-fA-F]{64}$", value):
        raise ValueError(f"Image is not digest-pinned for {label}: {value!r}")
    return value


def main():
    args = parse_args()
    manifest = json.loads(args.manifest.read_text())
    builds = manifest["builds"]
    if args.distro:
        builds = [build for build in builds if build["distro"] == args.distro]
        if len(builds) != 1:
            raise ValueError(f"Expected one manifest build for distro {args.distro!r}")

    selected_builds = []
    sources = {}
    images = []

    def add_source(key, component, version, url, sha256, distro):
        sha256 = require_sha256(sha256, key)
        if key not in sources:
            sources[key] = {
                "component": component,
                "version": version,
                "url": url,
                "sha256": sha256,
                "distros": [],
            }
        elif sources[key]["url"] != url or sources[key]["sha256"] != sha256:
            raise ValueError(f"Inconsistent source metadata for {key}")
        sources[key]["distros"].append(distro)

    for original_build in builds:
        build = copy.deepcopy(original_build)
        distro = args.build_label or build["distro"]
        build["distro"] = distro
        build["with_pmix"] = not args.exclude_pmix

        slurm_version = build["slurm_version"]
        add_source(
            f"slurm-{slurm_version}",
            "slurm",
            slurm_version,
            f"https://download.schedmd.com/slurm/slurm-{slurm_version}.tar.bz2",
            build["slurm_sha256"],
            distro,
        )
        munge_version = build["munge_version"]
        add_source(
            f"munge-{munge_version}",
            "munge",
            munge_version,
            f"https://github.com/dun/munge/releases/download/munge-{munge_version}/munge-{munge_version}.tar.xz",
            build["munge_sha256"],
            distro,
        )

        images.append(
            {
                "distro": distro,
                "purpose": "slurm-and-munge-builder",
                "reference": require_digest_reference(
                    build["slurm_builder_image"], f"{distro} Slurm builder"
                ),
            }
        )

        if args.exclude_pmix:
            build["pmix_builds"] = []
            build.pop("pmix_builder_image", None)
            build.pop("slurm_ucx_path", None)
            build["slurm_with_ucx"] = False
        else:
            images.append(
                {
                    "distro": distro,
                    "purpose": "pmix-builder",
                    "reference": require_digest_reference(
                        build["pmix_builder_image"], f"{distro} PMIx builder"
                    ),
                }
            )
            for pmix in build["pmix_builds"]:
                version = pmix["version"]
                release = pmix.get("pmix_srcrpm_release", "1")
                filename = f"pmix-{version}-{release}.src.rpm"
                add_source(
                    f"pmix-{version}-{release}",
                    "pmix",
                    version,
                    f"https://github.com/openpmix/openpmix/releases/download/v{version}/{filename}",
                    pmix["sha256"],
                    distro,
                )

        selected_builds.append(build)

    if args.helper_image:
        images.append(
            {
                "purpose": "rpm-repository-helper",
                "reference": require_digest_reference(args.helper_image, "RPM repository helper"),
            }
        )

    command_files = sorted(args.fragments.glob("rpmbuild_*.txt"))
    package_files = sorted(args.fragments.glob("image_*_rpms_*.txt"))
    if not command_files:
        raise ValueError(f"No rpmbuild command fragments found in {args.fragments}")
    if not package_files:
        raise ValueError(f"No image package lists found in {args.fragments}")

    provenance = {
        "schema_version": 1,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "repository": {
            "name": args.repository,
            "commit_sha": args.commit_sha,
            "workflow": args.workflow,
            "run_id": args.run_id,
            "run_attempt": args.run_attempt,
            "run_url": f"{args.server_url}/{args.repository}/actions/runs/{args.run_id}",
        },
        "builds": selected_builds,
        "sources": list(sources.values()),
        "images": images,
        "rpmbuild_commands": {
            path.name: path.read_text().strip() for path in command_files
        },
        "image_package_lists": {
            path.name: path.read_text().splitlines() for path in package_files
        },
    }

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(provenance, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
