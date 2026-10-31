param([switch]$SkipInstall, [switch]$PortableOnly)
$ErrorActionPreference = 'Stop'
$env:PYTEST_DISABLE_PLUGIN_AUTOLOAD = '1'
$taskRoot = Split-Path $PSScriptRoot -Parent
Set-Location -LiteralPath $taskRoot
function Invoke-Checked([scriptblock]$Command) {
    & $Command
    if ($LASTEXITCODE -ne 0) { throw "Build command failed with exit code $LASTEXITCODE" }
}
if (!(Test-Path -LiteralPath '.venv/Scripts/python.exe')) { Invoke-Checked { python -m venv .venv } }
if (!$SkipInstall) {
    if (Test-Path -LiteralPath 'requirements.lock.txt') { Invoke-Checked { .venv/Scripts/python.exe -m pip install -r requirements.lock.txt } }
    else { Invoke-Checked { .venv/Scripts/python.exe -m pip install -r requirements.txt } }
    Invoke-Checked { npm.cmd ci }
}
Invoke-Checked { node node_modules/electron/install.js }
Invoke-Checked { .venv/Scripts/python.exe scripts/create-icon.py }
Invoke-Checked { .venv/Scripts/python.exe -m pytest tests -q --tb=short -p no:cacheprovider --basetemp test-output/build-tests }
Invoke-Checked { node --test tests/preview-protocol.test.cjs tests/pdf-range.test.cjs }
Invoke-Checked { npx.cmd tsc --noEmit --noUnusedLocals --noUnusedParameters }
Invoke-Checked { .venv/Scripts/python.exe -m pip freeze | Set-Content -LiteralPath requirements.lock.txt -Encoding utf8 }
Invoke-Checked { .venv/Scripts/python.exe scripts/collect-licenses.py }
$taskEngineBuild = Join-Path 'backend-build' ([guid]::NewGuid().ToString())
Invoke-Checked { .venv/Scripts/python.exe -m PyInstaller engine.spec --noconfirm --distpath backend-dist --workpath $taskEngineBuild }
Invoke-Checked { .venv/Scripts/python.exe scripts/smoke-engine.py --frozen }
Invoke-Checked { npm.cmd run build }
if ($PortableOnly) { Invoke-Checked { npx.cmd electron-builder --win portable --x64 --config.electronDist=node_modules/electron/dist } }
else { Invoke-Checked { npx.cmd electron-builder --win nsis portable --x64 --config.electronDist=node_modules/electron/dist } }
& "$PSScriptRoot/smoke-desktop.ps1"
Invoke-Checked { .venv/Scripts/python.exe scripts/smoke-engine.py --engine release/win-unpacked/resources/engine/phosphor-engine.exe }
Invoke-Checked { .venv/Scripts/python.exe scripts/package-source.py }
Get-ChildItem -LiteralPath release -File | Where-Object { $_.Extension -in @('.exe','.zip') } | ForEach-Object {
    $hash = Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256
    "$($hash.Hash.ToLower())  $($_.Name)"
} | Set-Content -LiteralPath release/SHA256SUMS.txt -Encoding utf8
