# Contributing to term.it

Thanks for your interest in improving term.it! 🎉

## Getting started

1. Fork and clone the repo.
2. Build it:
   ```bash
   ./package.sh release && open build/term.it.app
   # or: swift run
   ```
3. Requirements: macOS 15+, Xcode 16+.

## Project layout

See the *Architecture* section in the [README](README.md).

## Guidelines

- Keep the code style consistent with the surrounding files (Swift, SwiftUI idioms).
- Prefer small, focused pull requests with a clear description.
- Comments and UI strings are in French in this codebase — feel free to keep that
  convention, or open a discussion if you'd like to add localization.
- Don't commit build artifacts (`.build/`, `build/`) — they're gitignored.
- Never commit credentials, host data, or anything secret.

## Reporting bugs

Open an issue with:
- macOS version and Mac model
- Steps to reproduce
- What you expected vs. what happened
- Logs or screenshots if relevant

## Feature ideas

Check the roadmap in the README first, then open an issue to discuss before
starting large changes.

## Code of conduct

Be respectful and constructive. We want this to be a friendly project.
