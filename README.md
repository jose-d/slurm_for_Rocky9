# Build of Slurm for Rocky8, Rocky9 and Rocky10

This repository automates the process of building the [Slurm](https://github.com/SchedMD/slurm) scheduler with [OpenPMIx](https://github.com/openpmix/openpmix) on Rocky Linux-compatible distributions, leveraging GitHub Actions for continuous integration and delivery.

Container images from the [jose-d/images](https://github.com/jose-d/images) repository are utilized.

Supported build tuples are listed in `build-manifest.json`, and the GitHub Actions workflow reads that manifest to build the selected matrix. Each tuple can stage multiple PMIx builds for a single Slurm build. EL9 currently builds Slurm 26.05.4 against PMIx 3.2.5 and PMIx 6.1.0, without UCX or DOCA. EL8 retains its independently configured Slurm version and UCX/DOCA feature set.

EL10 builds Slurm 25.11.8 against PMIx 3.2.5 and PMIx 6.1.0 with UCX (from DOCA 3.5.0), NVML (CUDA 13.4 `cuda-nvml-devel` from NVIDIA's RHEL10 repository), RPATH and `slurmrestd`, using an http-parser package rebuilt from Rocky 9 (see [EL10](#el10)). Slurm daemons must not be newer than the `slurmctld` they talk to.

Start the `Build Slurm packages` workflow manually and choose `target_distro=el8`, `target_distro=el9`, `target_distro=el10`, or `target_distro=all`. The default is `all` for compatibility with existing invocations. For example:

```bash
gh workflow run build_slurm.yml --ref master -f target_distro=el9
```

For Rocky8/EL8 clusters that do not need PMIx or InfiniBand support, the repository also provides a separate `Build Slurm packages without PMIx` workflow. It uses the digest-pinned Rocky8 Slurm builder image with NVML/CUDA support enabled and skips the PMIx dependency entirely.

If the workflow needs to pull private GHCR images from `jose-d/images`, define an optional repository variable `GHCR_U` and a matching repository secret `GHCR_S`; otherwise the workflow falls back to the current repository owner and `GITHUB_TOKEN`.

The optional `reltag` input selects the RPM release tag: empty keeps the previous behaviour (the current UTC timestamp), `commit` derives it from the commit time (the same value `scripts/build_local.sh` uses), and any other value is used verbatim. RPM build times always come from `SOURCE_DATE_EPOCH`, the commit time.

## Local builds

`scripts/build_local.sh DISTRO` runs the workflow's sequence (every PMIx build, Munge, Slurm, then the smoke test in a fresh runtime container) on any Linux host with podman, reading all inputs from `build-manifest.json` and verifying every source with `scripts/download_verified.sh`:

```bash
git clone https://github.com/jose-d/slurm_for_Rocky9.git
git clone https://github.com/jose-d/images.git     # only needed for local builder images
cd slurm_for_Rocky9
scripts/build_local.sh el10
```

The result is `local-build/rpm_tarball_<distro>_<RELTAG>.tar.gz` with the workflow's `rpms/{pmix,munge,slurm}/` layout (plus `rpms/http-parser/` for EL10); logs, `rpmbuild` commands and builder package lists are in `local-build/<distro>/logs/`. Digest-pinned builder images are pulled when available; otherwise (for example while the manifest still has placeholder references, or for private images) the builder images are built locally from `../images/docker/<dist>/<image>/Dockerfile`, including their parent images. Useful variables: `RELTAG`, `SOURCE_DATE_EPOCH`, `IMAGES_REPO`, `LOCAL_IMAGES=auto|always|never`, `REBUILD_IMAGES=1`, `OUTPUT_DIR`, `CONTAINER_ENGINE` (see the script header).

### Reproducibility

- `SOURCE_DATE_EPOCH` defaults to the committer time of `HEAD`; `RELTAG` defaults to that time formatted as `%Y%m%d%H%M%S` (the workflow's format). Both can be overridden, for example `RELTAG=20260505090930 scripts/build_local.sh el10`.
- Every `rpmbuild` runs with `%use_source_date_epoch_as_buildtime 1`, `%clamp_mtime_to_source_date_epoch 1`, `%source_date_epoch_from_changelog 0` and `%_buildhost reproducible` (`scripts/rpm_reproducibility.sh`), in a container with the fixed hostname `reproducible` and the fixed workspace `/workspace`.
- Builder and runtime images are pinned by digest in the manifest. Locally built builder images are not pinned (they install the newest packages at image build time), so only builds from the same image are expected to be bit-identical; publish the images and pin them for cross-host reproducibility.
- The local tarball itself is deterministic (sorted, fixed owner and mtime, `gzip -n`).

## EL10

The EL10 builder images are published from `jose-d/images` (`docker/rocky10/`, workflow `Build Rocky10 Docker imgs`) and pinned by digest in the `el10` tuple. A tuple whose images are not digest-pinned is skipped for `target_distro=all` (with a warning) and refused for an explicit distro; `scripts/build_local.sh` then builds the images locally. To publish new images:

1. Run the `Build Rocky10 Docker imgs` workflow (`gh workflow run docker_rocky10_build_base.yml -R jose-d/images`).
2. Look up the digests of the pushed `latest` (or run-id) tags, for example `skopeo inspect --format '{{.Digest}}' docker://ghcr.io/jose-d/images/rocky10_pmix-build:latest` (or `podman pull` and `podman image inspect --format '{{.Digest}}'`), for `rocky10_pmix-build` and `rocky10_slurm-build`.
3. Replace `pmix_builder_image` and `slurm_builder_image` of the `el10` tuple with `ghcr.io/jose-d/images/rocky10_<image>@sha256:<digest>` and rebuild.

The EL10 smoke test additionally requires every plugin in the tuple's `expected_slurm_plugins` and checks that all installed plugins resolve their libraries from Rocky 10 (with CRB), EPEL 10 and DOCA 3.5.0 (except the driver's `libnvidia-ml`).

The EL8 tuple's `expected_slurm_plugins` lists the plugins the Phoebe Slurm server and its EL8 nodes rely on (taken from their 25.11.5 installations, minus `data_parser_v0_0_41`, which Slurm 26.05 removed), so the smoke test fails if a release drops one of them. The same library-resolution check runs against Rocky 8 and EPEL 8.

### http-parser

Slurm 25.11 needs [http-parser](https://github.com/nodejs/http-parser) for `slurmrestd` and its `http_parser_libhttp_parser`, `rest_auth_*` and `openapi_*` plugins, but Rocky 10 (BaseOS, AppStream, CRB) and EPEL 10 no longer ship it. The `el10` tuple therefore has an `http_parser` entry, and the workflow's `build_http_parser` job (or the corresponding `scripts/build_local.sh` step) rebuilds Rocky 9 AppStream's `http-parser-2.9.4-6.el9.src.rpm` in the EL10 Slurm builder with `scripts/build_http_parser.sh`:

- the source RPM and the Rocky 9 release key (`RPM-GPG-KEY-Rocky-9`) are downloaded with their SHA-256 checksums from the manifest, and the source RPM's signature is verified against that key (fingerprint `21CB 256A E16F C54C 6E65 2949 702D 426D 350D 275D`) in a throw-away rpm database;
- the release becomes `6.<RELTAG>.el10` (upstream release plus the build's release tag), with the same reproducibility settings as the other packages;
- the resulting `http-parser` and `http-parser-devel` are installed from a local repository before the Slurm build, like Munge, and published in `rpms/http-parser/` of the release tarball and in the EL10 DNF repository. EL10 nodes need them installed together with `slurm`.

Tuples without an `http_parser` entry (EL8, EL9) keep using the distribution's http-parser and are unchanged. The spec's `BuildRequires: meson` is installed at build time if the builder image does not contain it.

This is a stop-gap for Slurm 25.11. SchedMD [bug 21801](https://support.schedmd.com/show_bug.cgi?id=21801) (a duplicate of [bug 20785](https://support.schedmd.com/show_bug.cgi?id=20785)) tracks the dependency on the unmaintained http-parser: Slurm 26.05.0 adds `http_parser/llhttp_parser` and `url_parser/internal`, and that is not backported to 25.11. Rocky 10 AppStream ships `llhttp`/`llhttp-devel` 9.1.3, so when the `el10` tuple moves to Slurm 26.05 it should build against llhttp and drop the `http_parser` entry and package.

## HTTP RPM repositories

A successful workflow publishes a GitHub Release containing the selected distro RPM archives, logs, and filtered build provenance. It also regenerates and deploys the [GitHub Pages](https://jose-d.github.io/slurm_for_Rocky9/) DNF/YUM repository from the selected build artifacts after their smoke tests pass. A distro-only run therefore publishes that distro's repository, while `target_distro=all` publishes separate repositories for both EL8 and EL9.

Install the appropriate repository configuration and refresh the metadata, for example on EL9:

```bash
sudo dnf config-manager --add-repo https://jose-d.github.io/slurm_for_Rocky9/slurm-for-rocky-el9.repo
sudo dnf makecache
```

The generated repository configuration currently has `gpgcheck=0` because these RPMs are not signed. GitHub Releases retain the versioned build archives; the HTTP repository is replaced by the latest successful build.

## Build provenance

Every release includes a `build-provenance.json` file (or `build-provenance-no-pmix.json`) and the same file is retained as a workflow artifact. It records the repository commit and workflow run, source URLs and SHA-256 checksums, builder image digests, exact shell-escaped `rpmbuild` commands, and the installed package list from every builder image.

Before publishing, each RPM set is installed in a fresh digest-pinned Rocky Linux container. The smoke test checks the reported `slurmctld` and `srun` versions and verifies that PMIx plugins have resolvable runtime linkage. The no-PMIx build is checked to ensure that it contains no PMIx plugin.

## Acknowledgments

I was inspired by the work done by the [c3se](https://github.com/c3se) team, as showcased in their [repository](https://github.com/c3se/containers/tree/master/rpm-builds). Additionally, I greatly benefited from the advice shared by the community on the EasyBuild Slack and from the [insightful talk](https://github.com/easybuilders/easybuild/wiki/EasyBuild-tech-talks-I:-Open-MPI) organized by EasyBuild, which can be found on their [Tech Talks](https://easybuild.io/tech-talks/) page.
