# First release readiness

As of 2026-09-18, the local 0.1.0 release candidate targets Linux x86-64 with
Mojo 1.0.0. This is a preparation record, not a published-release announcement.

Completed locally:

- Repository destination and package metadata: [idlab-discover/mojo-snappy](https://github.com/idlab-discover/mojo-snappy).

- Apache-2.0 license selection and preservation of Google Snappy notices.
- GitHub CI configuration with pinned actions and locked Pixi environments.
- Source, optimized, precompiled-package and example checks.
- PyArrow/cramjam interoperability: 72 fixtures in four directions, under each
  assertion policy.
- Conda release recipe and actual isolated installation tests: all 19 codec tests
  pass with ASSERT=all, all 19 with ASSERT=none, and the example passes.
- Artifact inspection confirms the compiler pin, installed library and both
  license documents. Existing default/oracle locked environments are unchanged.

The recipe uses build number 1: build 0 was already used for development artifacts.
The initial build-0 attempt hit an old cache entry and did not establish that the
new tests ran. Build 1 has explicit fresh installed-test output for both modes;
only that artifact is the current candidate.

Remaining before the first release:

- Push the reviewed release-preparation commit and obtain a passing hosted CI run.
- Tag the validated commit `v0.1.0`, then use its passing tag-build artifact for
  the GitHub release. No tag or publication has occurred yet.
- Select a Conda channel separately if channel installation is desired.

See [distribution](distribution.md) and [candidate release notes](release-0.1.0.md).
The codec implementation is unchanged from the accepted optimization baseline;
this release does not depend on further performance work.
