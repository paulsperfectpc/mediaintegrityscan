# Scan-MediaIntegrity.ps1

PowerShell script to detect potentially corrupted media files by running an FFmpeg decode test.

## What This Script Does

- Recursively scans one or more media folders.
- Filters files by extension (`.mkv`, `.mp4`, `.avi`, `.mov`, `.wmv`, `.flv`, `.webm`, `.m4v` by default).
- Runs FFmpeg against each file to decode content (without creating output files).
- Flags a file as `CORRUPT` only when FFmpeg returns a non-zero exit code.
- Writes corruption details to a log file.

This is useful for files that appear in Plex but fail playback, show artifacting, freeze, or crash mid-load.

## How Corruption Is Detected

The script runs FFmpeg with strict error behavior:

- `-v error`
- `-xerror`
- `-err_detect explode`

It decodes primary streams only:

- Maps first video stream: `-map 0:v:0?`
- Maps first audio stream: `-map 0:a:0?`
- Skips subtitle/data streams: `-sn -dn`

This avoids many false positives from non-playback streams while still catching real decode/container failures.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7+
- FFmpeg (`ffmpeg.exe`) available in PATH, or allow script auto-download
- Read access to media folders
- Write access to the log file location

Administrator rights are not required.

## Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `ScanPaths` | `string[]` | Prompted if omitted | One or more directories to scan recursively |
| `LogPath` | `string` | `./CorruptedMedia.log` | Output log file for corrupt files |
| `FfmpegPath` | `string` | `ffmpeg.exe` | Path or command name for FFmpeg |
| `ScanMode` | `Quick` or `Full` | `Quick` | `Quick` scans first N seconds, `Full` scans entire file |
| `QuickSeconds` | `int` | `45` | Seconds decoded per file in `Quick` mode (`5-3600`) |
| `Extensions` | `string[]` | Built-in list | File extensions to include |

## Usage Examples

Run with defaults (you will be prompted for scan paths if omitted):

```powershell
.\Scan-MediaIntegrity.ps1
```

Quick scan of two libraries:

```powershell
.\Scan-MediaIntegrity.ps1 \
  -ScanPaths "D:\PlexMedia\Movies", "E:\PlexMedia\TV" \
  -ScanMode Quick \
  -QuickSeconds 60 \
  -LogPath "C:\temp\CorruptedMedia.log"
```

Full scan (slow but most thorough):

```powershell
.\Scan-MediaIntegrity.ps1 \
  -ScanPaths "D:\PlexMedia" \
  -ScanMode Full \
  -LogPath "C:\temp\CorruptedMedia-Full.log"
```

Custom extension list:

```powershell
.\Scan-MediaIntegrity.ps1 \
  -ScanPaths "D:\Media" \
  -Extensions ".mkv", ".mp4", ".ts" \
  -LogPath "C:\temp\CorruptedMedia.log"
```

## Log Output

The log includes:

- timestamp
- file path
- FFmpeg exit code
- FFmpeg error text (if available)

Example block:

```text
[2026-05-04 12:34:56] CORRUPT: D:\PlexMedia\Movies\Example.mkv
FFMPEG EXIT CODE: 1
ERROR DETAILS:
[hevc @ ...] error while decoding MB ...
--------------------------------------------------
```

## Notes and Limitations

- `Quick` mode can miss corruption that occurs later in a file.
- `Full` mode is recommended for final verification.
- The script tests decode health, not subjective quality issues.
- Very large libraries on network storage can take significant time.

## Troubleshooting

### FFmpeg not found

If FFmpeg is missing, the script prompts to download it automatically. Choose `Y` to install a local `ffmpeg.exe` next to the script.

### No files detected

Check:

- `ScanPaths` are valid directories
- extension list includes your media type
- account has permission to enumerate files

### Files flagged that still play

Some files can be partially damaged but still playable in tolerant players. Run `Full` mode to validate thoroughly and compare with Plex behavior.

## Recommended Workflow

1. Run `Quick` mode on a schedule for regular health checks.
2. Run `Full` mode periodically (weekly/monthly) for deep validation.
3. Replace or re-rip files listed as corrupt.
