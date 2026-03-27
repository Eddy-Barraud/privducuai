# GitHub Agent Setup

This document explains the GitHub integration for Privducai.

## Components

### 1. GitHub Actions Workflow

**File:** `.github/workflows/build.yml`

Automatically builds the project on:
- **Push** to `main` or `develop` branches
- **Pull Requests** to `main` or `develop` branches

Runs:
- Xcode version check
- Debug build
- Release build
- Uploads build logs on failure

**Status Badge:** Add to README
```markdown
[![Build Status](https://github.com/eddybarraud/Privducai/actions/workflows/build.yml/badge.svg)](https://github.com/eddybarraud/Privducai/actions/workflows/build.yml)
```

### 2. GitHub Helper Script

**File:** `scripts/github-helper.sh`

Interactive CLI for common GitHub operations:
```bash
./scripts/github-helper.sh
```

Features:
- Check build status (requires GitHub CLI)
- View recent commits
- Create feature branches
- View repository statistics

### 3. PR Template

**File:** `.github/pull_request_template.md`

Automatically appears when creating PRs. Includes sections for:
- Description
- Type of change
- Related issues
- Testing checklist
- Screenshots

### 4. Issue Templates

**Location:** `.github/ISSUE_TEMPLATE/`

Pre-configured templates for:
- **Bug Reports** — `bug_report.md`
- **Feature Requests** — `feature_request.md`

### 5. Contributing Guide

**File:** `CONTRIBUTING.md`

Guidelines for:
- Setting up development environment
- Code style
- Commit message conventions
- Pull request workflow
- Issue reporting

## Workflow

### To Contribute

1. Fork the repository
2. Create a feature branch: `git checkout -b feature/my-feature`
3. Make changes and test locally using build scripts
4. Commit with clear messages
5. Push and create a PR from GitHub
6. GitHub Actions will automatically build and test
7. Address any feedback and merge

### GitHub Actions Status

View build status:
- **GitHub UI:** Actions tab → Build Privducai
- **CLI:** `./scripts/github-helper.sh` → Option 1
- **README Badge:** Shows in project header

## Setup Requirements

- GitHub repository at `https://github.com/eddybarraud/Privducai`
- Actions enabled (default)
- macOS runners available (GitHub-hosted)

## Next Steps

1. Push to GitHub to trigger workflows
2. Monitor build status in Actions tab
3. Share repository link and CONTRIBUTING guide with collaborators
