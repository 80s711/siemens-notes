param(
    [Parameter(Mandatory = $true)]
    [string]$ImagePath,

    [string]$Branch = "main",

    [string]$CommitMessage = "",

    [switch]$CopyToImagine,

    [switch]$Push
)

$ErrorActionPreference = "Stop"

function Get-RepoRoot {
    $root = git rev-parse --show-toplevel 2>$null
    if (-not $root) {
        throw "Current directory is not a Git repository."
    }
    return $root.Trim()
}

function Get-OriginInfo {
    $originUrl = git remote get-url origin 2>$null
    if (-not $originUrl) {
        throw "Origin remote was not found."
    }

    if ($originUrl -match "^https://github\.com/([^/]+)/([^/.]+?)(?:\.git)?$") {
        return @{
            Url = $originUrl
            Owner = $Matches[1]
            Repo = $Matches[2]
        }
    }

    throw "Only GitHub HTTPS remotes are supported."
}

function Get-RelativeRepoPath([string]$RepoRoot, [string]$FullPath) {
    $repoUri = New-Object System.Uri(($RepoRoot.TrimEnd('\') + '\'))
    $fileUri = New-Object System.Uri($FullPath)
    $relative = $repoUri.MakeRelativeUri($fileUri).ToString()
    return [System.Uri]::UnescapeDataString($relative).Replace('/', '\')
}

function Ensure-FileInRepo([string]$RepoRoot, [string]$InputPath, [bool]$ShouldCopy) {
    $fullPath = (Resolve-Path -LiteralPath $InputPath).Path
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "Image file was not found: $InputPath"
    }

    $normalizedRepoRoot = [System.IO.Path]::GetFullPath($RepoRoot)
    $repoPrefix = $normalizedRepoRoot.TrimEnd('\') + '\'
    if ($fullPath.StartsWith($repoPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $fullPath
    }

    if (-not $ShouldCopy) {
        throw "Image is outside the repository. Use -CopyToImagine to copy it into imagine."
    }

    $imagineDir = Join-Path $RepoRoot "imagine"
    if (-not (Test-Path -LiteralPath $imagineDir -PathType Container)) {
        New-Item -ItemType Directory -Path $imagineDir | Out-Null
    }

    $fileName = [System.IO.Path]::GetFileName($fullPath)
    $targetPath = Join-Path $imagineDir $fileName

    if (Test-Path -LiteralPath $targetPath -PathType Leaf) {
        $name = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
        $ext = [System.IO.Path]::GetExtension($fileName)
        $timestamp = Get-Date -Format "yyyyMMddHHmmss"
        $targetPath = Join-Path $imagineDir ($name + "-" + $timestamp + $ext)
    }

    Copy-Item -LiteralPath $fullPath -Destination $targetPath
    return $targetPath
}

$repoRoot = Get-RepoRoot
$origin = Get-OriginInfo
$finalPath = Ensure-FileInRepo -RepoRoot $repoRoot -InputPath $ImagePath -ShouldCopy:$CopyToImagine.IsPresent
$relativePath = Get-RelativeRepoPath -RepoRoot $repoRoot -FullPath $finalPath
$urlPath = $relativePath.Replace('\', '/')
$rawUrl = "https://raw.githubusercontent.com/$($origin.Owner)/$($origin.Repo)/$Branch/$urlPath"

if ($Push) {
    git add -- $relativePath

    $hasStagedChanges = $LASTEXITCODE -eq 0
    if (-not $hasStagedChanges) {
        throw "git add failed."
    }

    $null = git diff --cached --quiet
    if ($LASTEXITCODE -eq 0) {
        Write-Host "No staged changes to commit."
    }
    else {
        if (-not $CommitMessage) {
            $CommitMessage = "docs: add image " + [System.IO.Path]::GetFileName($finalPath)
        }

        git commit -m $CommitMessage
        if ($LASTEXITCODE -ne 0) {
            throw "git commit failed."
        }

        git push origin $Branch
        if ($LASTEXITCODE -ne 0) {
            throw "git push failed."
        }
    }
}

Write-Host ""
Write-Host "Relative path: $urlPath"
Write-Host "GitHub raw URL:"
Write-Host $rawUrl
Write-Host ""
Write-Host "Markdown usage:"
Write-Host "![image]($rawUrl)"
