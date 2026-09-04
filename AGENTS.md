# Repository Guidelines

## Project Structure & Module Organization

- `build-manifest.json` is the source of truth for supported EL8/EL9 build tuples, versions, checksums, and digest-pinned container images.
- `.github/workflows/` contains the PMIx matrix build and the separate Rocky 8 no-PMIx workflow.
- `scripts/` contains the active Bash build, download, repository, and smoke-test helpers. `create_build_provenance.py` produces release provenance.
- `legacy/` preserves obsolete Apptainer recipes for reference; do not extend these for current builds.
- `README.md` documents published RPM repositories, credentials, and release behavior.

## Build, Test, and Development Commands

Full package builds run in GitHub Actions because they depend on pinned GHCR builder images:

```bash
gh workflow run build_slurm.yml --ref master
gh workflow run build_slurm_without_pmix.yml --ref master
```

Before pushing, run lightweight local checks:

```bash
bash -n scripts/*.sh
python3 -m py_compile scripts/create_build_provenance.py
python3 -m json.tool build-manifest.json >/dev/null
git diff --check
```

Given downloaded RPMs and a matching Rocky container, run `scripts/smoke_test_rpms.sh RPM_DIR VERSION true`; use `false` for the no-PMIx build.

## Coding Style & Naming Conventions

Use four-space indentation in Bash and Python, and two spaces in workflow YAML. Bash scripts must begin with `#!/usr/bin/env bash` and use `set -euo pipefail`. Quote variable expansions, use `snake_case` for functions and local variables, and reserve `UPPER_CASE` for exported configuration. Keep workflow jobs and artifact names distro-specific, such as `el8-slurm_rpms`.

Pin external Actions and container images by immutable SHA/digest. Add a SHA-256 checksum whenever introducing or updating downloaded source material.

## Testing Guidelines

There is no unit-test suite or coverage threshold. The release gate is the fresh-container smoke test: install RPMs, verify `slurmctld` and `srun` versions, check runtime linkage, and confirm PMIx presence or absence. Test every affected distro and build variant. Publishing must continue to depend on successful smoke-test jobs.

## Commit & Pull Request Guidelines

Use short, imperative commit subjects, for example `Pin and verify build inputs` or `Fix smoke test runtime setup`. Keep each commit focused. Pull requests should describe affected tuples, explain manifest or dependency changes, link the relevant issue, and list commands or workflow runs used for verification. Include logs instead of screenshots for CI or packaging changes.

## Security & Release Configuration

Never commit GHCR credentials; use `GHCR_U`, `GHCR_S`, or `GITHUB_TOKEN`. Preserve checksum verification and provenance generation. Published RPM repository files currently use `gpgcheck=0`, so do not claim package-signature verification.
