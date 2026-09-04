# Build of Slurm for Rocky8 and Rocky9

This repository automates the process of building the [Slurm](https://github.com/SchedMD/slurm) scheduler with [OpenPMIx](https://github.com/openpmix/openpmix) on Rocky Linux-compatible distributions, leveraging GitHub Actions for continuous integration and delivery.

Container images from the [jose-d/images](https://github.com/jose-d/images) repository are utilized.

Supported build tuples are listed in `build-manifest.json`, and the GitHub Actions workflow reads that manifest to build the selected matrix. Each tuple can stage multiple PMIx builds for a single Slurm build. EL9 currently builds Slurm 26.05.4 against PMIx 3.2.5 and PMIx 6.1.0, without UCX or DOCA. EL8 retains its independently configured Slurm version and UCX/DOCA feature set.

Start the `Build Slurm packages` workflow manually and choose `target_distro=el8`, `target_distro=el9`, or `target_distro=all`. The default is `all` for compatibility with existing invocations. For example:

```bash
gh workflow run build_slurm.yml --ref master -f target_distro=el9
```

For Rocky8/EL8 clusters that do not need PMIx or InfiniBand support, the repository also provides a separate `Build Slurm packages without PMIx` workflow. It uses the digest-pinned Rocky8 Slurm builder image with NVML/CUDA support enabled and skips the PMIx dependency entirely.

If the workflow needs to pull private GHCR images from `jose-d/images`, define an optional repository variable `GHCR_U` and a matching repository secret `GHCR_S`; otherwise the workflow falls back to the current repository owner and `GITHUB_TOKEN`.

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
