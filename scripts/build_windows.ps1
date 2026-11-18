# Build the Windows desktop app + bundled local engine (+ optional Tesseract OCR and installer).
# Requirements: Flutter (Windows desktop enabled, Visual Studio C++ workload), Python 3.11+.
# Optional: -BundleTesseract (Chocolatey available), -Installer (Inno Setup 6 / ISCC.exe on PATH or default folder).
# Output: app\build\windows\x64\runner\Release\  and, with -Installer, dist\UATA-Setup-<version>.exe
param([switch]$BundleTesseract, [switch]$Installer, [string]$Version = "0.1.0")
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
function Check { if ($LASTEXITCODE -ne 0) { throw "command failed ($LASTEXITCODE)" } }

# 1) engine as a standalone executable (data files of uata, python-docx templates, ffmpeg binary)
Push-Location "$root\backend"
python -m pip install -r requirements.txt pyinstaller; Check
python -m PyInstaller --noconfirm --onefile --name uata-engine `
  --collect-data uata --collect-data docx --collect-binaries imageio_ffmpeg --collect-data imageio_ffmpeg `
  run_engine.py; Check
Pop-Location

# 2) Flutter desktop app
Push-Location "$root\app"
flutter pub get; Check
$build = if ($env:GITHUB_RUN_NUMBER) { $env:GITHUB_RUN_NUMBER } else { "dev" }
flutter build windows --release --dart-define=UATA_BUILD=$build; Check
$release = "build\windows\x64\runner\Release"
New-Item -ItemType Directory -Force "$release\engine" | Out-Null
Copy-Item "$root\backend\dist\uata-engine.exe" "$release\engine\uata-engine.exe" -Force

# 3) Tesseract OCR (Apache-2.0) with English + Arabic, next to the engine: <install>\tesseract\tesseract.exe
if ($BundleTesseract) {
  choco install tesseract -y --no-progress; Check
  $src = "C:\Program Files\Tesseract-OCR"
  if (-not (Test-Path "$src\tesseract.exe")) { throw "Tesseract not found in $src" }
  Copy-Item $src "$release\tesseract" -Recurse -Force
  $ara = "$release\tesseract\tessdata\ara.traineddata"
  if (-not (Test-Path $ara)) {
    Invoke-WebRequest "https://github.com/tesseract-ocr/tessdata_fast/raw/main/ara.traineddata" -OutFile $ara
  }
}
Pop-Location

# 4) installer
if ($Installer) {
  $iscc = (Get-Command ISCC.exe -ErrorAction SilentlyContinue).Source
  if (-not $iscc) { $iscc = "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe" }
  & $iscc "/DAppVersion=$Version" "$root\installer\uata.iss"; Check
}
Write-Host "Done: $root\app\$release"
