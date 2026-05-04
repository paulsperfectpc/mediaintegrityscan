<#
.SYNOPSIS
    Scans media files for corruption using FFmpeg decode checks.

.DESCRIPTION
    This script recursively searches the specified directories for media files and runs an FFmpeg decode test.
    Files that fail decode are logged to a specified output file.

.PARAMETER ScanPaths
    An array of directories to scan. Example: "D:\Movies", "E:\TV Shows"

.PARAMETER LogPath
    The path to the log file where corrupted media paths will be saved. Defaults to ".\CorruptedMedia.log".

.PARAMETER FfmpegPath
    The path to the FFmpeg executable. Defaults to "ffmpeg.exe" (assuming it's in your system PATH).

.PARAMETER ScanMode
    Quick: Decode only the first N seconds of each file.
    Full: Decode the entire file.

.PARAMETER QuickSeconds
    Number of seconds to decode in Quick mode. Ignored in Full mode.

.EXAMPLE
    .\Scan-MediaIntegrity.ps1 -ScanPaths "D:\PlexMedia\Movies", "E:\PlexMedia\TV" -LogPath "C:\temp\corrupt.log"

.EXAMPLE
    .\Scan-MediaIntegrity.ps1 -ScanPaths "D:\PlexMedia" -ScanMode Full
#>

[CmdletBinding()]
param (
    [string[]]$ScanPaths,

    [string]$LogPath = ".\CorruptedMedia.log",

    [string]$FfmpegPath = "ffmpeg.exe",

    [ValidateSet("Quick", "Full")]
    [string]$ScanMode = "Quick",

    [ValidateRange(5, 3600)]
    [int]$QuickSeconds = 45,
    
    [string[]]$Extensions = @(".mkv", ".mp4", ".avi", ".mov", ".wmv", ".flv", ".webm", ".m4v")
)

Set-StrictMode -Version Latest

function Resolve-ExecutablePath {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$NameOrPath
    )

    if (Test-Path -LiteralPath $NameOrPath) {
        return (Resolve-Path -LiteralPath $NameOrPath).Path
    }

    $command = Get-Command -Name $NameOrPath -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $command) {
        return $command.Source
    }

    return $null
}

function Install-LocalFfmpeg {
    [CmdletBinding()]
    param ()

    Write-Host "Downloading FFmpeg... This may take a minute depending on your connection." -ForegroundColor Cyan

    $zipUrl = "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip"
    $tempId = [guid]::NewGuid().ToString("N")
    $tempZip = Join-Path $env:TEMP "ffmpeg-$tempId.zip"
    $extractDir = Join-Path $env:TEMP "ffmpeg-$tempId"

    try {
        if ((Get-Command Invoke-WebRequest).Parameters.ContainsKey("UseBasicParsing")) {
            Invoke-WebRequest -Uri $zipUrl -OutFile $tempZip -UseBasicParsing
        }
        else {
            Invoke-WebRequest -Uri $zipUrl -OutFile $tempZip
        }

        if (Test-Path -LiteralPath $extractDir) {
            Remove-Item -LiteralPath $extractDir -Recurse -Force
        }

        Expand-Archive -Path $tempZip -DestinationPath $extractDir -Force

        $ffmpegExe = Get-ChildItem -Path $extractDir -Filter "ffmpeg.exe" -Recurse | Select-Object -First 1
        if ($null -eq $ffmpegExe) {
            throw "Could not locate ffmpeg.exe inside the downloaded archive."
        }

        $destinationRoot = if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) { (Get-Location).Path } else { $PSScriptRoot }
        $destinationPath = Join-Path $destinationRoot "ffmpeg.exe"

        Copy-Item -LiteralPath $ffmpegExe.FullName -Destination $destinationPath -Force
        Write-Host "FFmpeg successfully downloaded to: $destinationPath" -ForegroundColor Green
        return $destinationPath
    }
    finally {
        if (Test-Path -LiteralPath $tempZip) {
            Remove-Item -LiteralPath $tempZip -Force
        }
        if (Test-Path -LiteralPath $extractDir) {
            Remove-Item -LiteralPath $extractDir -Recurse -Force
        }
    }
}

function Test-MediaFile {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$FilePath,

        [Parameter(Mandatory)]
        [string]$FfmpegExecutable,

        [Parameter(Mandatory)]
        [ValidateSet("Quick", "Full")]
        [string]$Mode,

        [Parameter(Mandatory)]
        [int]$Seconds
    )

    $arguments = @(
        "-hide_banner",
        "-nostdin",
        "-v", "error",
        "-xerror",
        "-err_detect", "explode"
    )

    if ($Mode -eq "Quick") {
        $arguments += @("-t", $Seconds.ToString())
    }

    $arguments += @(
        "-i", $FilePath,
        "-map", "0:v:0?",
        "-map", "0:a:0?",
        "-sn",
        "-dn",
        "-f", "null", "-"
    )

    $commandOutput = & $FfmpegExecutable @arguments 2>&1
    $exitCode = $LASTEXITCODE
    $message = ($commandOutput | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine

    return [pscustomobject]@{
        IsHealthy = ($exitCode -eq 0)
        ExitCode  = $exitCode
        Message   = $message.Trim()
    }
}

function Write-CorruptEntry {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$OutputPath,

        [Parameter(Mandatory)]
        [System.IO.FileInfo]$File,

        [Parameter(Mandatory)]
        [int]$ExitCode,

        [Parameter()]
        [string]$Details
    )

    Add-Content -Path $OutputPath -Value "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] CORRUPT: $($File.FullName)"
    Add-Content -Path $OutputPath -Value "FFMPEG EXIT CODE: $ExitCode"

    if (-not [string]::IsNullOrWhiteSpace($Details)) {
        Add-Content -Path $OutputPath -Value "ERROR DETAILS:"
        Add-Content -Path $OutputPath -Value $Details
    }

    Add-Content -Path $OutputPath -Value "--------------------------------------------------"
}

# Prompt for ScanPaths if not provided
if (-not $ScanPaths) {
    $userInput = Read-Host "Enter the directory path(s) to scan (separate multiple paths with commas)"
    if ([string]::IsNullOrWhiteSpace($userInput)) {
        Write-Error "No paths provided. Exiting."
        exit 1
    }
    $ScanPaths = $userInput -split ',' | ForEach-Object { $_.Trim() }
}

$ScanPaths = $ScanPaths |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    ForEach-Object { $_.Trim() } |
    Select-Object -Unique

if (-not $ScanPaths) {
    Write-Error "No valid scan paths were provided."
    exit 1
}

$normalizedExtensions = $Extensions |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    ForEach-Object {
        $trimmed = $_.Trim().ToLowerInvariant()
        if ($trimmed.StartsWith('.')) {
            $trimmed
        }
        else {
            ".${trimmed}"
        }
    } |
    Select-Object -Unique

$extensionSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($ext in $normalizedExtensions) {
    [void]$extensionSet.Add($ext)
}

# Ensure FFmpeg is available
$resolvedFfmpeg = Resolve-ExecutablePath -NameOrPath $FfmpegPath

if (-not $resolvedFfmpeg) {
    Write-Warning "FFmpeg is required but was not found at '$FfmpegPath' or in your system PATH."
    $choice = Read-Host "Would you like this script to automatically download FFmpeg for you? (Y/N)"
    if ($choice -match "^[Yy]") {
        try {
            $resolvedFfmpeg = Install-LocalFfmpeg
        } catch {
            Write-Error "Failed to download or extract FFmpeg: $($_.Exception.Message)"
            exit 1
        }
    } else {
        Write-Host ""
        Write-Error "Missing Dependency: FFmpeg"
        Write-Host "Please download FFmpeg manually from https://ffmpeg.org/download.html" -ForegroundColor Yellow
        Write-Host "Extract the archive and place 'ffmpeg.exe' in the same folder as this script, or add it to your system PATH." -ForegroundColor Yellow
        exit 1
    }
}

try {
    $null = & $resolvedFfmpeg -version 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "FFmpeg check returned exit code $LASTEXITCODE"
    }
}
catch {
    Write-Error "Unable to execute FFmpeg from '$resolvedFfmpeg'. $($_.Exception.Message)"
    exit 1
}

# Gather media files first so progress is meaningful.
$mediaFiles = [System.Collections.Generic.List[System.IO.FileInfo]]::new()

foreach ($path in $ScanPaths) {
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        Write-Warning "Path does not exist or is not a directory: $path"
        continue
    }

    Write-Host "Indexing directory: $path" -ForegroundColor Yellow

    Get-ChildItem -LiteralPath $path -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $extensionSet.Contains($_.Extension) } |
        ForEach-Object { $mediaFiles.Add($_) }
}

if ($mediaFiles.Count -eq 0) {
    Write-Warning "No media files found for the provided extensions."
    exit 0
}

# Ensure log directory exists.
$logDirectory = Split-Path -Path $LogPath -Parent
if (-not [string]::IsNullOrWhiteSpace($logDirectory) -and -not (Test-Path -LiteralPath $logDirectory)) {
    New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
}

# Clear or create the log file
New-Item -ItemType File -Path $LogPath -Force | Out-Null
Add-Content -Path $LogPath -Value "Started Media Integrity Scan at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Add-Content -Path $LogPath -Value "Mode: $ScanMode"
if ($ScanMode -eq "Quick") {
    Add-Content -Path $LogPath -Value "QuickSeconds: $QuickSeconds"
}
Add-Content -Path $LogPath -Value "FFmpeg: $resolvedFfmpeg"
Add-Content -Path $LogPath -Value "--------------------------------------------------"

Write-Host "Started Media Integrity Scan at $(Get-Date)" -ForegroundColor Cyan
Write-Host "Scan Mode: $ScanMode" -ForegroundColor Cyan
if ($ScanMode -eq "Quick") {
    Write-Host "Quick Decode Duration: $QuickSeconds seconds per file" -ForegroundColor Cyan
}
Write-Host "Files queued: $($mediaFiles.Count)" -ForegroundColor Cyan
Write-Host "Logging corrupted files to: $LogPath" -ForegroundColor Cyan

$totalFiles = $mediaFiles.Count
$corruptFiles = 0
$scannedFiles = 0
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

foreach ($file in $mediaFiles) {
    $scannedFiles++
    $percent = [int](($scannedFiles / [double]$totalFiles) * 100)

    Write-Progress -Activity "Scanning Media Files" -Status "Checking: $($file.Name)" -PercentComplete $percent

    $result = Test-MediaFile -FilePath $file.FullName -FfmpegExecutable $resolvedFfmpeg -Mode $ScanMode -Seconds $QuickSeconds
    if (-not $result.IsHealthy) {
        Write-Host "[CORRUPT] $($file.FullName)" -ForegroundColor Red
        Write-CorruptEntry -OutputPath $LogPath -File $file -ExitCode $result.ExitCode -Details $result.Message
        $corruptFiles++
    }
}

$stopwatch.Stop()
Write-Progress -Activity "Scanning Media Files" -Completed

Write-Host "`nScan Complete!" -ForegroundColor Green
Write-Host "Total Files Scanned: $totalFiles" -ForegroundColor Cyan
Write-Host "Corrupt Files Found: $corruptFiles" -ForegroundColor $(if ($corruptFiles -gt 0) { "Red" } else { "Green" })
Write-Host "Elapsed Time: $($stopwatch.Elapsed.ToString('hh\:mm\:ss'))" -ForegroundColor Cyan

Add-Content -Path $LogPath -Value "Scan Complete at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Add-Content -Path $LogPath -Value "Total Files Scanned: $totalFiles"
Add-Content -Path $LogPath -Value "Corrupt Files Found: $corruptFiles"
Add-Content -Path $LogPath -Value "Elapsed Time: $($stopwatch.Elapsed.ToString('hh\:mm\:ss'))"