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
license tests. This repository uploads CI artifacts; channel publication runs
through [modular/modular-community](https://github.com/modular/modular-community/tree/main/recipes/mojo-snappy).
The recipe lists [Str-Gen](https://github.com/Str-Gen) as maintainer.

Current local verification status is recorded in [release readiness](release-status.md).

## Versions and build numbers

A Conda artifact is identified by name, version and build string. This recipe
has no variant keys, so the build string is always `hb0f4dca_<build number>`
and the build number alone separates artifacts of one version. The
modular-community CI builds with `--skip-existing=all`: an unchanged
name/version/build is skipped, not rebuilt.

- New source or a new compiler pin: new library version and tag, build number 0.
- Same tagged source, recipe-only fix (metadata, tests, license files):
  same version, build number + 1.

0.2.0 builds 0 and 1 predate this rule; build 1 was compiled from `83a08c6`,
not from `v0.2.0`. See the table in the [0.2.1 release notes](release-0.2.1.md).

## Release sequence

1. Merge the release commit to `main` after both GitHub CI jobs pass. Workspace,
   package and recipe versions must all equal the release version, with build 0.
2. Tag that merge commit `v<version>` (annotated), push the tag and wait for its CI run.
   Download its `mojo-snappy-conda-linux-64` artifact; check `SOURCE_COMMIT`
   against the tag and verify `SHA256SUMS`.
3. Create a draft GitHub release for the tag with `docs/release-<version>.md`,
   the `.conda` file, checksum file and source-commit record. Review and publish it.
4. Update `recipes/mojo-snappy/recipe.yaml` in `modular/modular-community`:
   version, `mojo_version`, build number 0 and the tag's commit as `rev`. Build it
   locally with upstream's Rattler-Build version, variants and channel order,
   then open the PR with the upstream checklist. The package reaches
   `modular-community` only after a maintainer merges it and the upload job runs.

Do not move an existing release tag. A local package, CI artifact or GitHub
release does not mean that the package is available through a public Conda
channel. PyPI distribution is not configured, and a Conda package is not a
Python wheel.

## CI behavior

The workflow runs on pushes, pull requests and manual dispatch. It uses pinned
GitHub action revisions, locked Pixi environments, read-only repository permission,
and uploads the Conda artifact with SHA256 checksums and exact checkout commit.
It does not create tags, GitHub releases or channel uploads automatically.

Reference patterns were adapted from the local Balsa project. Implementation
references: [setup-pixi](https://github.com/prefix-dev/setup-pixi),
[Rattler recipe/tests](https://rattler-build.prefix.dev/latest/reference/recipe_file/),
[Pixi Mojo backend](https://pixi.prefix.dev/latest/build/backends/pixi-build-mojo/).

