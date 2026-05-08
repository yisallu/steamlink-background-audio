# Repackage work/Payload into a new IPA using 7z (zip/deflate).
# Usage: .\make_ipa.ps1 [output-ipa-path]

param(
    [string]$OutIpa = "steamlink1.3.25-bgaudio.ipa"
)

$ErrorActionPreference = "Stop"

$here = Split-Path -Parent $MyInvocation.MyCommand.Definition
$payload = Join-Path $here "work\Payload"
if (-not (Test-Path $payload)) {
    throw "Payload not found at $payload - extract the IPA first."
}

$dylib = Join-Path $here "work\Payload\Steam Link.app\Frameworks\BackgroundAudio.dylib"
if (-not (Test-Path $dylib)) {
    Write-Warning "BackgroundAudio.dylib is missing from Frameworks/. The patched app will fail to launch until you compile and place it there."
}

$out = if ([IO.Path]::IsPathRooted($OutIpa)) { $OutIpa } else { Join-Path $here $OutIpa }
if (Test-Path $out) { Remove-Item $out -Force }

$sevenzip = (Get-Command 7z.exe -ErrorAction SilentlyContinue).Source
if (-not $sevenzip) {
    throw "7z.exe not found on PATH. Install 7-Zip or run the extraction / repackaging on macOS."
}

Push-Location (Join-Path $here "work")
try {
    & $sevenzip a -tzip -mx=5 -bd "-xr!*.bak" $out Payload | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "7z failed with exit $LASTEXITCODE" }
} finally {
    Pop-Location
}

Write-Host "wrote $out"
Get-Item $out | Format-List Length, LastWriteTime
