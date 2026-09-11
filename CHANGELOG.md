# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project aims to
follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html). No versions have been tagged yet,
so everything below sits under Unreleased until the first release is cut.

## [Unreleased]

### Added

- `models` now reports the metadata SAIA returns beyond the OpenAI model schema: the per-model
  `demand` figure for the deployment behind a model, its serving `status`, and the input modalities
  it accepts. Sorted by demand, so the contended deployments are at the top.
- `models --json` emits the raw model entries for scripting.
- `models --short` (`-s`, `--ids`) prints the plain id list.

### Changed

- **BREAKING:** `models` prints the metadata table instead of a bare id list. Scripts that parsed
  the ids want `models --short`. The metadata is the reason to run the command interactively, so it
  should not need a flag; the pipeline form is the one worth spelling out.

### Notes

- Fields absent from a response degrade to `-` rather than breaking the table, so the client still
  renders against a gateway or proxy that implements only the standard OpenAI schema.

## History before this changelog

Earlier work is recorded in the git log rather than here. The notable entries, by date:

- 2026-08: endpoint selection with `-e`/`--endpoint` and `SAIA_ENDPOINT`, accepted either before or
  after a subcommand, covering Academic Cloud, GWDG SAIA and any compatible gateway URL.
- 2026-08: rate-limit reset times shown by default for an active quota, and humanised; reset
  assigned to the exhausted quota window.
- 2026-08: automatic macOS Keychain fallback for `SAIA_API_KEY`.
- 2026-05: initial release — a single-file Bash client over the SAIA API covering models, limits,
  document conversion, embeddings, audio, chat, completion, image generation and Arcana queries.
