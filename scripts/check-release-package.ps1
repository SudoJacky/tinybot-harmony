param([string]$HapPath = (Join-Path $PSScriptRoot '../entry/build/default/outputs/default/entry-default-unsigned.hap'))

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$package = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $HapPath).Path)
try {
    $reader = [System.IO.StreamReader]::new($package.GetEntry('module.json').Open())
    try { $manifest = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
    if ($manifest.app.buildMode -ne 'release' -or $manifest.app.debug) {
        throw 'Expected a release package with debugging disabled.'
    }
    if (-not $manifest.module.compressNativeLibs) { throw 'Native library compression is disabled.' }

    $nativeLibraries = @($package.Entries | Where-Object { $_.FullName -match '^libs/.+\.so$' })
    foreach ($library in $nativeLibraries) {
        if (-not $library.FullName.StartsWith('libs/arm64-v8a/')) {
            throw "Unexpected release architecture: $($library.FullName)"
        }
        if ($library.CompressedLength -ge $library.Length) {
            throw "Native library was not compressed: $($library.FullName)"
        }
    }
    foreach ($required in @('libs/arm64-v8a/libtinybot_sandbox.so', 'libs/arm64-v8a/libc++_shared.so',
        'ets/modules.abc', 'resources/base/media/team_employee_portraits.webp')) {
        $entry = $package.GetEntry($required)
        if (-not $entry -or $entry.Length -eq 0) { throw "Missing release content: $required" }
    }
    $legacyNames = @('background.png', 'foreground.png', 'layered_image.json', 'startIcon.png', 'team_employee_portraits.png')
    foreach ($entry in $package.Entries) {
        if ($entry.FullName -match '(?i)source.?maps?\.(map|json)$' -or
            $entry.FullName -match '^resources/rawfile/interactive-web/example(-2d)?\.json$' -or
            ($entry.FullName.StartsWith('resources/') -and $legacyNames -contains $entry.Name)) {
            throw "Unexpected debug or legacy content: $($entry.FullName)"
        }
    }
    [pscustomobject]@{
        Package = (Resolve-Path -LiteralPath $HapPath).Path
        PackageMiB = [Math]::Round((Get-Item -LiteralPath $HapPath).Length / 1MB, 3)
        NativeMiB = [Math]::Round(($nativeLibraries | Measure-Object CompressedLength -Sum).Sum / 1MB, 3)
        Architectures = 'arm64-v8a'
    }
} finally { $package.Dispose() }
