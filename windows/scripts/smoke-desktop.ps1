param([string]$Executable,[string]$AppDirectory,[switch]$AllowUnpackaged,[ValidateRange(10,180)][int]$TimeoutSeconds=45)
$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path $PSScriptRoot -Parent
if (!$Executable) { $Executable = Join-Path $taskRoot 'release/win-unpacked/Phosphor.exe' }
$taskReportDirectory = Join-Path $taskRoot 'test-output'
New-Item -ItemType Directory -Path $taskReportDirectory -Force | Out-Null
$taskReport = Join-Path $taskReportDirectory ('desktop-' + [guid]::NewGuid().ToString() + '.json')
$previousReport = $env:PHOSPHOR_SELF_TEST_REPORT
$previousFixture = $env:PHOSPHOR_SELF_TEST_FIXTURE
$taskFixturePath = Join-Path $taskReportDirectory ('desktop-fixture-' + [guid]::NewGuid().ToString())
try {
    $env:PHOSPHOR_SELF_TEST_FIXTURE = & (Join-Path $taskRoot '.venv/Scripts/python.exe') (Join-Path $PSScriptRoot 'make-desktop-fixture.py') $taskFixturePath
    if ($LASTEXITCODE -ne 0) { throw 'Could not create the synthetic desktop fixture.' }
    $env:PHOSPHOR_SELF_TEST_REPORT = $taskReport
    $taskArguments = if ($AppDirectory) { @(('"' + $AppDirectory + '"'),'--self-test') } else { @('--self-test') }
    $taskProcess = Start-Process -FilePath $Executable -ArgumentList $taskArguments -WindowStyle Hidden -PassThru
    if (!$taskProcess.WaitForExit($TimeoutSeconds*1000)) { $taskProcess.Kill(); throw 'Desktop startup check timed out.' }
    $result = Get-Content -LiteralPath $taskReport -Raw | ConvertFrom-Json
    if ((!$AllowUnpackaged -and !$result.packaged) -or !$result.rendererLoaded -or !$result.rendererBridge -or !$result.engine -or !$result.mediaProtocol -or !$result.pdfPreview -or $result.error) {
        throw ('Desktop startup check failed: ' + ($result | ConvertTo-Json -Compress))
    }
    $result | Add-Member -NotePropertyName executableSha256 -NotePropertyValue (Get-FileHash -LiteralPath $Executable -Algorithm SHA256).Hash.ToLowerInvariant()
    $result | ConvertTo-Json | Set-Content -LiteralPath $taskReport -Encoding utf8
    $result | ConvertTo-Json
    Write-Output 'PASS: renderer, preload bridge, bundled engine, real PDF canvas, private media ranges and lock revocation.'
}
finally {
    $env:PHOSPHOR_SELF_TEST_REPORT = $previousReport
    $env:PHOSPHOR_SELF_TEST_FIXTURE = $previousFixture
    $taskFixtureResolved = [IO.Path]::GetFullPath($taskFixturePath)
    $taskReportResolved = [IO.Path]::GetFullPath($taskReportDirectory).TrimEnd('\') + '\'
    if ($taskFixtureResolved.StartsWith($taskReportResolved,[StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $taskFixtureResolved)) { Remove-Item -LiteralPath $taskFixtureResolved -Recurse -Force }
}
