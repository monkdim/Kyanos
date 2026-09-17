# Contributing to Clarity

Thanks for your interest in contributing to Clarity! This guide covers how to build from source, run tests, and submit changes.

## Prerequisites

- [Bun](https://bun.sh) (latest) — used to compile the native binary
- A working `clarity` binary (download from [Releases](https://github.com/monkdim/Kyanos/releases))

## Build from Source

Clone the repo and build:

```bash
git clone https://github.com/monkdim/Kyanos.git
cd Clarity

# Transpile Clarity -> JavaScript
clarity transpile --bundle

# Compile to native binary
cd native/dist
bun build --compile clarity-entry.js --outfile clarity
```

Or use the built-in build command:

```bash
clarity build           # Build for current platform
clarity build --install # Build and install to /usr/local/bin
```

## Running Tests

```bash
clarity test stdlib/    # Run all test suites (50 files, ~2,750 assertions)
clarity smoke ./native/dist/clarity  # Run smoke tests on a binary
```

## Code Style

- Format your code before committing:

```bash
clarity fmt <file-or-dir> --write
```

- Lint for common issues:

```bash
clarity lint <file-or-dir>
```

- Type-check annotations:

```bash
clarity check <file> --types
```

## Project Structure

```
stdlib/          Clarity standard library and CLI (the language itself)
native/          JS transpiler (Python bootstrap) and runtime shim
examples/        Example programs
docs/            Documentation site
playground/      Browser-based playground
editors/vscode/  VS Code extension
registry/        Docker setup for package registry
```

## Submitting Changes

1. Fork the repo and create a branch from `main`
2. Write your changes in Clarity (not Python — we're 100% self-hosted)
3. Add tests in `stdlib/test_*.clarity` if applicable
4. Run `clarity fmt --write` and `clarity lint` on changed files
5. Run `clarity test stdlib/` to make sure everything passes
6. Open a pull request with a clear description of what and why

## Reporting Issues

Open an issue at [github.com/monkdim/Kyanos/issues](https://github.com/monkdim/Kyanos/issues) with:
- What you expected vs what happened
- Steps to reproduce
- Clarity version (`clarity version`)
- Platform and OS

## License

By contributing, you agree that your contributions will be licensed under the GPL-3.0 license.
