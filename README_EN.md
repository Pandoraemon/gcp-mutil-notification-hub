# One-Click GCP Alerts to Feishu/Lark, WeCom & DingTalk

English | [简体中文](README.md)

Push Google Cloud alerts to IM group bots as cards:

- **Cloud Monitoring** metric / log alerts
- **Personalized Service Health** (Google Cloud service incidents)
- **Cloud Billing** budget alerts (optional)
- **Security Command Center** findings (optional)

Supports **Feishu/Lark, WeCom (WeChat Work) and DingTalk** — pick one platform per deployment. About 10 minutes to deploy, fully serverless, typically under USD 1/month at low volume.

---

## One-click deploy

[![Open in Cloud Shell](https://gstatic.com/cloudssh/images/open-btn.svg)](https://console.cloud.google.com/cloudshell/open?cloudshell_git_repo=https://github.com/Pandoraemon/gcp-mutil-notification-hub&cloudshell_tutorial=docs/cloudshell-tutorial.md)

1. **Click the button above**: Cloud Shell opens in your browser, clones this project and shows a step-by-step tutorial (nothing to install locally).
2. **Run in the Cloud Shell terminal**:

   ```bash
   ./deploy-gcloud.sh
   ```

3. **Answer a few prompts** (see "What the script asks" below). At the end the script posts a **🟢 connectivity self-test** card to your group — once you see it, you are done.

> Without the button, run this in any terminal where `gcloud` is logged in:
> `git clone https://github.com/Pandoraemon/gcp-mutil-notification-hub.git && cd gcp-mutil-notification-hub && ./deploy-gcloud.sh`

> The interactive prompts and script output are in Chinese; the table below translates them.

---

## Before you start (2 things)

| What | Notes |
|---|---|
| **A GCP project and permissions** | The deploying account needs `Editor` + `Project IAM Admin` (`roles/editor` + `roles/resourcemanager.projectIamAdmin`). If Editor is not allowed, grant the minimal role set in [User guide · Required IAM permissions](docs/full-guide.md#所需-iam-权限) (Chinese). |
| **A group bot webhook** | Add a bot to the target group and copy its webhook URL — see [Bot setup](docs/bot-setup.md) (Chinese). For Feishu / DingTalk with signing enabled you also need the signing secret. |

## What the script asks

| Prompt | Answer |
|---|---|
| Select a project | Pick a number (applies to this run only; your `gcloud` default project is not changed) |
| Select a channel | `1` Feishu/Lark, `2` WeCom, `3` DingTalk |
| Webhook URL | Paste the bot webhook |
| Signing secret | Feishu: the secret if signature verification is on, **otherwise `NONE`**; DingTalk: the `SEC...` secret if signing is on, **otherwise `NONE`**; not asked for WeCom |
| Google Cloud service incident alerts | Recommended `Y` (default on) |
| Recommended default alert pack | Choose `y` for ready-made CPU / disk / quota / load balancer / GKE / Cloud SQL / high-risk IAM / GCE maintenance alerts |
| SCC / Billing budget | Only if needed (Billing needs billing-account permission, SCC needs organization permission) |
| Ops notification email | An email to be notified if IM delivery itself breaks; may be left empty |

> If DingTalk uses only the "custom keyword" security setting, the keyword must be **`GCP告警`**.

How the run ends:

- **✅ 部署完成 (done)**: everything is in place and the self-test card should be in your group.
- **⚠️ 本次部署【不完整】 (incomplete)**: the core pipeline works, but some steps were skipped for missing permissions. Grant them with the commands printed on screen and **re-run `./deploy-gcloud.sh`** (safe to re-run; nothing is created twice).
- **❌ Failed**: follow the on-screen hints or the [troubleshooting guide](docs/troubleshooting.md) (Chinese).

---

## After deployment

**Route more alerts**: in Cloud Monitoring, create or edit any alert policy and choose the notification channel **`Feishu Alert Hub`** (legacy name — also used for WeCom / DingTalk). Its alerts will then be pushed to your group.

**Common operations** (run in the project directory; all support `--help`; without `--project` you will be asked to pick one):

| Task | Command |
|---|---|
| Change configuration (group, platform, severity, data sources…) | `./scripts/configure.sh` |
| Emergency stop (drop messages) | `./scripts/emergency-disable.sh` |
| Pause (queue messages, deliver after resume) | `./scripts/emergency-disable.sh --pause` |
| Resume | `./scripts/emergency-enable.sh` |
| Re-deliver failed messages (dead-letter queue) | `./scripts/replay-dlq.sh` |
| Uninstall | `./scripts/teardown-gcloud.sh` (add `--delete-secrets` to also delete bot credentials) |

> When you reopen Cloud Shell later, the project lives in `~/cloudshell_open/gcp-mutil-notification-hub`.

**Multiple projects**: to aggregate alerts from several projects (or a whole folder / organization) into one group, see [Multi-project Hub mode](docs/multi-project-hub.md) (Chinese).

---

## FAQ

**Deployed successfully but no cards arrive?**
Usually a wrong signing secret (Feishu signing off but `NONE` not entered, or a wrong DingTalk secret), or a permission step that was skipped. Run the first three commands in the [troubleshooting guide](docs/troubleshooting.md).

**Every alert shows HIGH?**
Policies without a severity are treated as HIGH (better to over-report than miss). Set Severity on the alert policy.

**Only forward important alerts?**
`./scripts/configure.sh --section=filter` sets the minimum severity (default `MEDIUM`); `--section=source-filter` sets it per source.

**Will it flood the group or hit platform rate limits?**
Built-in rate limiting: at most 80 cards/minute for Feishu and 16/minute for WeCom / DingTalk (80% of each platform's limit). During alert storms messages queue up instead of being lost.

**Send to Feishu and DingTalk at the same time?**
One platform per deployment. Deploy to separate projects if you need both.

**Cost?**
Small usage of Cloud Functions, Pub/Sub and Cloud Logging — typically under USD 1/month for a few hundred alerts. Billing budgets themselves are free.

---

## Documentation (Chinese)

- [Bot setup](docs/bot-setup.md) — create Feishu / WeCom / DingTalk bots and verify webhooks
- [User guide](docs/full-guide.md) — permissions, configuration changes, operations, settings, FAQ
- [Multi-project Hub mode](docs/multi-project-hub.md)
- [Troubleshooting](docs/troubleshooting.md) — no cards, error codes, diagnostic commands
