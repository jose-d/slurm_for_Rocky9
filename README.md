# Build of Slurm for Rocky8 and Rocky9

This repository automates the process of building the [Slurm](https://github.com/SchedMD/slurm) scheduler with [OpenPMIx](https://github.com/openpmix/openpmix) on Rocky Linux-compatible distributions, leveraging GitHub Actions for continuous integration and delivery.

Container images from the [jose-d/images](https://github.com/jose-d/images) repository are utilized.

Supported build tuples are listed in `build-manifest.json`, and the GitHub Actions workflow reads that manifest to build the full matrix from a single workflow definition. Each tuple can stage multiple PMIx builds for a single Slurm build; the current manifest builds Slurm 25.11.5 against PMIx 3.2.5 and PMIx 6.1.0.

For Rocky8/EL8 clusters that do not need PMIx or InfiniBand support, the repository also provides a separate `Build Slurm packages without PMIx` workflow. It builds Slurm from `ghcr.io/jose-d/images/rocky8_slurm-build:latest` with NVML/CUDA support enabled and skips the PMIx dependency entirely.

If the workflow needs to pull private GHCR images from `jose-d/images`, define an optional repository variable `GHCR_U` and a matching repository secret `GHCR_S`; otherwise the workflow falls back to the current repository owner and `GITHUB_TOKEN`.

## Acknowledgments

I was inspired by the work done by the [c3se](https://github.com/c3se) team, as showcased in their [repository](https://github.com/c3se/containers/tree/master/rpm-builds). Additionally, I greatly benefited from the advice shared by the community on the EasyBuild Slack and from the [insightful talk](https://github.com/easybuilders/easybuild/wiki/EasyBuild-tech-talks-I:-Open-MPI) organized by EasyBuild, which can be found on their [Tech Talks](https://easybuild.io/tech-talks/) page.
