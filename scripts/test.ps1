param([string]$StudioPath = $env:DEVECO_STUDIO_HOME)

$ErrorActionPreference = 'Stop'
if (-not $StudioPath) {
    $StudioPath = Join-Path $env:ProgramFiles 'Huawei\DevEco Studio'
}
$projectPath = Split-Path -Parent $PSScriptRoot
$nodePath = Join-Path $StudioPath 'tools\node\node.exe'
$hvigorPath = Join-Path $StudioPath 'tools\hvigor\bin\hvigorw.js'
if (-not (Test-Path -LiteralPath $nodePath) -or -not (Test-Path -LiteralPath $hvigorPath)) {
    throw 'DevEco Studio not found. Set DEVECO_STUDIO_HOME or pass -StudioPath.'
}
$env:DEVECO_SDK_HOME = Join-Path $StudioPath 'sdk'
$env:JAVA_HOME = Join-Path $StudioPath 'jbr'
$startedAt = Get-Date
Push-Location -LiteralPath $projectPath
try {
    & $nodePath $hvigorPath test -p module=entry -p coverage=true
    if ($LASTEXITCODE -ne 0) { throw "Local tests failed: $LASTEXITCODE" }
    $resultPath = Join-Path $projectPath 'entry\.test\default\intermediates\test\coverage_data\test_result.txt'
    $resultFile = Get-Item -LiteralPath $resultPath
    if ($resultFile.LastWriteTime -lt $startedAt) { throw 'Test report was not refreshed.' }
    $result = Get-Content -LiteralPath $resultPath -Raw
    Write-Output $result
    if ($result -notmatch 'Tests run: (\d+), Failure: 0, Error: 0, Pass: (\d+), Ignore: 0') {
        throw 'Tests did not all pass; inspect the report above.'
    }
    if ([int]$Matches[1] -eq 0 -or $Matches[1] -ne $Matches[2]) {
        throw 'No complete passing test run was recorded.'
    }
} finally {
    Pop-Location
}
