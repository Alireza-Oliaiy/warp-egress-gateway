[CmdletBinding()]
param(
    [string]$RepositoryUrl = "https://github.com/Alireza-Oliaiy/warp-egress-gateway.git",
    [string]$CommitMessage = "Release v0.4.1: recover policy routing after network reconciliation",
    [string]$Branch = "main",
    [switch]$CreateReleaseTag,
    [string]$WorkDirectory = (Join-Path $env:TEMP "warp-egress-gateway-publish")
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Invoke-Git {
    param([Parameter(Mandatory = $true)][string[]]$GitArguments)

    & git @GitArguments
    if ($LASTEXITCODE -ne 0) {
        throw "git command failed: git $($GitArguments -join ' ')"
    }
}

function Publish-ReleaseTag {
    param([Parameter(Mandatory = $true)][string]$CheckoutPath)

    $Version = (Get-Content -LiteralPath (Join-Path $CheckoutPath "VERSION") -Raw).Trim()
    if ([string]::IsNullOrWhiteSpace($Version)) { throw "VERSION is empty." }
    $Tag = "v$Version"

    & git ls-remote --exit-code --tags origin "refs/tags/$Tag" *> $null
    if ($LASTEXITCODE -eq 0) {
        throw "Remote release tag $Tag already exists. Release tags are immutable; bump VERSION for a new release."
    }

    & git rev-parse -q --verify "refs/tags/$Tag" *> $null
    if ($LASTEXITCODE -eq 0) {
        throw "Local tag $Tag already exists unexpectedly."
    }

    Write-Host "Creating release tag $Tag"
    Invoke-Git -GitArguments @("tag", "-a", $Tag, "-m", "Release $Tag")
    Invoke-Git -GitArguments @("push", "origin", $Tag)
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw "Git for Windows was not found in PATH. Install Git for Windows first."
}

$SourceDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$SourceFullPath = [System.IO.Path]::GetFullPath($SourceDirectory)
$WorkFullPath = [System.IO.Path]::GetFullPath($WorkDirectory)

if ($SourceFullPath.TrimEnd('\') -eq $WorkFullPath.TrimEnd('\')) {
    throw "WorkDirectory must be different from the extracted source directory."
}

Write-Host "[1/8] Preparing temporary checkout: $WorkFullPath"
if (Test-Path -LiteralPath $WorkFullPath) {
    Remove-Item -LiteralPath $WorkFullPath -Recurse -Force
}

Write-Host "[2/8] Cloning $RepositoryUrl"
Invoke-Git -GitArguments @("clone", "--branch", $Branch, "--single-branch", $RepositoryUrl, $WorkFullPath)

Write-Host "[3/8] Replacing checkout files with this release"
Get-ChildItem -LiteralPath $WorkFullPath -Force |
    Where-Object { $_.Name -ne ".git" } |
    Remove-Item -Recurse -Force

Get-ChildItem -LiteralPath $SourceFullPath -Force |
    Where-Object { $_.Name -ne ".git" } |
    Copy-Item -Destination $WorkFullPath -Recurse -Force

Push-Location $WorkFullPath
try {
    Write-Host "[4/8] Enforcing LF-safe repository settings"
    Invoke-Git -GitArguments @("config", "core.autocrlf", "false")
    # Stage additions/deletions first so --renormalize never tries to stat a
    # tracked path intentionally removed from the new release payload.
    Invoke-Git -GitArguments @("add", "-A")
    Invoke-Git -GitArguments @("add", "--renormalize", ".")
    Invoke-Git -GitArguments @("add", "-A")

    Write-Host "[5/8] Recording Linux executable modes"
    $ExecutableFiles = @()
    $ExecutableFiles += Get-ChildItem -Path . -Recurse -File -Filter "*.sh" |
        ForEach-Object {
            $_.FullName.Substring($WorkFullPath.Length + 1).Replace('\', '/')
        }
    $ExecutableFiles += "native/scripts/warp-gateway"
    $ExecutableFiles = $ExecutableFiles | Sort-Object -Unique

    foreach ($File in $ExecutableFiles) {
        $LocalPath = Join-Path $WorkFullPath ($File.Replace('/', '\'))
        if (Test-Path -LiteralPath $LocalPath) {
            Invoke-Git -GitArguments @("update-index", "--add", "--chmod=+x", "--", $File)
        }
    }

    Write-Host "[6/8] Checking staged changes"
    Invoke-Git -GitArguments @("diff", "--cached", "--check")

    $Bash = Get-Command bash -ErrorAction SilentlyContinue
    if ($null -ne $Bash) {
        Write-Host "Running repository tests with Bash"
        & bash tests/syntax.sh
        if ($LASTEXITCODE -ne 0) { throw "Syntax test failed." }
        & bash tests/whitespace.sh
        if ($LASTEXITCODE -ne 0) { throw "Whitespace/EOF test failed." }
        & bash tests/security-order.sh
        if ($LASTEXITCODE -ne 0) { throw "Security test failed." }
        & bash tests/policy-recovery.sh
        if ($LASTEXITCODE -ne 0) { throw "Policy recovery test failed." }
        & bash tests/monitoring.sh
        if ($LASTEXITCODE -ne 0) { throw "Monitoring test failed." }
        & bash tests/profile-ipv4.sh
        if ($LASTEXITCODE -ne 0) { throw "IPv4 profile regression test failed." }
        & bash tests/upgrade.sh
        if ($LASTEXITCODE -ne 0) { throw "Upgrade safety test failed." }
        & bash tests/docs.sh
        if ($LASTEXITCODE -ne 0) { throw "Documentation test failed." }
        & bash tests/release-metadata.sh
        if ($LASTEXITCODE -ne 0) { throw "Release metadata test failed." }
        & bash tests/publisher.sh
        if ($LASTEXITCODE -ne 0) { throw "Windows publisher regression test failed." }
        & bash tests/package.sh
        if ($LASTEXITCODE -ne 0) { throw "Release package regression test failed." }
    }
    else {
        Write-Warning "bash was not found in PATH; GitHub Actions will run the Linux tests after push."
    }

    & git diff --cached --quiet
    $DiffExitCode = $LASTEXITCODE
    if ($DiffExitCode -eq 0) {
        Write-Host "No changes to publish. The remote already matches this release."
        if ($CreateReleaseTag) {
            Publish-ReleaseTag -CheckoutPath $WorkFullPath
            Write-Host "Release tag published successfully." -ForegroundColor Green
        }
        return
    }
    if ($DiffExitCode -ne 1) {
        throw "Unable to inspect staged changes."
    }

    $UserNameOutput = & git config --get user.name 2>$null
    if ($LASTEXITCODE -ne 0) { $UserNameOutput = "" }
    $UserName = ([string]$UserNameOutput).Trim()
    if ([string]::IsNullOrWhiteSpace($UserName)) {
        $UserName = Read-Host "Git commit user.name"
        Invoke-Git -GitArguments @("config", "user.name", $UserName)
    }

    $UserEmailOutput = & git config --get user.email 2>$null
    if ($LASTEXITCODE -ne 0) { $UserEmailOutput = "" }
    $UserEmail = ([string]$UserEmailOutput).Trim()
    if ([string]::IsNullOrWhiteSpace($UserEmail)) {
        $UserEmail = Read-Host "Git commit user.email"
        Invoke-Git -GitArguments @("config", "user.email", $UserEmail)
    }

    Write-Host "[7/8] Creating commit"
    Invoke-Git -GitArguments @("commit", "-m", $CommitMessage)

    Write-Host "[8/8] Pushing to origin/$Branch"
    Invoke-Git -GitArguments @("push", "origin", $Branch)

    if ($CreateReleaseTag) {
        Publish-ReleaseTag -CheckoutPath $WorkFullPath
    }

    Write-Host ""
    Write-Host "Published successfully." -ForegroundColor Green
    Write-Host "Checkout kept at: $WorkFullPath"
    & git log -1 --oneline
}
finally {
    Pop-Location
}
