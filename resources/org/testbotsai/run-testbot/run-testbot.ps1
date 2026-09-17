# Run TestBot — bundled PowerShell script for the Jenkins Shared Library
# (Windows agents).
#
# Loaded via libraryResource() by vars/runTestBot.groovy, written to the
# build workspace, and executed with the `powershell` pipeline step. Reads
# JWT_TOKEN and TEST_BOT_CONFIGURATION as environment variables (set by
# runTestBot.groovy from the customer's Jenkins Credentials), triggers a
# TestBot execution, polls until it completes, and writes JUnit + Markdown
# reports into the current workspace so the customer's Jenkinsfile can pick
# them up via `junit 'test-reports/*.xml'` and `archiveArtifacts`.
#
# This is the Windows-native counterpart to run-testbot.sh (used on
# macOS/Linux agents) — same logic, but uses only what ships with Windows
# PowerShell by default (Invoke-RestMethod, ConvertFrom/To-Json). No bash,
# curl, jq, or Python required.

$ErrorActionPreference = 'Stop'

# Older Windows PowerShell (5.1) defaults to TLS 1.0/1.1, which most modern
# HTTPS APIs reject outright — force TLS 1.2 before making any request.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$JwtToken = $env:JWT_TOKEN
$TestBotConfiguration = $env:TEST_BOT_CONFIGURATION
$PollIntervalSeconds = if ($env:POLL_INTERVAL_SECONDS) { [int]$env:POLL_INTERVAL_SECONDS } else { 5 }
$PollTimeoutMinutes = if ($env:POLL_TIMEOUT_MINUTES) { [int]$env:POLL_TIMEOUT_MINUTES } else { 345 }

$TestOpsBaseUrl = "https://api.automationhq.ai/ahq-test-bot-executor-services"

New-Item -ItemType Directory -Force -Path "results" | Out-Null
New-Item -ItemType Directory -Force -Path "test-reports" | Out-Null

function Sanitize([string]$msg) {
    if (-not $msg) { return "" }
    $flat = $msg -replace "`r`n", " " -replace "`n", " " -replace "`r", " "
    $flat = $flat -replace '\|', '\|'
    if ($flat.Length -gt 500) {
        return $flat.Substring(0, 500) + "... (truncated)"
    }
    return $flat
}

Write-Host "===== Validate Inputs ====="

if ([string]::IsNullOrEmpty($JwtToken)) {
    Write-Host "ERROR: JWT_TOKEN variable is empty. Set it in your Jenkinsfile's credentials binding."
    exit 1
}

try {
    $ConfigObj = $TestBotConfiguration | ConvertFrom-Json -ErrorAction Stop
} catch {
    $len = $TestBotConfiguration.Length
    $lines = ($TestBotConfiguration -split "`n").Count
    $first = if ($len -gt 0) { $TestBotConfiguration.Substring(0, 1) } else { "" }
    $last = if ($len -gt 0) { $TestBotConfiguration.Substring($len - 1, 1) } else { "" }
    $openBraces = ([regex]::Matches($TestBotConfiguration, '\{')).Count
    $closeBraces = ([regex]::Matches($TestBotConfiguration, '\}')).Count
    Write-Host "ERROR: TEST_BOT_CONFIGURATION is not valid JSON: $($_.Exception.Message)"
    Write-Host "   Diagnostic (no secret values shown): $len chars, $lines lines, starts with '$first', ends with '$last', braces: $openBraces open / $closeBraces close"
    exit 1
}

$TestBotId = $ConfigObj.testBotId
if ([string]::IsNullOrEmpty($TestBotId)) {
    Write-Host "ERROR: TEST_BOT_CONFIGURATION is missing a `"testBotId`" field"
    exit 1
}

$TestBotName = $ConfigObj.name
Write-Host "   Test Bot ID  : $TestBotId"
Write-Host "   Test Bot Name: $TestBotName"

Write-Host ""
Write-Host "===== Trigger and Poll TestBot Execution ====="

$TriggerUrl = "$TestOpsBaseUrl/rest/api/testops/$TestBotId/execute"
Write-Host "Triggering test bot execution..."
Write-Host "   Endpoint : $TriggerUrl"

$Headers = @{
    "Authorization" = "Bearer $JwtToken"
}

try {
    $TriggerResponse = Invoke-RestMethod -Uri $TriggerUrl -Method Post -Headers $Headers -ContentType "application/json" -Body $TestBotConfiguration
} catch {
    $body = ""
    if ($_.Exception.Response) {
        try {
            $stream = $_.Exception.Response.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($stream)
            $body = $reader.ReadToEnd()
        } catch {}
    }
    if (-not $body) { $body = $_.Exception.Message }
    Write-Host "ERROR: Trigger request failed (endpoint unreachable, timed out, or a non-2xx status, e.g. an invalid/expired token): $(Sanitize $body)"
    exit 1
}

$ExecutionId = $TriggerResponse.id
if ([string]::IsNullOrEmpty($ExecutionId)) {
    $msg = if ($TriggerResponse.message) { $TriggerResponse.message } else { ($TriggerResponse | ConvertTo-Json -Compress) }
    Write-Host "ERROR: Trigger response did not include an execution id: $(Sanitize $msg)"
    exit 1
}

Write-Host "Execution triggered. ID: $ExecutionId"
Write-Host "Polling every ${PollIntervalSeconds}s (timeout: ${PollTimeoutMinutes}m)..."

$StartTime = Get-Date
$PollCount = 0
$FinalStatus = "UNKNOWN"

while ($true) {
    $PollCount++
    $Elapsed = (Get-Date) - $StartTime

    if ($Elapsed.TotalSeconds -gt ($PollTimeoutMinutes * 60)) {
        Write-Host "ERROR: Polling timed out after $PollTimeoutMinutes minutes. Last known status: $FinalStatus"
        exit 1
    }

    $StatusUrl = "$TestOpsBaseUrl/rest/api/testops/execution/$ExecutionId/status?pollCount=$PollCount"

    $StatusResponse = $null
    $attempt = 0
    while ($attempt -lt 4 -and -not $StatusResponse) {
        try {
            $StatusResponse = Invoke-RestMethod -Uri $StatusUrl -Method Get
        } catch {
            $attempt++
            if ($attempt -ge 4) {
                Write-Host "ERROR: Status check failed after $([int]$Elapsed.TotalSeconds)s: $(Sanitize $_.Exception.Message)"
                exit 1
            }
            Start-Sleep -Seconds 5
        }
    }

    $FinalStatus = if ($StatusResponse.status) { $StatusResponse.status } else { "UNKNOWN" }
    Write-Host "   Status: $FinalStatus (elapsed: $([int]$Elapsed.TotalSeconds)s)"

    if ($FinalStatus -in @("ENQUEUED", "PROCESSING", "OPTIMIZATION_IN_PROGRESS")) {
        Start-Sleep -Seconds $PollIntervalSeconds
    } else {
        break
    }
}

Write-Host "Execution finished with status: $FinalStatus"

Write-Host ""
Write-Host "===== Fetch Detailed Results ====="

$DetailedUrl = "$TestOpsBaseUrl/rest/api/testops/execution/$ExecutionId/detailed-results"

try {
    $Data = Invoke-RestMethod -Uri $DetailedUrl -Method Get
} catch {
    Write-Host "ERROR: Execution finished with status $FinalStatus but fetching detailed results failed: $(Sanitize $_.Exception.Message)"
    exit 1
}

$Data | ConvertTo-Json -Depth 20 | Set-Content -Path "results/execution-result.json" -Encoding UTF8

$Summary = $Data.summary
$FailedScripts = if ($Summary -and $null -ne $Summary.failedScripts) { [int]$Summary.failedScripts } else { 0 }

Write-Host ""
Write-Host "===== Generate JUnit XML + Markdown Report ====="

$TotalScripts = if ($Summary.totalScripts) { $Summary.totalScripts } else { 0 }

$xmlWriter = New-Object System.Xml.XmlTextWriter("test-reports/junit.xml", [System.Text.Encoding]::UTF8)
$xmlWriter.Formatting = 'Indented'
$xmlWriter.WriteStartDocument()
$xmlWriter.WriteStartElement("testsuite")
$xmlWriter.WriteAttributeString("name", $(if ($Data.testBotName) { $Data.testBotName } else { "TestBot" }))
$xmlWriter.WriteAttributeString("tests", "$TotalScripts")
$xmlWriter.WriteAttributeString("failures", "$FailedScripts")
$xmlWriter.WriteAttributeString("errors", "0")

foreach ($ts in $Data.testSuiteResults) {
    $suiteName = if ($ts.testSuiteName) { $ts.testSuiteName } else { "Suite" }
    foreach ($script in $ts.testScriptResults) {
        $xmlWriter.WriteStartElement("testcase")
        $xmlWriter.WriteAttributeString("classname", $suiteName)
        $xmlWriter.WriteAttributeString("name", $(if ($script.testScriptName) { $script.testScriptName } else { "Test" }))
        if ($script.resultStatus -ne "PASSED") {
            $xmlWriter.WriteStartElement("failure")
            $xmlWriter.WriteString("$($script.resultStatus)")
            $xmlWriter.WriteEndElement()
        }
        $xmlWriter.WriteEndElement()
    }
}

$xmlWriter.WriteEndElement()
$xmlWriter.WriteEndDocument()
$xmlWriter.Flush()
$xmlWriter.Close()

$md = New-Object System.Collections.Generic.List[string]
$md.Add("# TestBot Execution Report")
$md.Add("")
$md.Add("**Execution ID:** $($Data.executionId)")
$md.Add("")
$md.Add("**Bot:** $($Data.testBotName)")
$md.Add("")
$md.Add("**Status:** $($Data.status)")
$md.Add("")
$md.Add("**Duration:** $($Summary.formattedDuration)")
$md.Add("")
$md.Add("## Summary")
$md.Add("")
$md.Add("| Metric | Value |")
$md.Add("|----------|----------|")
$md.Add("| Total Suites | $($Summary.totalSuites) |")
$md.Add("| Passed Suites | $($Summary.passedSuites) |")
$md.Add("| Failed Suites | $($Summary.failedSuites) |")
$md.Add("| Total Scripts | $($Summary.totalScripts) |")
$md.Add("| Passed Scripts | $($Summary.passedScripts) |")
$md.Add("| Failed Scripts | $($Summary.failedScripts) |")

foreach ($suite in $Data.testSuiteResults) {
    $md.Add("")
    $md.Add("## Suite: $(if ($suite.testSuiteName) { $suite.testSuiteName } else { 'Suite' })")
    $md.Add("")
    foreach ($script in $suite.testScriptResults) {
        $icon = if ($script.resultStatus -eq "PASSED") { "[PASS]" } else { "[FAIL]" }
        $md.Add("### $icon $(if ($script.testScriptName) { $script.testScriptName } else { 'Test' })")
        foreach ($iteration in $script.iterations) {
            $md.Add("")
            $md.Add("| Step | Status | Description |")
            $md.Add("|------|--------|-------------|")
            foreach ($step in $iteration.stepResults) {
                $stepStatus = $step.resultStatus
                $stepIcon = if ($stepStatus -eq "PASSED") { "[PASS]" } else { "[FAIL]" }
                $md.Add("| $($step.sequence) | $stepIcon $stepStatus | $($step.testStepName) |")
            }
        }
    }
}

($md -join "`n") | Set-Content -Path "results/report.md" -Encoding UTF8
Write-Host "Generated test-reports/junit.xml and results/report.md"

Write-Host ""
Write-Host "===== Generate Allure Report ====="

$AllureOutDir = "allure-results"
New-Item -ItemType Directory -Force -Path $AllureOutDir | Out-Null

function Allure-Status([string]$resultStatus) {
    if ($resultStatus -eq "PASSED") { return "passed" } else { return "failed" }
}

$NowMs = [long][double]::Parse((Get-Date -UFormat %s)) * 1000

foreach ($ts in $Data.testSuiteResults) {
    $suiteName = if ($ts.testSuiteName) { $ts.testSuiteName } else { "Suite" }
    foreach ($script in $ts.testScriptResults) {
        $scriptName = if ($script.testScriptName) { $script.testScriptName } else { "Test" }

        $stepsList = @()
        foreach ($iteration in $script.iterations) {
            foreach ($step in $iteration.stepResults) {
                $stepsList += @{
                    name   = "$($step.sequence): $($step.testStepName)"
                    status = Allure-Status $step.resultStatus
                    stage  = "finished"
                    start  = $NowMs
                    stop   = $NowMs
                }
            }
        }

        $resultUuid = [guid]::NewGuid().ToString()
        $result = @{
            uuid      = $resultUuid
            historyId = "${suiteName}::${scriptName}"
            name      = $scriptName
            status    = Allure-Status $script.resultStatus
            stage     = "finished"
            start     = $NowMs
            stop      = $NowMs
            labels    = @(
                @{ name = "suite"; value = $suiteName },
                @{ name = "framework"; value = "AutomationHQ TestBot" }
            )
            steps     = $stepsList
        }

        ($result | ConvertTo-Json -Depth 10 -Compress) | Set-Content -Path (Join-Path $AllureOutDir "$resultUuid-result.json") -Encoding UTF8
    }
}

Write-Host "Generated Allure results in $AllureOutDir"

# Jenkins agents are long-lived (unlike a fresh GitHub/GitLab runner each
# time), so the Allure CLI is cached under the agent user's profile instead of
# re-downloading it on every single build. Java is guaranteed present
# already — Jenkins itself is a Java application, so this adds no new
# prerequisite beyond what's already required to run Jenkins at all.
$AllureVersion = "2.46.1"
$AllureHome = Join-Path $env:USERPROFILE ".testbot-allure\allure-$AllureVersion"
$AllureBat = Join-Path $AllureHome "bin\allure.bat"

if (-not (Test-Path $AllureBat)) {
    Write-Host "Downloading Allure CLI $AllureVersion (first run only, cached under $env:USERPROFILE\.testbot-allure)..."
    $zipPath = Join-Path $env:TEMP "testbot-allure.zip"
    Invoke-WebRequest -Uri "https://github.com/allure-framework/allure2/releases/download/$AllureVersion/allure-$AllureVersion.zip" -OutFile $zipPath
    New-Item -ItemType Directory -Force -Path (Split-Path $AllureHome -Parent) | Out-Null
    Expand-Archive -Path $zipPath -DestinationPath (Split-Path $AllureHome -Parent) -Force
    Remove-Item $zipPath -Force
}

& $AllureBat generate allure-results --clean -o allure-report
Write-Host "Generated allure-report/index.html"

Write-Host ""
Write-Host "===== TestBot Run Summary ====="
Write-Host ""
Write-Host "Execution ID : $ExecutionId"
Write-Host "Status       : $FinalStatus"
Write-Host ""
Get-Content "results/report.md" | Write-Host
Write-Host ""
Write-Host "================================"

if ($FinalStatus -eq "FAILED" -or $FailedScripts -gt 0) {
    Write-Host ""
    Write-Host "TestBot run finished with failures ($FailedScripts failed script(s))."
    exit 1
}

exit 0
