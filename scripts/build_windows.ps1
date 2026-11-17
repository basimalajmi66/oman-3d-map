# Build the Windows desktop app + bundled local engine.
# Requirements: Flutter (Windows desktop enabled, Visual Studio C++ workload), Python 3.11+.
# Output: app\build\windows\x64\runner\Release\  (uata_app.exe + engine\uata-engine.exe)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
function Check { if ($LASTEXITCODE -ne 0) { throw "command failed ($LASTEXITCODE)" } }

Push-Location "$root\backend"
python -m pip install -r requirements.txt pyinstaller; Check
python -m PyInstaller --noconfirm --onefile --name uata-engine --collect-data uata run_engine.py; Check
Pop-Location

Push-Location "$root\app"
flutter pub get; Check
flutter build windows --release; Check
$release = "build\windows\x64\runner\Release"
New-Item -ItemType Directory -Force "$release\engine" | Out-Null
Copy-Item "$root\backend\dist\uata-engine.exe" "$release\engine\uata-engine.exe" -Force
Pop-Location

Write-Host "Done: $root\app\$release"
