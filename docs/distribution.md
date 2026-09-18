# Packaging and release

## Build and validate

Use the checked-in lockfile and Pixi 0.80.0, matching CI:

```sh
pixi install --locked -e default -e oracle -e packaging
pixi run --locked check
pixi run --locked -e oracle test-interop --assertions all
pixi run --locked -e oracle test-interop --assertions none
pixi run --locked -e packaging conda-build
```

The release recipe builds from the checkout, includes Apache and third-party
license texts, and installs the library under `lib/mojo`. Its test environment
contains the built package and compiler, with no checkout source include path.
It compiles/runs the full suite with ASSERT=all and ASSERT=none and runs the example.
Build outputs are under `build/conda/linux-64/`.

The existing `pixi-build-mojo` manifest remains available for local path dependencies.
Use the explicit Conda recipe above for release artifacts and its installation/
license tests. Neither workflow publishes to a package channel.

Current local verification status is recorded in [release readiness](release-status.md).

## First release sequence

The candidate version is 0.1.0. The repository is
[idlab-discover/mojo-snappy](https://github.com/idlab-discover/mojo-snappy); remote and package URL metadata are configured.

1. Commit the reviewed license, CI, recipe, lockfile and release documentation.
   Push the release branch and require both GitHub CI jobs to pass.
2. Confirm workspace, package and recipe versions all equal 0.1.0 and review
   [release notes](release-0.1.0.md). Tag that exact validated commit `v0.1.0`.
3. Push the tag and wait for its CI run. Download its `mojo-snappy-conda-linux-64`
   artifact; check `SOURCE_COMMIT` against the tag and verify `SHA256SUMS`.
4. Create a draft GitHub release for the existing tag with the release notes,
   `.conda` file, checksum file and source-commit record. Review and publish it.

Do not move an existing release tag. A local package or CI artifact does not mean
that the package is available through a public Conda channel. Channel publication
is a separate step requiring a chosen channel and credentials; an upstream recipe
submission should use the release commit/hash instead of `source: path: ..`.
PyPI distribution is not configured, and a Conda package is not a Python wheel.

## CI behavior

The workflow runs on pushes, pull requests and manual dispatch. It uses pinned
GitHub action revisions, locked Pixi environments, read-only repository permission,
and uploads the Conda artifact with SHA256 checksums and exact checkout commit.
It does not create tags, GitHub releases or channel uploads automatically.

Reference patterns were adapted from the local Balsa project. Implementation
references: [setup-pixi](https://github.com/prefix-dev/setup-pixi),
[Rattler recipe/tests](https://rattler-build.prefix.dev/latest/reference/recipe_file/),
[Pixi Mojo backend](https://pixi.prefix.dev/latest/build/backends/pixi-build-mojo/).
