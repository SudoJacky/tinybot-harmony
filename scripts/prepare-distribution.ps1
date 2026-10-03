[CmdletBinding()]
param(
    [string]$StudioRoot = 'D:/DevEco Studio',
    [string]$OutputDirectory,
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$projectRoot = Split-Path $PSScriptRoot -Parent
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Read-ZipText($Archive, [string]$Name) {
    $entry = $Archive.GetEntry($Name)
    if ($null -eq $entry) { throw "Missing archive entry: $Name" }
    $reader = New-Object System.IO.StreamReader($entry.Open())
    try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
}

function Read-NativeBuildId([string]$ReadElf, [string]$Path) {
    $notes = & $ReadElf -n $Path
    if ($LASTEXITCODE -ne 0) { throw "Cannot read native build ID: $Path" }
    $match = [regex]::Match(($notes -join "`n"), 'Build ID:\s*([0-9a-fA-F]+)')
    if (-not $match.Success) { throw "Native build ID missing: $Path" }
    return $match.Groups[1].Value.ToLowerInvariant()
}

Push-Location $projectRoot
try {
    $nodePath = Join-Path $StudioRoot 'tools/node/node.exe'
    $json5Path = Join-Path $StudioRoot 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/json5'
    $sourceJson = & $nodePath -e 'const fs=require(''fs'');const j=require(process.argv[1]);process.stdout.write(JSON.stringify(j.parse(fs.readFileSync(process.argv[2],''utf8''))));' $json5Path (Join-Path $projectRoot 'AppScope/app.json5')
    if ($LASTEXITCODE -ne 0) { throw 'Cannot read source app configuration.' }
    $sourceApp = ($sourceJson | ConvertFrom-Json).app
    $baseName = "Tinybot-$($sourceApp.versionName)-$($sourceApp.versionCode)-release-UNSIGNED"
    if (-not $OutputDirectory) {
        $OutputDirectory = Join-Path $projectRoot "artifacts/distribution/Tinybot-$($sourceApp.versionName)-$($sourceApp.versionCode)-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    }
    $OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
    $zipPath = "$OutputDirectory.zip"
    if ((Test-Path -LiteralPath $OutputDirectory) -or (Test-Path -LiteralPath $zipPath)) {
        throw 'Output already exists. Choose a new -OutputDirectory; existing deliveries are never overwritten.'
    }

    if (-not $SkipBuild) {
        # This project uses direct connections, as requested by its owner.
        Remove-Item Env:HTTP_PROXY, Env:HTTPS_PROXY, Env:ALL_PROXY -ErrorAction SilentlyContinue
        & devecocli check arkts
        if ($LASTEXITCODE -ne 0) { throw 'ArkTS check failed.' }
        & devecocli build --product default --build-mode release
        if ($LASTEXITCODE -ne 0) { throw 'Release build failed.' }
    }

    $appPath = Join-Path $projectRoot 'build/outputs/default/tinybot-harmony-default-unsigned.app'
    $symbolsPath = Join-Path $projectRoot 'build/outputs/default/symbol/release/app-symbol.zip'
    if (-not (Test-Path -LiteralPath $symbolsPath)) {
        $symbolsPath = Join-Path $projectRoot 'build/outputs/default/symbol/app-symbol.zip'
    }
    foreach ($required in @($appPath, $symbolsPath)) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Missing build output: $required" }
    }
    $hapBytes = $null
    $nativeLibraries = @()
    $readElf = Join-Path $StudioRoot 'sdk/default/openharmony/native/llvm/bin/llvm-readelf.exe'
    $appArchive = [IO.Compression.ZipFile]::OpenRead($appPath)
    try {
        $pack = (Read-ZipText $appArchive 'pack.info') | ConvertFrom-Json
        $hapEntries = @($appArchive.Entries | Where-Object { $_.FullName.EndsWith('.hap') })
        if ($hapEntries.Count -ne 1) { throw 'Expected exactly one HAP. Update this script for additional modules.' }
        foreach ($entry in $appArchive.Entries) {
            if ($entry.FullName -notin @('entry-default.hap', 'pack.info', 'pac.json')) { throw "Unexpected APP entry: $($entry.FullName)" }
        }
        $hapBytes = New-Object IO.MemoryStream
        $hapStream = $hapEntries[0].Open()
        try { $hapStream.CopyTo($hapBytes) } finally { $hapStream.Dispose() }
        $hapBytes.Position = 0
        $hapArchive = [IO.Compression.ZipArchive]::new($hapBytes, [IO.Compression.ZipArchiveMode]::Read, $true)
        try {
            $manifest = (Read-ZipText $hapArchive 'module.json') | ConvertFrom-Json
            if ($manifest.app.debug -ne $false) { throw 'Refusing to distribute a debug build.' }
            if ($manifest.app.bundleName -ne 'com.sudojacky.tinybot' -or $manifest.app.bundleName -ne $sourceApp.bundleName) { throw 'Bundle name mismatch.' }
            if ($manifest.app.versionCode -ne $sourceApp.versionCode -or $manifest.app.versionName -ne $sourceApp.versionName) { throw 'Version mismatch: rebuild first.' }
            if ($pack.summary.app.bundleName -ne $sourceApp.bundleName -or $pack.summary.app.version.code -ne $sourceApp.versionCode) { throw 'APP and HAP metadata disagree.' }
            if ($pack.summary.modules[0].apiVersion.releaseType -ne 'Release') { throw 'Expected a Release SDK package.' }
            foreach ($entry in $hapArchive.Entries) {
                if ($entry.FullName -match '(?i)(\.(p12|p7b|pem|key|keystore)$|(^|/)(\.env|build-profile\.json5)$)') { throw "Unexpected sensitive file in HAP: $($entry.FullName)" }
            }
            if (-not ($hapArchive.Entries | Where-Object { $_.FullName.EndsWith('/THIRD_PARTY_NOTICES.txt') })) { throw 'Third-party notices missing from HAP.' }
            # 0.1.2 adds native execution. Check both cloud-phone and emulator
            # libraries and preserve matching unstripped binaries for crash diagnosis.
            foreach ($abi in @('arm64-v8a', 'x86_64')) {
                $library = "libs/$abi/libtinybot_sandbox.so"
                $nativeEntry = $hapArchive.GetEntry($library)
                if ($null -eq $nativeEntry) { throw "Native sandbox missing from HAP: $library" }
                $nativeStream = $nativeEntry.Open()
                $hasher = [Security.Cryptography.SHA256]::Create()
                try { $nativeHash = [BitConverter]::ToString($hasher.ComputeHash($nativeStream)).Replace('-', '').ToLowerInvariant() }
                finally { $hasher.Dispose(); $nativeStream.Dispose() }
                $strippedPath = Join-Path $projectRoot "entry/build/default/intermediates/stripped_native_libs/default/$abi/libtinybot_sandbox.so"
                $symbolPath = Join-Path $projectRoot "entry/build/default/intermediates/cmake/default/obj/$abi/libtinybot_sandbox.so"
                if ((Get-FileHash -LiteralPath $strippedPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $nativeHash) {
                    throw "Packaged native library is stale: $abi"
                }
                $buildId = Read-NativeBuildId $readElf $strippedPath
                if ((Read-NativeBuildId $readElf $symbolPath) -ne $buildId) { throw "Native symbols do not match HAP: $abi" }
                $sections = & $readElf -S $symbolPath
                if ($LASTEXITCODE -ne 0 -or ($sections -join "`n") -notmatch '\.debug_info\s') { throw "Native debug symbols missing: $abi" }
                $nativeLibraries += [ordered]@{ abi = $abi; path = $library; sha256 = $nativeHash; buildId = $buildId }
            }
        } finally { $hapArchive.Dispose() }

        foreach ($folder in @('packages', 'symbols', 'assets', 'screenshots', 'licenses')) {
            New-Item -ItemType Directory -Path (Join-Path $OutputDirectory $folder) -Force | Out-Null
        }
        Copy-Item -LiteralPath $appPath -Destination (Join-Path $OutputDirectory "packages/$baseName.app")
        [IO.File]::WriteAllBytes((Join-Path $OutputDirectory "packages/$baseName.hap"), $hapBytes.ToArray())
    } finally {
        $appArchive.Dispose()
        if ($null -ne $hapBytes) { $hapBytes.Dispose() }
    }

    Copy-Item -LiteralPath $symbolsPath -Destination (Join-Path $OutputDirectory 'symbols/app-symbol.zip')
    foreach ($abi in @('arm64-v8a', 'x86_64')) {
        $nativeDestination = Join-Path $OutputDirectory "symbols/native/$abi"
        New-Item -ItemType Directory -Path $nativeDestination -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $projectRoot "entry/build/default/intermediates/cmake/default/obj/$abi/libtinybot_sandbox.so") -Destination $nativeDestination
    }
    Copy-Item -LiteralPath 'artifacts/app-store/tinybot-icon-1024.png' -Destination (Join-Path $OutputDirectory 'assets')
    Copy-Item -Path 'docs/distribution/*.txt' -Destination $OutputDirectory
    Copy-Item -LiteralPath 'LICENSE' -Destination (Join-Path $OutputDirectory 'licenses/APACHE-2.0.txt')
    Copy-Item -LiteralPath 'entry/src/main/resources/rawfile/THIRD_PARTY_NOTICES.txt' -Destination (Join-Path $OutputDirectory 'licenses')
    Copy-Item -LiteralPath 'entry/src/main/cpp/third_party/quickjs/LICENSE' -Destination (Join-Path $OutputDirectory 'licenses/QuickJS-MIT.txt')
    if (Test-Path -LiteralPath 'artifacts/store-screenshots') {
        Get-ChildItem -LiteralPath 'artifacts/store-screenshots' -File | Where-Object { $_.Extension -in @('.png', '.txt') } | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $OutputDirectory 'screenshots')
        }
    }

    $sdk = Get-Content -LiteralPath (Join-Path $StudioRoot 'sdk/default/sdk-pkg.json') -Raw | ConvertFrom-Json
    $files = @(Get-ChildItem -LiteralPath $OutputDirectory -Recurse -File | ForEach-Object {
        [ordered]@{ path = $_.FullName.Substring($OutputDirectory.Length + 1).Replace('\', '/'); bytes = $_.Length; sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
    })
    $info = [ordered]@{
        preparedAt = (Get-Date).ToString('o')
        bundleName = $manifest.app.bundleName
        developerType = 'individual'
        developerName = $null
        contactEmail = $null
        privacyPolicyUrl = $null
        versionName = $manifest.app.versionName
        versionCode = $manifest.app.versionCode
        buildMode = 'release'
        debug = $manifest.app.debug
        minimumApi = $pack.summary.modules[0].apiVersion.compatible
        targetApi = $pack.summary.modules[0].apiVersion.target
        sdkVersion = $sdk.data.version
        deviceTypes = $manifest.module.deviceTypes
        nativeLibraries = $nativeLibraries
        signing = 'unsigned; cloud-managed release signing required before upload/install'
        uploadedToAGC = $false
        rebuiltThisRun = (-not $SkipBuild.IsPresent)
        originalBuildAppPath = 'build/outputs/default/tinybot-harmony-default-unsigned.app'
        pending = @('Cloud signing and platform validation', 'Developer name and contact', 'Final privacy policy URL and in-app privacy flow', 'AGC qualification requirements', 'Cloud test results and review model access')
        files = $files
    }
    $utf8 = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText((Join-Path $OutputDirectory 'package-info.json'), ($info | ConvertTo-Json -Depth 12), $utf8)
    $checksums = @(Get-ChildItem -LiteralPath $OutputDirectory -Recurse -File | Sort-Object FullName | ForEach-Object {
        $relativePath = $_.FullName.Substring($OutputDirectory.Length + 1).Replace('\', '/')
        "$( (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() )  $relativePath"
    })
    [IO.File]::WriteAllLines((Join-Path $OutputDirectory 'SHA256SUMS.txt'), $checksums, $utf8)
    [IO.Compression.ZipFile]::CreateFromDirectory($OutputDirectory, $zipPath)
    Write-Output "Prepared: $OutputDirectory"
    Write-Output "Delivery ZIP: $zipPath"
    Write-Output 'Unsigned release input only. Use DevEco Studio Upload Product for cloud signing.'
} finally { Pop-Location }
