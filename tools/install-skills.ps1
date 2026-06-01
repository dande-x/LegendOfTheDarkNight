<#
.SYNOPSIS
    Install ai-dev-kit skills into a target agent's discovery directory.

.DESCRIPTION
    Phase 1: Move skills from <workspace>\skills\ to <workspace>\.installer\skills\,
             filtering out platform-excluded skills listed in
             <workspace>\.installer\local-skill-filter.json under the "win32" key.
    Phase 2: Create directory junctions from <workspace>\.<tool>\skills\<name>\
             pointing to <workspace>\.installer\skills\<name>\ (hard-copy fallback).

    Junctions don't require admin or Developer Mode and are atomic from the
    Claude/Codex/Cursor/Gemini agents' point of view. The agents read through
    them transparently.

    IMPORTANT: keep this file ASCII-only. PowerShell 5.1 without UTF-8 BOM
    treats .ps1 as the current ANSI codepage (e.g. CP936 on zh-CN Windows),
    which corrupts non-ASCII characters and can break parsing in subtle ways
    (e.g. silently merging the next code line into a comment). All comments
    and string literals here are English to avoid that landmine.

.PARAMETER Tool
    claude | codex | cursor | gemini | all

.EXAMPLE
    .\install-skills.ps1 codex
    .\install-skills.ps1 all
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('claude', 'codex', 'cursor', 'gemini', 'all')]
    [string]$Tool
)

$ErrorActionPreference = 'Stop'

$SupportedTools = @('claude', 'codex', 'cursor', 'gemini')
$PlatformKey = 'win32'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Workspace = Split-Path -Parent $ScriptDir
$RawSource = Join-Path $Workspace 'skills'
$InstallerDir = Join-Path $Workspace '.installer'
$Source = Join-Path $InstallerDir 'skills'
$FilterConfig = Join-Path $InstallerDir 'local-skill-filter.json'

# --------------------------------------------------------------------------- #
# Phase 1: Move skills/ -> .installer/skills/ with platform filtering
# --------------------------------------------------------------------------- #

function Get-ExcludedSkills {
    if (-not (Test-Path $FilterConfig)) { return @() }

    try {
        $config = Get-Content -Raw -Encoding UTF8 -Path $FilterConfig | ConvertFrom-Json
        $excludeSkills = $config.exclude_skills
        if ($null -eq $excludeSkills) { return @() }

        $platformList = $excludeSkills.$PlatformKey
        if ($null -eq $platformList) { return @() }

        # ConvertFrom-Json may return a single string instead of an array when
        # the JSON array has exactly one element. Wrap in @() to normalize.
        return @($platformList)
    }
    catch {
        Write-Host "[install-skills] WARNING: failed to parse $FilterConfig - skipping filter"
        return @()
    }
}

function Move-SkillsToInstaller {
    # Already moved in a previous run (path does not exist).
    if (-not (Test-Path $RawSource)) { return }
    # Path exists but is not a directory (edge case).
    if (-not (Test-Path $RawSource -PathType Container)) { return }

    $excludedSet = @{}
    foreach ($name in (Get-ExcludedSkills)) { $excludedSet[$name] = $true }

    if (-not (Test-Path $Source)) {
        New-Item -ItemType Directory -Force -Path $Source | Out-Null
    }

    $filtered = 0
    Get-ChildItem -Path $RawSource -Directory | ForEach-Object {
        $name = $_.Name
        if ($excludedSet.ContainsKey($name)) {
            $filtered++
            return  # skip this skill
        }
        $dest = Join-Path $Source $name
        if (Test-Path $dest) {
            cmd /c "rmdir /S /Q `"$dest`"" 2>&1 | Out-Null
        }
        Move-Item -Force -Path $_.FullName -Destination $dest
    }

    # Also move non-directory files (e.g. README) if any.
    Get-ChildItem -Path $RawSource -File | ForEach-Object {
        Move-Item -Force -Path $_.FullName -Destination (Join-Path $Source $_.Name)
    }

    # Remove the top-level skills/ directory, including any excluded skill
    # directories left behind — they are not needed on this platform.
    if (Test-Path $RawSource) {
        Remove-Item -Force -Recurse -Path $RawSource -ErrorAction SilentlyContinue
    }

    if ($filtered -gt 0) {
        Write-Host "[install-skills] filtered $filtered skill(s) for platform=$PlatformKey"
    }
}

Move-SkillsToInstaller

# --------------------------------------------------------------------------- #
# Phase 2: Create junctions from .installer/skills/ to .<tool>/skills/
# --------------------------------------------------------------------------- #

function Install-ForTool {
    param([string]$ToolName)

    # Safety: empty tool name would collapse target to '$Workspace\.' = source path,
    # and the subsequent rmdir would destroy source files. Refuse hard.
    if ([string]::IsNullOrWhiteSpace($ToolName)) {
        Write-Error "Install-ForTool called with empty ToolName - refusing (would destroy source)"
        exit 2
    }

    $TargetDir = Join-Path $Workspace ".${ToolName}\skills"

    if (-not (Test-Path $Source)) {
        Write-Error "Source not found: $Source"
        exit 1
    }

    # Safety: target must not resolve to source. If they collide, rmdir below
    # would delete source files thinking they're stale targets.
    $resolvedTarget = [System.IO.Path]::GetFullPath($TargetDir)
    $resolvedSource = [System.IO.Path]::GetFullPath($Source)
    if ($resolvedTarget.TrimEnd('\') -eq $resolvedSource.TrimEnd('\')) {
        Write-Error "Refusing: target [$resolvedTarget] equals source [$resolvedSource]"
        exit 2
    }

    if (-not (Test-Path $TargetDir)) {
        New-Item -ItemType Directory -Force -Path $TargetDir | Out-Null
    }

    $installed = 0

    Get-ChildItem -Path $Source -Directory | ForEach-Object {
        $name = $_.Name
        $skillSource = $_.FullName
        $dest = Join-Path $TargetDir $name

        # Safely remove existing entry. On a junction, `cmd rmdir` removes the
        # junction itself without following into the target; PowerShell's
        # Remove-Item -Recurse on a junction can be dangerous on PS 5.1.
        if (Test-Path $dest) {
            cmd /c "rmdir /S /Q `"$dest`"" 2>&1 | Out-Null
        }

        # Try directory junction first (no admin / dev mode needed).
        cmd /c "mklink /J `"$dest`" `"$skillSource`"" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $dest)) {
            # Fall back to hard copy.
            Copy-Item -Recurse -Force -Path $skillSource -Destination $dest
        }
        $installed++
    }

    Write-Host "[install-skills] $ToolName`: installed=$installed target=$TargetDir"
}

# ValidateSet is case-insensitive in PowerShell, but .codex / .cursor etc. must
# be lowercase on disk (POSIX cares; git is case-sensitive). Normalize first.
$ToolLower = $Tool.ToLower()

if ($ToolLower -eq 'all') {
    foreach ($t in $SupportedTools) { Install-ForTool $t }
}
else {
    Install-ForTool $ToolLower
}
