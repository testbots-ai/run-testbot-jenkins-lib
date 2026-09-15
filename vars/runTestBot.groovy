// runTestBot() — Jenkins Shared Library step.
//
// Triggers an AutomationHQ TestBot execution, polls until it completes, and
// publishes JUnit + Markdown results in the current build workspace.
//
// Requires two environment variables to already be set by the caller's own
// Jenkinsfile (bound from Jenkins Credentials, e.g. via an `environment {}`
// block using `credentials(...)`):
//   TESTBOT_JWT_TOKEN      — JWT token for the TestBot executor API
//   TEST_BOT_CONFIGURATION — stringified JSON TestBot configuration
//
// Optional named arguments (both have defaults, matching the GitLab/Bitbucket
// versions of this integration):
//   pollIntervalSeconds — how often (in seconds) to poll for status. Default: '5'
//   pollTimeoutMinutes  — maximum time (in minutes) to wait. Default: '345'
//
// Example:
//   runTestBot()
//   runTestBot(pollIntervalSeconds: '10', pollTimeoutMinutes: '120')

def call(Map config = [:]) {
    def pollIntervalSeconds = config.pollIntervalSeconds ?: '5'
    def pollTimeoutMinutes = config.pollTimeoutMinutes ?: '345'

    if (!env.TESTBOT_JWT_TOKEN) {
        error "runTestBot: TESTBOT_JWT_TOKEN is not set. Bind it in your Jenkinsfile, e.g.:\n" +
              "  environment {\n" +
              "    TESTBOT_JWT_TOKEN = credentials('testbot-jwt-token')\n" +
              "  }"
    }
    if (!env.TEST_BOT_CONFIGURATION) {
        error "runTestBot: TEST_BOT_CONFIGURATION is not set. Bind it in your Jenkinsfile, e.g.:\n" +
              "  environment {\n" +
              "    TEST_BOT_CONFIGURATION = credentials('test-bot-configuration')\n" +
              "  }"
    }

    def scriptContent = libraryResource('org/testbotsai/run-testbot/run-testbot.sh')
    writeFile file: 'run-testbot.sh', text: scriptContent

    withEnv([
        "JWT_TOKEN=${env.TESTBOT_JWT_TOKEN}",
        "TEST_BOT_CONFIGURATION=${env.TEST_BOT_CONFIGURATION}",
        "POLL_INTERVAL_SECONDS=${pollIntervalSeconds}",
        "POLL_TIMEOUT_MINUTES=${pollTimeoutMinutes}"
    ]) {
        if (isUnix()) {
            sh 'chmod +x run-testbot.sh'
            sh './run-testbot.sh'
        } else {
            // Windows agents have no native "sh" — the script is bash, so it's
            // run via Git for Windows' bundled bash.exe instead. Not always on
            // PATH for the Jenkins Windows Service (services cache their PATH
            // at startup, so it can be stale even after Git is installed), so
            // this tries PATH first and falls back to the two standard Git
            // for Windows install locations before giving up.
            bat '''
                where bash >nul 2>nul
                if %ERRORLEVEL% EQU 0 (
                    bash run-testbot.sh
                ) else if exist "C:\\Program Files\\Git\\bin\\bash.exe" (
                    "C:\\Program Files\\Git\\bin\\bash.exe" run-testbot.sh
                ) else if exist "C:\\Program Files (x86)\\Git\\bin\\bash.exe" (
                    "C:\\Program Files (x86)\\Git\\bin\\bash.exe" run-testbot.sh
                ) else (
                    echo ERROR: bash.exe not found. Install Git for Windows ^(includes Git Bash^), or add its "bin" folder to PATH and restart the Jenkins service.
                    exit /b 1
                )
            '''
        }
    }
}
