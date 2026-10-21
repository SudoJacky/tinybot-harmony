param(
    [string]$HapPath = (Join-Path $PSScriptRoot '../entry/build/default/outputs/default/entry-default-unsigned.hap'),
    [switch]$RequireReleaseProfile,
    [string]$StudioRoot = $env:DEVECO_STUDIO_HOME
)

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
    if ($RequireReleaseProfile) {
        if (-not $StudioRoot) { $StudioRoot = Join-Path $env:ProgramFiles 'Huawei/DevEco Studio' }
        $declared = @($manifest.module.requestPermissions | ForEach-Object { $_.name })
        # The platform report explicitly requires this ACL for Tinybot. SDK provisionEnable
        # alone is not an ACL classifier (it is also true for INTERNET and MICROPHONE).
        $requiredAcl = @('ohos.permission.FILE_ACCESS_PERSIST' | Where-Object { $_ -in $declared })
        $auditRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.cache'))
        $auditPath = Join-Path $auditRoot ('release-profile-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $auditPath -Force | Out-Null
        try {
            $profilePath = Join-Path $auditPath 'embedded.p7b'
            $arguments = @('-jar', (Join-Path $StudioRoot 'sdk/default/openharmony/toolchains/lib/hap-sign-tool.jar'), 'verify-app',
                '-inFile', (Resolve-Path -LiteralPath $HapPath).Path, '-outCertChain', (Join-Path $auditPath 'chain.cer'), '-outProfile', $profilePath)
            $quotedArguments = $arguments | ForEach-Object { '"' + $_ + '"' }
            $verification = Start-Process -FilePath (Join-Path $StudioRoot 'jbr/bin/java.exe') -ArgumentList $quotedArguments `
                -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput (Join-Path $auditPath 'verify.log') -RedirectStandardError (Join-Path $auditPath 'verify-error.log')
            if ($verification.ExitCode -ne 0) { throw 'Signed HAP verification failed; provide the final signed HAP, not an unsigned package.' }
            if ($PSVersionTable.PSVersion.Major -lt 6) { Add-Type -AssemblyName System.Security }
            else { Add-Type -AssemblyName System.Security.Cryptography.Pkcs }
            $cms = [Security.Cryptography.Pkcs.SignedCms]::new()
            $cms.Decode([IO.File]::ReadAllBytes($profilePath))
            $cms.CheckSignature($true)
            $profile = [Text.Encoding]::UTF8.GetString($cms.ContentInfo.Content) | ConvertFrom-Json
            $issues = @()
            if ($profile.type -ne 'release') { $issues += "Profile type is '$($profile.type)', expected release" }
            if ($profile.'bundle-info'.'bundle-name' -ne $manifest.app.bundleName) { $issues += 'Profile bundle name differs from HAP' }
            $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            if (-not $profile.validity -or $now -lt $profile.validity.'not-before' -or $now -ge $profile.validity.'not-after') { $issues += 'Profile is outside its validity period' }
            $allowed = @($profile.acls.'allowed-acls')
            $missing = @($requiredAcl | Where-Object { $_ -notin $allowed })
            $extra = @($allowed | Where-Object { $_ -notin $declared })
            if ($missing.Count -gt 0) { $issues += "Profile missing ACL: $($missing -join ', ')" }
            if ($extra.Count -gt 0) { $issues += "Profile ACL absent from HAP declarations: $($extra -join ', ')" }
            if ($issues.Count -gt 0) { throw ($issues -join '; ') }
        } finally {
            $resolvedAudit = [IO.Path]::GetFullPath($auditPath)
            if (-not $resolvedAudit.StartsWith($auditRoot + [IO.Path]::DirectorySeparatorChar)) { throw 'Unsafe audit cleanup path' }
            Remove-Item -LiteralPath $resolvedAudit -Recurse -Force
        }
    }
    [pscustomobject]@{
        Package = (Resolve-Path -LiteralPath $HapPath).Path
        PackageMiB = [Math]::Round((Get-Item -LiteralPath $HapPath).Length / 1MB, 3)
        NativeMiB = [Math]::Round(($nativeLibraries | Measure-Object CompressedLength -Sum).Sum / 1MB, 3)
        Architectures = 'arm64-v8a'
        ProfileCheck = $(if ($RequireReleaseProfile) { 'Embedded release Profile and ACL checked; platform acceptance still required' } else { 'Not checked: package structure only' })
    }
} finally { $package.Dispose() }
