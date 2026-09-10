# Run TestBot — Jenkins Shared Library

Run AutomationHQ TestBot executions from Jenkins and see pass/fail results directly in your pipeline.

---

## 1. Add This to Your `Jenkinsfile`

```groovy
library identifier: 'run-testbot@1.0.0', retriever: modernSCM(
    [$class: 'GitSCMSource', remote: 'https://github.com/testbots-ai/run-testbot-jenkins-lib.git']
)

pipeline {
    agent any
    environment {
        TESTBOT_JWT_TOKEN = credentials('testbot-jwt-token')
        TEST_BOT_CONFIGURATION = credentials('test-bot-configuration')
    }
    stages {
        stage('Run TestBot') {
            steps {
                runTestBot()
            }
        }
    }
    post {
        always {
            junit allowEmptyResults: true, testResults: 'test-reports/*.xml'
            archiveArtifacts allowEmptyArchive: true, artifacts: 'test-reports/**, results/**'
        }
    }
}
```

That's the whole file. No extra setup files, no folder structure needed in your repo — the `library` line pulls everything in directly, no Jenkins-admin pre-configuration required.

**Where to put it:** save this as a file named exactly `Jenkinsfile` (no file extension) at the **root** of your repository:

```text
your-repo/
├── Jenkinsfile          ← this file, at the root
├── src/
└── ...
```

See Step 5 below for how Jenkins actually picks this file up and runs it.

---

## 2. Add Your TestBot Config as a Jenkins Credential

```text
Manage Jenkins → Credentials → System → Global credentials → Add Credentials
```

| Field | Value |
| --- | --- |
| Kind | Secret text |
| Secret | your TestBot configuration, as one line of JSON |
| ID | `test-bot-configuration` |


---

## 3. Add Your JWT Token as a Jenkins Credential

```text
Manage Jenkins → Credentials → System → Global credentials → Add Credentials
```

| Field | Value |
| --- | --- |
| Kind | Secret text |
| Secret | your JWT token |
| ID | `testbot-jwt-token` |

**Important:** the credential IDs must be exactly `test-bot-configuration` and `testbot-jwt-token` — the Jenkinsfile above references them by these exact names.

---

## 4. Confirm Required Plugins Are Installed

Most Jenkins instances already have these (they're part of the standard "suggested plugins" set installed by default):

* **Pipeline** (`workflow-aggregator`)
* **Git**
* **Credentials Binding**
* **JUnit**

If your Jenkins is missing any of these, install them via `Manage Jenkins → Plugins`.

---

## 5. Create the Jenkins Job and Run It

Once your `Jenkinsfile` is committed to your repo (Step 1), you need a Jenkins job that knows to run it. Two ways to do that:

### Option A: Pipeline job pointing at your repo (recommended)

This is the standard, maintainable setup — Jenkins pulls the `Jenkinsfile` straight from your repo every time, so it stays version-controlled alongside your code.

1. Jenkins home page → **New Item**
2. Enter a name (e.g. `run-testbot`), select **Pipeline**, click **OK**
3. Scroll to the **Pipeline** section at the bottom
4. **Definition**: change the dropdown to **Pipeline script from SCM**
5. **SCM**: select **Git**
6. **Repository URL**: your repo's git URL (e.g. `https://github.com/your-org/your-repo.git`)
7. **Credentials**: add/select credentials here if your repo is private (not needed for a public repo)
8. **Branch Specifier**: usually `*/main` (or whatever branch your `Jenkinsfile` is on)
9. **Script Path**: leave as `Jenkinsfile` (this is the default — matches the filename from Step 1)
10. Click **Save**

### Option B: Paste the script directly into Jenkins (quick test only)

Useful for a one-off test without needing a `Jenkinsfile` committed anywhere yet — **not recommended for ongoing use**, since the pipeline definition then lives only in Jenkins, not in your version-controlled repo.

1. Jenkins home page → **New Item**
2. Enter a name, select **Pipeline**, click **OK**
3. Scroll to the **Pipeline** section
4. **Definition**: leave as **Pipeline script**
5. Paste the full script from Step 1 directly into the **Script** text box
6. Click **Save**

### Run it

```text
Your Job → Build Now
```

---

## Where to See Results

* **Console Output** — full readable pass/fail report, printed at the end of the run
* **Test Result Trend** — pass/fail graph and per-script results, on the job page (from the `junit` step)
* **Artifacts** — downloadable result files (`test-reports/junit.xml`, `results/execution-result.json`, `results/report.md`), on the build page

The build shows **blue/green** if everything passed, **red** if anything failed.

---

## Keeping Up to Date

This is pinned to a specific version (`run-testbot@1.0.0`), not a branch — so your pipeline never changes behavior unexpectedly. Whenever a new version is released, that's the **only line you need to change** — bump `1.0.0` to the new version (e.g. `1.0.1`) in your Jenkinsfile. Nothing else needs to change.

---

## Troubleshooting

| Problem | Fix |
| --- | --- |
| `runTestBot: TESTBOT_JWT_TOKEN is not set` | Confirm the `environment {}` block in your Jenkinsfile matches the example above, and the credential ID is exactly `testbot-jwt-token` |
| `runTestBot: TEST_BOT_CONFIGURATION is not set` | Same as above, but for the `test-bot-configuration` credential |
| `test_bot_configuration input is not valid JSON` (from the script output) | Make sure the credential's secret value is valid JSON, all on one line |
| `No such DSL method 'junit'` or `'archiveArtifacts'` | The required plugin is missing — see Step 4 |
| Build times out | Raise `POLL_TIMEOUT_MINUTES` by passing it to the step: `runTestBot(pollTimeoutMinutes: '120')` |

---

## Support

For any issues, contact your TestBots administrator or support team.
