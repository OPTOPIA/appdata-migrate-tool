# Changelog

## 0.1.0 - 2026-07-14

- Added manifest-bound migration state, status inspection, explicit cleanup, and optional delayed cleanup scheduling.
- Reworked rollback to preserve post-migration destination data through a verified restore copy.
- Added destination NTFS/free-space/tool preflight, robocopy logs, default path/size/timestamp verification, and optional SHA-256 verification.
- Added stable process exit codes, scheduled-cleanup status, and scheduled-cleanup cancellation.
- Added Pester safety-baseline tests, a verification script, Windows GitHub Actions CI, and recovery/design documentation.
- Added the Apache-2.0 license.

## Unreleased

- Hash-based content verification and production NTFS integration-test coverage remain planned.
- License selection remains pending repository-owner direction.
