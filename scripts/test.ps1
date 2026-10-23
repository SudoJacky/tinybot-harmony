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
& $nodePath (Join-Path $projectPath 'scripts/build-locales.cjs') --check
if ($LASTEXITCODE -ne 0) { throw 'Locale validation failed. Run node scripts/build-locales.cjs after editing translations.' }
& $nodePath (Join-Path $projectPath 'scripts/test-huawei-account.cjs')
if ($LASTEXITCODE -ne 0) { throw 'Huawei account tests failed.' }
& $nodePath (Join-Path $projectPath 'scripts/test-hosted-privacy.cjs')
if ($LASTEXITCODE -ne 0) { throw 'Hosted privacy state and startup gating tests failed.' }
& $nodePath (Join-Path $projectPath 'scripts/test-announcements.cjs')
if ($LASTEXITCODE -ne 0) { throw 'Announcement startup, persistence and dialog tests failed.' }
& $nodePath (Join-Path $projectPath 'scripts/test-app-information.cjs')
if ($LASTEXITCODE -ne 0) { throw 'App review navigation and error handling tests failed.' }
& $nodePath (Join-Path $projectPath 'scripts/build-builtin-skills.cjs') --check
if ($LASTEXITCODE -ne 0) { throw 'Built-in Skills are stale. Run node scripts/build-builtin-skills.cjs.' }
& $nodePath (Join-Path $projectPath 'scripts/test-developer-diagnostics.cjs')
if ($LASTEXITCODE -ne 0) { throw 'Developer diagnostics collection, export and lifecycle tests failed.' }
& $nodePath (Join-Path $projectPath 'scripts/test-unified-logging.cjs')
if ($LASTEXITCODE -ne 0) { throw 'Unified runtime log levels, redaction, export and disabled-path tests failed.' }
& $nodePath (Join-Path $projectPath 'scripts/test-browser.cjs')
if ($LASTEXITCODE -ne 0) { throw 'Browser permission, takeover and runtime pause tests failed.' }
& $nodePath (Join-Path $projectPath 'scripts/test-browser-annotation.cjs')
if ($LASTEXITCODE -ne 0) { throw 'Browser annotation geometry, export and image delivery tests failed.' }
$env:DEVECO_STUDIO_HOME = $StudioPath
& $nodePath (Join-Path $projectPath 'scripts/test-gemini.cjs')
if ($LASTEXITCODE -ne 0) { throw 'Gemini protocol and signed tool loop tests failed.' }
& $nodePath (Join-Path $projectPath 'scripts/test-code-highlight.cjs')
if ($LASTEXITCODE -ne 0) { throw 'Markdown code highlighting tests failed.' }
& $nodePath (Join-Path $projectPath 'scripts/test-stream-reveal.cjs')
if ($LASTEXITCODE -ne 0) { throw 'Streaming text reveal tests failed.' }
& $nodePath (Join-Path $projectPath 'scripts/test-conversation-export.cjs')
if ($LASTEXITCODE -ne 0) { throw 'Conversation export metadata, PNG composition and cleanup tests failed.' }
& $nodePath (Join-Path $projectPath 'scripts/test-markdown-performance.cjs')
if ($LASTEXITCODE -ne 0) { throw 'Markdown incremental parsing and renderer tests failed. Build the app first.' }
& $nodePath (Join-Path $projectPath 'scripts/test-speech-orb.cjs')
if ($LASTEXITCODE -ne 0) { throw 'Voice input UI lifecycle tests failed. Build the app first.' }
& $nodePath (Join-Path $projectPath 'scripts/test-voice-composer.cjs')
if ($LASTEXITCODE -ne 0) { throw 'Voice composer tests failed. Build the app first.' }
& $nodePath (Join-Path $projectPath 'scripts/test-drawing-board.cjs')
if ($LASTEXITCODE -ne 0) { throw 'Drawing board and composer attachment tests failed. Build the app first.' }
& $nodePath (Join-Path $projectPath 'scripts/test-skill-completion.cjs')
if ($LASTEXITCODE -ne 0) { throw 'Skill completion and composer callback tests failed. Build the app first.' }
& $nodePath (Join-Path $projectPath 'scripts/test-appearance.cjs')
if ($LASTEXITCODE -ne 0) { throw 'Appearance preference and palette tests failed.' }
& $nodePath (Join-Path $projectPath 'scripts/test-settings-performance.cjs')
if ($LASTEXITCODE -ne 0) { throw 'Settings responsiveness and persistence tests failed. Build the app first.' }
& $nodePath (Join-Path $projectPath 'scripts/test-settings-navigation.cjs')
if ($LASTEXITCODE -ne 0) { throw 'Settings subpage drafts, credentials and return callbacks failed. Build the app first.' }
& $nodePath (Join-Path $projectPath 'scripts/test-history-drawer.cjs')
if ($LASTEXITCODE -ne 0) { throw 'History drawer activity and animation lifecycle tests failed. Build the app first.' }
& $nodePath (Join-Path $projectPath 'scripts/test-harness-features.cjs')
if ($LASTEXITCODE -ne 0) { throw 'Search, delivery, references and runtime reliability tests failed.' }
& $nodePath (Join-Path $projectPath 'scripts/test-preview-publication.cjs')
if ($LASTEXITCODE -ne 0) { throw 'Preview publication integration tests failed.' }
& $nodePath (Join-Path $projectPath 'scripts/test-preview-lifecycle.cjs')
if ($LASTEXITCODE -ne 0) { throw 'Preview resource and lazy lifecycle tests failed. Build the app first.' }
& $nodePath (Join-Path $projectPath 'scripts/test-turn-workflow.cjs')
if ($LASTEXITCODE -ne 0) { throw 'Streaming timeline projection and retained process row tests failed. Build the app first.' }
& $nodePath (Join-Path $projectPath 'scripts/test-resources.cjs')
if ($LASTEXITCODE -ne 0) { throw 'Resource management integration tests failed.' }
& $nodePath (Join-Path $projectPath 'scripts/test-tool-schemas.cjs')
if ($LASTEXITCODE -ne 0) { throw 'Native tool parameter schema and execution tests failed.' }
& $nodePath (Join-Path $projectPath 'scripts/test-tool-discovery.cjs')
if ($LASTEXITCODE -ne 0) { throw 'Compact tool discovery, permission and runtime tests failed.' }
& $nodePath (Join-Path $projectPath 'scripts/test-prefix-cache.cjs')
if ($LASTEXITCODE -ne 0) { throw 'Request prefix, durable context, team sharing and cache configuration tests failed.' }
& $nodePath (Join-Path $projectPath 'scripts/test-context-usage.cjs')
if ($LASTEXITCODE -ne 0) { throw 'Conversation context usage aggregation tests failed. Build the app first.' }
& $nodePath (Join-Path $projectPath 'scripts/test-usage-filter-sheet.cjs')
if ($LASTEXITCODE -ne 0) { throw 'Usage filter sheet lifecycle tests failed. Build the app first.' }
& $nodePath (Join-Path $projectPath 'scripts/test-memory.cjs')
if ($LASTEXITCODE -ne 0) { throw 'Memory maintenance integration tests failed.' }
& $nodePath (Join-Path $projectPath 'scripts/test-code-sandbox.cjs')
if ($LASTEXITCODE -ne 0) { throw 'Code sandbox adapter tests failed.' }
& $nodePath (Join-Path $projectPath 'scripts/test-orchestration.cjs')
if ($LASTEXITCODE -ne 0) { throw 'Orchestration integration tests failed.' }
& $nodePath (Join-Path $projectPath 'scripts/test-tool-details.cjs')
if ($LASTEXITCODE -ne 0) { throw 'Tool detail presentation tests failed.' }
& $nodePath (Join-Path $projectPath 'scripts/test-window-viewport.cjs')
if ($LASTEXITCODE -ne 0) { throw 'Window viewport integration tests failed.' }
& $nodePath (Join-Path $projectPath 'scripts/test-answer-speech-native.cjs')
if ($LASTEXITCODE -ne 0) { throw 'Answer speech and launch shortcut tests failed.' }
& $nodePath (Join-Path $projectPath 'scripts/test-launch-actions-renderer.cjs')
if ($LASTEXITCODE -ne 0) { throw 'Desktop service card and launch action renderer tests failed. Build the app first.' }
& $nodePath (Join-Path $projectPath 'scripts/test-conversation-share.cjs')
if ($LASTEXITCODE -ne 0) { throw 'Conversation sharing tests failed. Build the app first.' }
& $nodePath (Join-Path $projectPath 'scripts/test-team-toggle.cjs')
if ($LASTEXITCODE -ne 0) { throw 'Team mode persistence and projection tests failed.' }
& $nodePath (Join-Path $projectPath 'scripts/test-custom-tools.cjs')
if ($LASTEXITCODE -ne 0) { throw 'Custom tool selection and inherited execution tests failed.' }
& $nodePath (Join-Path $projectPath 'scripts/test-custom-tools-renderer.cjs')
if ($LASTEXITCODE -ne 0) { throw 'Custom tool selection UI callback tests failed. Build the app first.' }
& $nodePath (Join-Path $projectPath 'scripts/test-workspace-backup-ui.cjs')
if ($LASTEXITCODE -ne 0) { throw 'Workspace backup and failed-save UI callbacks failed. Build the app first.' }
& $nodePath (Join-Path $projectPath 'scripts/test-help-demo.cjs')
if ($LASTEXITCODE -ne 0) { throw 'Help demo animation lifecycle tests failed. Build the app first.' }
& $nodePath (Join-Path $projectPath 'scripts/test-legal-documents.cjs')
if ($LASTEXITCODE -ne 0) { throw 'Bundled legal document reading and text preservation tests failed. Build the app first.' }
& $nodePath (Join-Path $projectPath 'scripts/test-onboarding.cjs')
if ($LASTEXITCODE -ne 0) { throw 'First-use onboarding persistence, native mascot and navigation tests failed. Build the app first.' }
$env:DEVECO_SDK_HOME = Join-Path $StudioPath 'sdk'
$env:JAVA_HOME = Join-Path $StudioPath 'jbr'
$startedAt = Get-Date
Push-Location -LiteralPath $projectPath
try {
    & $nodePath $hvigorPath test -p module=entry -p coverage=true --no-daemon --no-parallel
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
