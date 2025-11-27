# Claude Code Instructions

## Build Process

**Do NOT run `scripts/build.sh` manually.** The build is automated via GitHub Actions workflow and runs automatically on push to main branch.

When making changes:
1. Edit source files in `scripts/src/` directory
2. Commit and push your changes
3. The GitHub Actions workflow will automatically rebuild `pve-install.sh`
