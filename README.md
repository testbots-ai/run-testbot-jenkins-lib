# Run TestBot — Jenkins Shared Library

Run AutomationHQ TestBot executions from Jenkins and see pass/fail results directly in your pipeline.

Already have Jenkins running? Skip to **[Step 1](#1-add-this-to-your-jenkinsfile)**. Otherwise, start with installing it below.

---

## 0. Install Jenkins

Jenkins is a Java application — no Docker required, though Docker is also an option if you prefer it. Pick your OS:

### macOS

**Requires**: [Homebrew](https://brew.sh) and Java 17+ (check with `java -version`; install via `brew install openjdk@21` if missing).

1. Install Jenkins:
   ```bash
   brew install jenkins-lts
   ```
2. Start it (runs in the background, persists across reboots):
   ```bash
   brew services start jenkins-lts
   ```
   Confirm it's actually running:
   ```bash
   brew services list
   ```
   You should see `jenkins-lts` with status `started`. It usually takes 15–30 seconds after this command before the web page is reachable — if `http://localhost:8080` doesn't load right away, wait a bit and refresh.

   (Full stop/start/restart commands are also collected together in **[Step 7](#7-stop-jenkins-when-youre-done)** at the bottom of this doc, for when you're done using Jenkins.)
3. Get the unlock key:
   ```bash
   cat ~/.jenkins/secrets/initialAdminPassword
   ```
   Copy this — you'll paste it into the browser in the next step.
4. Open `http://localhost:8080` in your browser and continue with **"Complete the Setup Wizard"** below.

**Alternative (Docker):**
```bash
docker run -d --name jenkins -p 8080:8080 -p 50000:50000 -v jenkins_home:/var/jenkins_home jenkins/jenkins:lts-jdk17
docker exec jenkins cat /var/jenkins_home/secrets/initialAdminPassword
```

### Windows

1. Go to [jenkins.io/download](https://www.jenkins.io/download/) → **Windows** → download the `.msi` installer (LTS version).
2. Run the downloaded `.msi` file.
3. Follow the installer prompts:
   - Choose an install directory (default is fine)
   - It will prompt you to select a **Java (JVM) path** — if you don't have Java 17+ installed, install it first from [adoptium.net](https://adoptium.net) before continuing
   - Choose the port (default `8080` is fine, unless something else is already using it)
4. The installer sets Jenkins up as a **Windows Service** that starts automatically — once installation finishes, it opens `http://localhost:8080` in your browser automatically.
5. If it doesn't open automatically, open `http://localhost:8080` yourself.
6. The unlock key is shown directly on that first screen, along with the exact file path it was saved to (typically `C:\Program Files\Jenkins\secrets\initialAdminPassword`) — open that file in Notepad to copy it, or copy it straight from the Jenkins page if shown there.
7. Continue with **"Complete the Setup Wizard"** below.

The Windows installer starts Jenkins for you automatically — you don't need to start it manually.

If you'd rather use the command line instead of the Services app, open **PowerShell as Administrator** (right-click Start → **Windows PowerShell (Admin)** or **Terminal (Admin)**) and run:

```powershell
Start-Service Jenkins
```

Confirm it's running:

```powershell
Get-Service Jenkins
```

You should see `Status: Running`.

(Full stop/start/restart commands — both GUI and command-line — are also collected together in **[Step 7](#7-stop-jenkins-when-youre-done)** at the bottom of this doc, for when you're done using Jenkins.)

### Complete the Setup Wizard (same on both platforms)

1. Paste the unlock key → **Continue**.
2. Click **Install suggested plugins** — wait for it to finish (this installs Pipeline, Git, and Credentials Binding automatically).
3. Create your admin username, password, full name, and email → **Save and Continue**.
4. Confirm the Jenkins URL (default is fine) → **Save and Finish** → **Start using Jenkins**.
5. One plugin isn't in the "suggested" bundle and is required — install it now:
   ```text
   Manage Jenkins → Plugins → Available plugins → search "JUnit" → check it → Install
   ```

Jenkins is now installed and ready. Continue to Step 1 below.

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

**Exact name and location:** the file must be named exactly `Jenkinsfile` — capital **J**, no file extension (not `Jenkinsfile.txt` or `Jenkinsfile.groovy`) — and it must sit at the **root** of your repository, alongside your top-level folders like `src/`:

```text
your-repo/
├── Jenkinsfile          ← this file, at the root
├── src/
└── ...
```

**How to actually create it, step by step:**

1. Open a terminal (or your code editor) in your project's repo folder.
2. Create the file at the repo root:
   ```bash
   # macOS/Linux
   touch Jenkinsfile
   ```
   ```powershell
   # Windows (PowerShell)
   New-Item Jenkinsfile
   ```
3. Open `Jenkinsfile` in any text editor (VS Code, Notepad, `nano`, etc.) and paste in the full pipeline script shown above exactly as-is.
4. Save the file.
5. Commit and push it to your repo, the same way you would any other file:
   ```bash
   git add Jenkinsfile
   git commit -m "Add Jenkinsfile for TestBot"
   git push
   ```

Jenkins doesn't need anything installed or configured in your repo beyond this one file — no `.jenkins/` folder, no extra config. Step 5 below covers how Jenkins actually finds and runs this file.

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

If you followed **Step 0** above, this is already done. Otherwise, confirm your Jenkins has these four plugins:

* **Pipeline** (`workflow-aggregator`) — part of the standard "suggested plugins" set
* **Git** — part of the standard "suggested plugins" set
* **Credentials Binding** — part of the standard "suggested plugins" set
* **JUnit** — **not** included in "suggested plugins", install manually

Install any missing ones via `Manage Jenkins → Plugins → Available plugins`.

---

## 5. Create the Jenkins Job and Run It

Once your `Jenkinsfile` is committed to your repo (Step 1), you need a Jenkins job that knows to run it. Two ways to do that:

### Option A: Pipeline job pointing at your repo (recommended)

This is the standard, maintainable setup — Jenkins pulls the `Jenkinsfile` straight from your repo every time, so it stays version-controlled alongside your code.

1. On the Jenkins home page (`http://localhost:8080`), click **New Item** in the left sidebar.
2. **Enter an item name**: this is just a label you'll see in the Jenkins dashboard — it doesn't need to match your repo name or anything else. A descriptive name like `run-testbot` is enough.
3. Below the name field, select **Pipeline** from the list of project types, then click **OK** at the bottom.
4. You're now on the job's configuration page. Scroll down to the **Pipeline** section at the very bottom.
5. **Definition**: change the dropdown from "Pipeline script" to **Pipeline script from SCM**.
6. New fields appear — **SCM**: select **Git** from the dropdown.
7. **Repository URL**: paste your repo's git clone URL (e.g. `https://github.com/your-org/your-repo.git`) — this is the same repo you pushed the `Jenkinsfile` to in Step 1.
8. **Credentials**: only needed if your repo is **private** — click **Add** → **Jenkins**, choose **Username with password** (or a personal access token as the password), fill in your Git host credentials, save, then select them from the dropdown. Skip this entirely for a public repo.
9. **Branch Specifier**: leave as `*/main`, or change to match whatever branch your `Jenkinsfile` actually lives on (e.g. `*/master`, `*/develop`).
10. **Script Path**: leave this as `Jenkinsfile` — it's the default value and matches the filename from Step 1 exactly. Only change this if you named your file differently or put it in a subfolder (not recommended).
11. Scroll to the bottom and click **Save**.

You're taken to the job's page — this is where you'll trigger runs and view results (see Step 6 below).

### Option B: Paste the script directly into Jenkins (quick test only)

Useful for a one-off test without needing a `Jenkinsfile` committed anywhere yet — **not recommended for ongoing use**, since the pipeline definition then lives only in Jenkins, not in your version-controlled repo.

1. Jenkins home page → **New Item**
2. Enter a name, select **Pipeline**, click **OK**
3. Scroll to the **Pipeline** section
4. **Definition**: leave as **Pipeline script**
5. Paste the full script from Step 1 directly into the **Script** text box
6. Click **Save**

### Run it

1. Go to the job's page (Jenkins home page → click the job name, e.g. `run-testbot`).
2. In the left sidebar, click **Build Now**.
3. A new build number (e.g. `#1`) appears under **Build History** on the left — click it to open that specific run.

---

## 6. Where to See Results

Once a build finishes (or while it's still running), open that build number from **Build History**, then:

* **Console Output** (left sidebar on the build page) — the full live/readable log, including the final pass/fail report printed at the end of the run. This is the first place to look, especially while a build is still in progress.
* **Test Result Trend / Test Result** (left sidebar on the build page, appears once the `junit` step has run) — a pass/fail graph and a breakdown per test script.
* **Artifacts** (left sidebar on the build page, or a section directly on the build's summary page) — downloadable result files:
  * `test-reports/junit.xml` — the raw JUnit report
  * `results/execution-result.json` — the raw TestBot API result
  * `results/report.md` — a human-readable Markdown summary

On the job's main page, each build number in **Build History** is shown with a colored ball/icon: **blue** (or green, depending on your Jenkins theme) means everything passed, **red** means something failed. You can tell pass/fail at a glance without opening the build.

---

## 7. Stop Jenkins When You're Done

Jenkins keeps running in the background (using CPU/memory and holding port `8080`) until you explicitly stop it. You don't need to stop it between runs — only when you're fully done for the session/day.

### macOS

* If you installed via **Homebrew**:
  ```bash
  brew services stop jenkins-lts
  ```
  Verify it stopped:
  ```bash
  brew services list
  ```
  `jenkins-lts` should now show status `none` or `stopped`.

  To start it again later: `brew services start jenkins-lts`. To restart without stopping manually first: `brew services restart jenkins-lts`.

* If you installed via **Docker**:
  ```bash
  docker stop jenkins
  ```
  To start it again later (reuses the same data, since it's stored in the `jenkins_home` volume): `docker start jenkins`.

### Windows

Jenkins runs as a **Windows Service**, so it keeps running in the background even after you log out — stop it explicitly. You can use either the Services app (GUI) or PowerShell (command line) — same effect either way.

**Option A: Services app (GUI)**

1. Open the **Services** app (press **Win**, type `Services`, press Enter).
2. Scroll down and find **Jenkins** in the list.
3. Right-click it → **Stop**.

To start it again later: right-click **Jenkins** in the same list → **Start**. To make it stop starting automatically on every reboot: right-click → **Properties** → set **Startup type** to **Manual** → **OK**.

**Option B: PowerShell (command line)**

Open **PowerShell as Administrator** (right-click Start → **Windows PowerShell (Admin)** or **Terminal (Admin)**), same as in Step 0:

```powershell
Stop-Service Jenkins
```

Verify it stopped:

```powershell
Get-Service Jenkins
```

`Status` should now show `Stopped`.

To start it again later:

```powershell
Start-Service Jenkins
```

To restart it (stop + start in one command):

```powershell
Restart-Service Jenkins
```

### How to confirm it's actually stopped

Open `http://localhost:8080` in your browser — if Jenkins is stopped, the page will fail to load ("can't be reached" / connection refused) instead of showing the dashboard.

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
