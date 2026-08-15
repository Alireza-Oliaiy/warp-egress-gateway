# Publish this release from Windows

1. Download and extract the ZIP.
2. Open PowerShell inside the extracted `warp-egress-gateway` folder.
3. Run:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\publish-to-github.ps1 `
  -RepositoryUrl "https://github.com/Alireza-Oliaiy/warp-egress-gateway.git" `
  -CommitMessage "Release v0.4.1: recover policy routing after network reconciliation" `
  -CreateReleaseTag
```

The script performs a fresh clone of the remote repository in `%TEMP%`, copies the release files, enforces LF line endings, records executable modes for Linux scripts, commits, and pushes.

After publishing, verify on a fresh Ubuntu host:

```bash
git clone https://github.com/Alireza-Oliaiy/warp-egress-gateway.git
cd warp-egress-gateway
sudo bash setup.sh
```

## Release tag and GitHub Release

Use `-CreateReleaseTag` only for an intentional release. The publisher reads `VERSION`, creates an annotated `v<VERSION>` tag after pushing `main`, and pushes the tag. The tag triggers `.github/workflows/release.yml`, which reruns validation, packages ZIP/TAR.GZ artifacts, generates SHA256 checksums, and creates the GitHub Release.

For ordinary non-release commits, omit `-CreateReleaseTag`.
## Replacement safety

The publisher performs a fresh clone and replaces the checkout with the release payload. It stages additions and deletions before Git line-ending renormalization so a release may intentionally remove previously tracked files without failing on stale index paths. The release test suite also validates that packaged Docker placeholder directories are preserved.

## Whitespace validation

Before commit creation, the publisher runs the repository whitespace/EOF regression test and then `git diff --cached --check`. This catches malformed Markdown or other text files before anything is pushed to GitHub.
