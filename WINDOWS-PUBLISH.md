# Publish this release from Windows

1. Download and extract the ZIP.
2. Open PowerShell inside the extracted `warp-egress-gateway` folder.
3. Run:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\publish-to-github.ps1 `
  -RepositoryUrl "https://github.com/Alireza-Oliaiy/warp-egress-gateway.git" `
  -CommitMessage "Release v0.3.1: harden Windows publishing"
```

The script performs a fresh clone of the remote repository in `%TEMP%`, copies the release files, enforces LF line endings, records executable modes for Linux scripts, commits, and pushes.

After publishing, verify on a fresh Ubuntu host:

```bash
git clone https://github.com/Alireza-Oliaiy/warp-egress-gateway.git
cd warp-egress-gateway
sudo bash setup.sh
```
