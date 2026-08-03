[CmdletBinding()]
param(
    [string]$RepositoryUrl = "https://github.com/Alireza-Oliaiy/warp-egress-gateway.git",
    [string]$CommitMessage = "Release v0.3.1: Windows publishing and status fixes",
    [string]$Branch = "main",
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
        & bash tests/security-order.sh
        if ($LASTEXITCODE -ne 0) { throw "Security test failed." }
    }
    else {
        Write-Warning "bash was not found in PATH; GitHub Actions will run the Linux tests after push."
    }

    & git diff --cached --quiet
    $DiffExitCode = $LASTEXITCODE
    if ($DiffExitCode -eq 0) {
        Write-Host "No changes to publish. The remote already matches this release."
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

    Write-Host ""
    Write-Host "Published successfully." -ForegroundColor Green
    Write-Host "Checkout kept at: $WorkFullPath"
    & git log -1 --oneline
}
finally {
    Pop-Location
}
