# Contributing to Privducai

Thank you for your interest in contributing to Privducai! Here's how you can help.

## Code of Conduct

Please be respectful and constructive in all interactions. We're building a welcoming community.

## Getting Started

1. **Fork the repository** on GitHub
2. **Clone your fork** locally:
   ```bash
   git clone https://github.com/YOUR_USERNAME/Privducai.git
   cd Privducai
   ```
3. **Create a feature branch**:
   ```bash
   git checkout -b feature/your-feature-name
   ```
4. **Make your changes** and test them locally
5. **Commit with clear messages**:
   ```bash
   git commit -m "Add feature: description"
   ```
6. **Push to your fork** and create a Pull Request

## Development Setup

### Requirements
- macOS 13.0 or later
- Xcode 14.0 or later
- Apple Silicon or Intel Mac

### Building

Quick build:
```bash
./scripts/build.sh Debug
```

Build with automatic launching:
```bash
./scripts/build-and-run.sh Debug
```

See [BUILDING.md](BUILDING.md) for more details.

## GitHub Helper

Use the GitHub helper script to manage repositories and check build status:
```bash
./scripts/github-helper.sh
```

## Pull Request Guidelines

Before submitting a PR:

1. **Update the README** if you've made documentation changes
2. **Test on macOS** (both simulator and device if possible)
3. **Keep commits clean** — one logical change per commit
4. **Follow the PR template** — fill out all relevant sections
5. **Link related issues** using `Fixes #123` syntax

## Commit Message Guidelines

Write clear, descriptive commit messages:
- Use the imperative mood ("Add feature" not "Added feature")
- Keep the first line under 72 characters
- Reference issues and PRs when relevant
- Example: `Add PDF upload support (#45)`

## Code Style

- Use Swift naming conventions (camelCase for variables/functions)
- Keep functions focused and reasonably sized
- Add comments for complex logic
- Write descriptive variable names

## Testing

Before submitting:
1. Build in Debug configuration
2. Build in Release configuration
3. Test on both simulator and real Mac if possible

## Reporting Issues

Use the issue templates provided:
- **Bug Report** — For reporting issues
- **Feature Request** — For suggesting improvements

Include:
- Clear description of the issue
- Steps to reproduce (bugs)
- Expected vs. actual behavior
- macOS version and hardware info

## Licensing

By contributing to Privducai, you agree that your contributions will be licensed under the project's Privducai Non-Commercial License v1.0.

## Questions?

Feel free to open an issue to ask questions or discuss ideas. We're here to help!

---

Happy coding! 🚀
