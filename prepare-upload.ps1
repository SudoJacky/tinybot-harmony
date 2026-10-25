[CmdletBinding()]
param(
    [string]$DistributionDirectory,
    [string]$TargetProjectRoot,
    [string]$StudioRoot = $env:DEVECO_STUDIO_HOME
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.IO.Compression.FileSystem

if (-not $TargetProjectRoot) {
    $commonDirectory = & git -C $PSScriptRoot rev-parse --path-format=absolute --git-common-dir
    if ($LASTEXITCODE -ne 0) { throw 'Cannot locate the main checkout. Specify -TargetProjectRoot.' }
    $TargetProjectRoot = Split-Path $commonDirectory -Parent
}
$TargetProjectRoot = (Resolve-Path -LiteralPath $TargetProjectRoot).Path
if (-not $StudioRoot) { $StudioRoot = Join-Path $env:ProgramFiles 'Huawei/DevEco Studio' }
$sourceJson = & (Join-Path $StudioRoot 'tools/node/node.exe') -e 'const fs=require(''fs'');const j=require(process.argv[1]);process.stdout.write(JSON.stringify(j.parse(fs.readFileSync(process.argv[2],''utf8''))));' (Join-Path $StudioRoot 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/json5') (Join-Path $TargetProjectRoot 'AppScope/app.json5')
if ($LASTEXITCODE -ne 0) { throw 'Cannot read the main checkout app configuration.' }
$expected = ($sourceJson | ConvertFrom-Json).app

if (-not $DistributionDirectory) {
    $distributionRoot = Join-Path $TargetProjectRoot 'artifacts/distribution'
    if (-not (Test-Path -LiteralPath $distributionRoot -PathType Container)) {
        throw 'No prepared distribution found. Run scripts/prepare-distribution.ps1 first.'
    }
    $candidates = @(Get-ChildItem -LiteralPath $distributionRoot -Directory |
        Where-Object { $_.Name.StartsWith("Tinybot-$($expected.versionName)-$($expected.versionCode)-") } |
        ForEach-Object {
            $infoPath = Join-Path $_.FullName 'package-info.json'
            if ((Test-Path -LiteralPath $infoPath -PathType Leaf) -and
                (Test-Path -LiteralPath ($_.FullName + '.zip') -PathType Leaf)) {
                $info = Get-Content -LiteralPath $infoPath -Raw -Encoding UTF8 | ConvertFrom-Json
                [pscustomobject]@{ Path = $_.FullName; PreparedAt = [DateTimeOffset]$info.preparedAt }
            }
        } | Sort-Object PreparedAt -Descending)
    if ($candidates.Count -eq 0) {
        throw "No prepared distribution for $($expected.versionName) / $($expected.versionCode). Run scripts/prepare-distribution.ps1 first."
    }
    $DistributionDirectory = $candidates[0].Path
}
$DistributionDirectory = (Resolve-Path -LiteralPath $DistributionDirectory).Path
$info = Get-Content -LiteralPath (Join-Path $DistributionDirectory 'package-info.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if ($info.bundleName -ne $expected.bundleName -or $info.versionName -ne $expected.versionName -or
    $info.versionCode -ne $expected.versionCode -or $info.buildMode -ne 'release' -or $info.debug -ne $false) {
    throw 'Distribution bundle/version must match the main checkout and be a non-debug Release build.'
}

$baseName = "Tinybot-$($expected.versionName)-$($expected.versionCode)-release-UNSIGNED"
$appRelative = "packages/$baseName.app"
$symbolRelative = 'symbols/app-symbol.zip'
foreach ($relative in @($appRelative, $symbolRelative)) {
    $records = @($info.files | Where-Object { $_.path -eq $relative })
    if ($records.Count -ne 1) { throw "Missing or duplicate distribution hash: $relative" }
    if ((Get-FileHash -LiteralPath (Join-Path $DistributionDirectory $relative) -Algorithm SHA256).Hash -ne $records[0].sha256) {
        throw "Distribution hash mismatch: $relative"
    }
}

$appPath = Join-Path $DistributionDirectory $appRelative
$archive = [IO.Compression.ZipFile]::OpenRead($appPath)
try {
    $metadata = @{}
    foreach ($name in @('pack.info', 'pac.json')) {
        $entry = $archive.GetEntry($name)
        if ($null -eq $entry) { throw "Missing APP metadata: $name" }
        $reader = [IO.StreamReader]::new($entry.Open())
        try { $metadata[$name] = $reader.ReadToEnd() } finally { $reader.Dispose() }
    }
    $packApp = ($metadata['pack.info'] | ConvertFrom-Json).summary.app
    if ($packApp.bundleName -ne $expected.bundleName -or $packApp.version.name -ne $expected.versionName -or
        $packApp.version.code -ne $expected.versionCode) { throw 'APP metadata does not match the main checkout.' }
    $hapEntry = $archive.GetEntry('entry-default.hap')
    if ($null -eq $hapEntry) { throw 'Missing entry-default.hap in APP.' }
    $hapBytes = [IO.MemoryStream]::new()
    $hapStream = $hapEntry.Open()
    try { $hapStream.CopyTo($hapBytes) } finally { $hapStream.Dispose() }
    $hapBytes.Position = 0
    $hapArchive = [IO.Compression.ZipArchive]::new($hapBytes, [IO.Compression.ZipArchiveMode]::Read)
    try {
        $moduleEntry = $hapArchive.GetEntry('module.json')
        if ($null -eq $moduleEntry) { throw 'Missing HAP manifest.' }
        $reader = [IO.StreamReader]::new($moduleEntry.Open())
        try { $app = ($reader.ReadToEnd() | ConvertFrom-Json).app } finally { $reader.Dispose() }
        if ($app.bundleName -ne $expected.bundleName -or $app.versionName -ne $expected.versionName -or
            $app.versionCode -ne $expected.versionCode -or $app.buildMode -ne 'release' -or $app.debug -ne $false) {
            throw 'Embedded HAP must match the main checkout and be a non-debug Release build.'
        }
    } finally { $hapArchive.Dispose(); $hapBytes.Dispose() }
} finally { $archive.Dispose() }

$outputRoot = [IO.Path]::GetFullPath((Join-Path $TargetProjectRoot 'build/outputs/default'))
$stagingRoot = Join-Path $TargetProjectRoot ('build/outputs/upload-' + [guid]::NewGuid().ToString('N'))
$backupRoot = Join-Path $TargetProjectRoot ('artifacts/upload-backups/' + [guid]::NewGuid().ToString('N'))
foreach ($path in @($outputRoot, $stagingRoot, $backupRoot)) {
    if (-not [IO.Path]::GetFullPath($path).StartsWith($TargetProjectRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Output/backup path escaped the target project.'
    }
}
New-Item -ItemType Directory -Path (Join-Path $stagingRoot 'symbol/release') -Force | Out-Null
Copy-Item -LiteralPath $appPath -Destination (Join-Path $stagingRoot 'tinybot-harmony-default-unsigned.app')
Copy-Item -LiteralPath (Join-Path $DistributionDirectory $symbolRelative) -Destination (Join-Path $stagingRoot 'symbol/release/app-symbol.zip')
$utf8 = [Text.UTF8Encoding]::new($false)
foreach ($name in $metadata.Keys) { [IO.File]::WriteAllText((Join-Path $stagingRoot $name), $metadata[$name], $utf8) }
$files = @('tinybot-harmony-default-unsigned.app', 'symbol/release/app-symbol.zip', 'pack.info', 'pac.json')
foreach ($pair in @(@('tinybot-harmony-default-unsigned.app', $appPath), @('symbol/release/app-symbol.zip', (Join-Path $DistributionDirectory $symbolRelative)))) {
    if ((Get-FileHash -LiteralPath (Join-Path $stagingRoot $pair[0]) -Algorithm SHA256).Hash -ne
        (Get-FileHash -LiteralPath $pair[1] -Algorithm SHA256).Hash) { throw 'Staged artifact copy hash mismatch.' }
}

$changed = @($files | Where-Object {
    $destination = Join-Path $outputRoot $_
    -not (Test-Path -LiteralPath $destination -PathType Leaf) -or
        (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -ne
        (Get-FileHash -LiteralPath (Join-Path $stagingRoot $_) -Algorithm SHA256).Hash
})
if ($changed.Count -eq 0) {
    # Only this invocation's four known files are removed; no recursive cleanup.
    foreach ($file in $files) { Remove-Item -LiteralPath (Join-Path $stagingRoot $file) }
    foreach ($directory in @('symbol/release', 'symbol', '')) { [IO.Directory]::Delete((Join-Path $stagingRoot $directory)) }
    Write-Output 'Upload artifacts already match; existing signing/upload results retained.'
} else {
    if (Test-Path -LiteralPath $outputRoot) {
        New-Item -ItemType Directory -Path (Split-Path $backupRoot -Parent) -Force | Out-Null
        Move-Item -LiteralPath $outputRoot -Destination $backupRoot
        Write-Output "Previous output backed up: $backupRoot"
    }
    try { Move-Item -LiteralPath $stagingRoot -Destination $outputRoot }
    catch {
        if ((Test-Path -LiteralPath $backupRoot) -and -not (Test-Path -LiteralPath $outputRoot)) {
            Move-Item -LiteralPath $backupRoot -Destination $outputRoot
        }
        throw
    }
}
Write-Output "Ready for Upload Product: $outputRoot"
Write-Output "Version: $($expected.versionName) / $($expected.versionCode)"
Write-Output "Source: $DistributionDirectory"
Write-Output 'Unsigned APP only; complete release signing in DevEco Studio.'
