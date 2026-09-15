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

    withEnv([
        "JWT_TOKEN=${env.TESTBOT_JWT_TOKEN}",
        "TEST_BOT_CONFIGURATION=${env.TEST_BOT_CONFIGURATION}",
        "POLL_INTERVAL_SECONDS=${pollIntervalSeconds}",
        "POLL_TIMEOUT_MINUTES=${pollTimeoutMinutes}"
    ]) {
        if (isUnix()) {
            def scriptContent = libraryResource('org/testbotsai/run-testbot/run-testbot.sh')
            writeFile file: 'run-testbot.sh', text: scriptContent
            sh 'chmod +x run-testbot.sh'
            sh './run-testbot.sh'
        } else {
            // Windows agents run a native PowerShell equivalent instead of the
            // bash script — Windows has no bash/curl/jq out of the box, and
            // requiring customers to install and PATH-configure Git Bash
            // extras just for this is unreliable. PowerShell (and the
            // `powershell` pipeline step) ships with every supported Windows
            // version, so this has no extra dependencies at all.
            def scriptContent = libraryResource('org/testbotsai/run-testbot/run-testbot.ps1')
            writeFile file: 'run-testbot.ps1', text: scriptContent
            powershell './run-testbot.ps1'
        }
    }
}
