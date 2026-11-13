# Contributing to TokenMoon

Open an issue to describe the problem, the expected result, and the macOS and TokenMoon versions. Use synthetic fixtures for usage and WebDAV reports. Remove account identifiers, server addresses, credentials, raw logs, and conversation content before sharing anything.

Make changes against `main`. Run `swift test`; for changes to persistence or synchronization, also run `python3 scripts/verify-webdav.py`. For UI changes, describe what you verified on macOS. Keep pull requests focused and include a test where it covers a meaningful regression.

By submitting a contribution, you agree to license it under GPL-3.0-only. When adding third-party material, include its original license and provenance.
