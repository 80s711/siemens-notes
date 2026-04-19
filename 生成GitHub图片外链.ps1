param(
    [Parameter(ParameterSetName = "single", Mandatory = $true)]
    [string]$ImagePath,

    [Parameter(ParameterSetName = "markdown", Mandatory = $true)]
    [string[]]$MarkdownPath,

    [Parameter(ParameterSetName = "all", Mandatory = $true)]
    [switch]$AllMarkdown,

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

    if ($originUrl -match "^git@github\.com:([^/]+)/([^/.]+?)(?:\.git)?$") {
        return @{
            Url = $originUrl
            Owner = $Matches[1]
            Repo = $Matches[2]
        }
    }

    throw "Only GitHub remotes are supported."
}

function Get-RelativeRepoPath([string]$RepoRoot, [string]$FullPath) {
    $repoUri = New-Object System.Uri(($RepoRoot.TrimEnd('\') + '\'))
    $fileUri = New-Object System.Uri($FullPath)
    $relative = $repoUri.MakeRelativeUri($fileUri).ToString()
    return [System.Uri]::UnescapeDataString($relative).Replace('/', '\')
}

function Get-RepoRelativeWebPath([string]$RepoRoot, [string]$FullPath) {
    return (Get-RelativeRepoPath -RepoRoot $RepoRoot -FullPath $FullPath).Replace('\', '/')
}

function Test-PathInRepo([string]$RepoRoot, [string]$FullPath) {
    $normalizedRepoRoot = [System.IO.Path]::GetFullPath($RepoRoot).TrimEnd('\') + '\'
    $normalizedFullPath = [System.IO.Path]::GetFullPath($FullPath)
    return $normalizedFullPath.StartsWith($normalizedRepoRoot, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-FileSha256([string]$Path) {
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash
}

function Copy-ToImagine([string]$RepoRoot, [string]$SourcePath) {
    $imagineDir = Join-Path $RepoRoot "imagine"
    if (-not (Test-Path -LiteralPath $imagineDir -PathType Container)) {
        New-Item -ItemType Directory -Path $imagineDir | Out-Null
    }

    $sourceFullPath = (Resolve-Path -LiteralPath $SourcePath).Path
    $fileName = [System.IO.Path]::GetFileName($sourceFullPath)
    $targetPath = Join-Path $imagineDir $fileName

    if (Test-Path -LiteralPath $targetPath -PathType Leaf) {
        if ((Get-FileSha256 -Path $sourceFullPath) -eq (Get-FileSha256 -Path $targetPath)) {
            return $targetPath
        }

        $name = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
        $ext = [System.IO.Path]::GetExtension($fileName)
        $timestamp = Get-Date -Format "yyyyMMddHHmmss"
        $targetPath = Join-Path $imagineDir ($name + "-" + $timestamp + $ext)
    }

    Copy-Item -LiteralPath $sourceFullPath -Destination $targetPath
    return $targetPath
}

function Ensure-FileInRepo([string]$RepoRoot, [string]$InputPath, [bool]$ShouldCopy) {
    $fullPath = (Resolve-Path -LiteralPath $InputPath).Path
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "Image file was not found: $InputPath"
    }

    if (Test-PathInRepo -RepoRoot $RepoRoot -FullPath $fullPath) {
        return $fullPath
    }

    if (-not $ShouldCopy) {
        throw "Image is outside the repository. Use -CopyToImagine to copy it into imagine."
    }

    return (Copy-ToImagine -RepoRoot $RepoRoot -SourcePath $fullPath)
}

function Resolve-MarkdownFiles([string]$RepoRoot, [string[]]$InputFiles, [bool]$UseAllMarkdown) {
    if ($UseAllMarkdown) {
        return Get-ChildItem -Path $RepoRoot -Filter *.md -File | Select-Object -ExpandProperty FullName
    }

    $resolved = @()
    foreach ($file in $InputFiles) {
        $resolved += (Resolve-Path -LiteralPath $file).Path
    }
    return $resolved
}

function Resolve-MarkdownImage([string]$RepoRoot, [string]$MarkdownFile, [string]$RefPath, [bool]$ShouldCopy) {
    $trimmedRefPath = $RefPath.Trim()
    if ($trimmedRefPath -match "^(?i)https?://") {
        return $null
    }

    $resolvedPath = $null
    if ([System.IO.Path]::IsPathRooted($trimmedRefPath)) {
        if (-not (Test-Path -LiteralPath $trimmedRefPath -PathType Leaf)) {
            throw "Image file was not found: $trimmedRefPath"
        }
        $resolvedPath = (Resolve-Path -LiteralPath $trimmedRefPath).Path
    }
    else {
        $markdownDir = Split-Path -Parent $MarkdownFile
        $candidatePath = Join-Path $markdownDir $trimmedRefPath
        if (-not (Test-Path -LiteralPath $candidatePath -PathType Leaf)) {
            throw "Image file was not found: $candidatePath"
        }
        $resolvedPath = (Resolve-Path -LiteralPath $candidatePath).Path
    }

    $finalPath = $resolvedPath
    if (-not (Test-PathInRepo -RepoRoot $RepoRoot -FullPath $resolvedPath)) {
        if (-not $ShouldCopy) {
            throw "Image is outside the repository. Use -CopyToImagine to copy it into imagine."
        }
        $finalPath = Copy-ToImagine -RepoRoot $RepoRoot -SourcePath $resolvedPath
    }
    else {
        $relativePath = Get-RelativeRepoPath -RepoRoot $RepoRoot -FullPath $resolvedPath
        if (-not $relativePath.StartsWith("imagine\", [System.StringComparison]::OrdinalIgnoreCase)) {
            $finalPath = Copy-ToImagine -RepoRoot $RepoRoot -SourcePath $resolvedPath
        }
    }

    return [PSCustomObject]@{
        FullPath = $finalPath
        RelativeRepoPath = Get-RelativeRepoPath -RepoRoot $RepoRoot -FullPath $finalPath
        RelativeWebPath = Get-RepoRelativeWebPath -RepoRoot $RepoRoot -FullPath $finalPath
    }
}

function Process-MarkdownFile([string]$RepoRoot, [string]$MarkdownFile, [bool]$ShouldCopy) {
    $content = Get-Content -Raw -Encoding utf8 -LiteralPath $MarkdownFile
    $images = New-Object System.Collections.Generic.List[object]

    $updatedContent = [System.Text.RegularExpressions.Regex]::Replace(
        $content,
        "!\[([^\]]*)\]\(([^)]+)\)",
        {
            param($match)

            $imageInfo = Resolve-MarkdownImage -RepoRoot $RepoRoot -MarkdownFile $MarkdownFile -RefPath $match.Groups[2].Value -ShouldCopy $ShouldCopy
            if ($null -eq $imageInfo) {
                return $match.Value
            }

            $null = $images.Add($imageInfo)
            return "![{0}]({1})" -f $match.Groups[1].Value, $imageInfo.RelativeWebPath
        }
    )

    if ($updatedContent -ne $content) {
        Set-Content -LiteralPath $MarkdownFile -Value $updatedContent -Encoding utf8
    }

    return [PSCustomObject]@{
        MarkdownFile = $MarkdownFile
        Updated = ($updatedContent -ne $content)
        Images = $images
    }
}

function Write-RawLinks([hashtable]$Origin, [string]$Branch, [System.Collections.Generic.HashSet[string]]$RelativeWebPaths) {
    foreach ($path in $RelativeWebPaths) {
        $rawUrl = "https://raw.githubusercontent.com/$($Origin.Owner)/$($Origin.Repo)/$Branch/$path"
        Write-Host ""
        Write-Host "Relative path: $path"
        Write-Host "GitHub raw URL:"
        Write-Host $rawUrl
        Write-Host ""
        Write-Host "Markdown usage:"
        Write-Host "![image]($rawUrl)"
        Write-Host ""
        Write-Host "HTML usage:"
        Write-Host "<img src=""$rawUrl"" alt=""image"">"
    }
}

function Invoke-GitPublish([string[]]$PathsToAdd, [string]$CommitMessage, [string]$Branch) {
    if ($PathsToAdd.Count -eq 0) {
        Write-Host "No files to add."
        return
    }

    git add -- $PathsToAdd
    if ($LASTEXITCODE -ne 0) {
        throw "git add failed."
    }

    $null = git diff --cached --quiet
    if ($LASTEXITCODE -eq 0) {
        Write-Host "No staged changes to commit."
        return
    }

    if (-not $CommitMessage) {
        $CommitMessage = "docs: sync note images"
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

$repoRoot = Get-RepoRoot
$origin = Get-OriginInfo
$pathsToAdd = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
$relativeWebPaths = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)

switch ($PSCmdlet.ParameterSetName) {
    "single" {
        $finalPath = Ensure-FileInRepo -RepoRoot $repoRoot -InputPath $ImagePath -ShouldCopy:$CopyToImagine.IsPresent
        $relativeRepoPath = Get-RelativeRepoPath -RepoRoot $repoRoot -FullPath $finalPath
        $relativeWebPath = Get-RepoRelativeWebPath -RepoRoot $repoRoot -FullPath $finalPath
        $null = $pathsToAdd.Add($relativeRepoPath)
        $null = $relativeWebPaths.Add($relativeWebPath)
    }
    "markdown" {
        foreach ($file in Resolve-MarkdownFiles -RepoRoot $repoRoot -InputFiles $MarkdownPath -UseAllMarkdown:$false) {
            $result = Process-MarkdownFile -RepoRoot $repoRoot -MarkdownFile $file -ShouldCopy:$true
            $markdownRelativePath = Get-RelativeRepoPath -RepoRoot $repoRoot -FullPath $result.MarkdownFile
            $null = $pathsToAdd.Add($markdownRelativePath)

            foreach ($image in $result.Images) {
                $null = $pathsToAdd.Add($image.RelativeRepoPath)
                $null = $relativeWebPaths.Add($image.RelativeWebPath)
            }
        }
    }
    "all" {
        foreach ($file in Resolve-MarkdownFiles -RepoRoot $repoRoot -InputFiles @() -UseAllMarkdown:$true) {
            $result = Process-MarkdownFile -RepoRoot $repoRoot -MarkdownFile $file -ShouldCopy:$true
            $markdownRelativePath = Get-RelativeRepoPath -RepoRoot $repoRoot -FullPath $result.MarkdownFile
            $null = $pathsToAdd.Add($markdownRelativePath)

            foreach ($image in $result.Images) {
                $null = $pathsToAdd.Add($image.RelativeRepoPath)
                $null = $relativeWebPaths.Add($image.RelativeWebPath)
            }
        }
    }
    default {
        throw "Unsupported parameter set."
    }
}

if ($Push) {
    Invoke-GitPublish -PathsToAdd ([string[]]$pathsToAdd) -CommitMessage $CommitMessage -Branch $Branch
}

Write-RawLinks -Origin $origin -Branch $Branch -RelativeWebPaths $relativeWebPaths
