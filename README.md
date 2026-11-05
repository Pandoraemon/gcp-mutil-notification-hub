# GCP 告警一键转发到飞书 / 企业微信 / 钉钉

[English](README_EN.md) | 简体中文

把 Google Cloud 的告警统一推送到 IM 群机器人卡片：

- **Cloud Monitoring** 指标 / 日志告警
- **Personalized Service Health**（Google Cloud 服务故障事件）
- **Cloud Billing** 预算超支（可选）
- **Security Command Center** 安全发现（可选）

支持 **飞书/Lark、企业微信、钉钉**，每次部署选一个平台。约 10 分钟完成，Serverless 无常驻资源，小流量下月成本通常不到 1 美元。

---

## 一键部署

[![Open in Cloud Shell](https://gstatic.com/cloudssh/images/open-btn.svg)](https://console.cloud.google.com/cloudshell/open?cloudshell_git_repo=https://github.com/Pandoraemon/gcp-mutil-notification-hub&cloudshell_tutorial=docs/cloudshell-tutorial.md)

1. **点击上方按钮**：浏览器打开 Cloud Shell，自动下载本项目并显示分步教程（无需在本机安装任何东西）。
2. **在 Cloud Shell 终端运行**：

   ```bash
   ./deploy-gcloud.sh
   ```

3. **按提示回答几个问题**（见下方「部署时会问什么」）。结束时脚本会往群里发一张 **🟢 连通性自检成功** 卡片，收到即部署完成。

> 没有按钮可用时，在任意已登录 `gcloud` 的终端执行：
> `git clone https://github.com/Pandoraemon/gcp-mutil-notification-hub.git && cd gcp-mutil-notification-hub && ./deploy-gcloud.sh`

---

## 部署前准备（2 样东西）

| 需要什么 | 说明 |
|---|---|
| **一个 GCP 项目及权限** | 部署账号需要 `Editor` + `Project IAM Admin`（`roles/editor` + `roles/resourcemanager.projectIamAdmin`）。不能给 Editor 时，按 [使用手册 · 所需 IAM 权限](docs/full-guide.md#所需-iam-权限) 授予最小角色集。 |
| **一个群机器人 Webhook** | 在目标群里添加机器人并复制 Webhook 地址，分步截图教程见 [创建群机器人](docs/bot-setup.md)。飞书 / 钉钉如开启了签名（加签），还需要那串密钥。 |

## 部署时会问什么

| 问题 | 怎么答 |
|---|---|
| 选择项目 | 从列表中选编号（只在本次生效，不会改你的 `gcloud` 默认项目） |
| 选择通知渠道 | `1` 飞书/Lark、`2` 企业微信、`3` 钉钉 |
| Webhook URL | 粘贴机器人 Webhook |
| 签名密钥 | 飞书：开了签名校验填密钥，**没开填 `NONE`**；钉钉：加签填 `SEC` 开头的密钥，**没开填 `NONE`**；企业微信不问 |
| Google Cloud 服务故障告警 | 建议 `Y`（默认开启） |
| 推荐默认告警包 | 想要开箱即用的 CPU / 磁盘 / 配额 / 负载均衡 / GKE / Cloud SQL / 高危 IAM / GCE 维护等告警就选 `y` |
| SCC / Billing 预算 | 需要再开（Billing 需要结算账号权限，SCC 需要组织权限） |
| 运维通知邮箱 | 填一个邮箱：万一 IM 推送本身出故障，会发邮件提醒；留空也可以 |

> 钉钉如果只用「自定义关键词」安全设置，关键词必须设为 **`GCP告警`**。

部署结束时的提示：

- **✅ 部署完成**：一切就绪，群里应已收到自检卡片。
- **⚠️ 本次部署【不完整】**：核心链路已建好，但有步骤因权限不足被跳过；按屏幕上给出的补救命令补齐权限后**重新运行 `./deploy-gcloud.sh`** 即可（可重复执行，不会重复创建）。
- **❌ 失败**：按屏幕提示或 [排查指南](docs/troubleshooting.md) 处理。

---

## 部署之后

**接入更多告警**：在 Cloud Monitoring 新建或编辑任意告警策略，通知渠道选择 **`Feishu Alert Hub`**（历史名称，企业微信 / 钉钉同样用它），该策略的告警就会推送到群里。

**常用操作**（在项目目录下运行，都支持 `--help`；不带 `--project` 时会让你选项目）：

| 想做什么 | 命令 |
|---|---|
| 修改配置（换群 / 换平台 / 告警级别 / 开关数据源等） | `./scripts/configure.sh` |
| 紧急停止推送（直接丢弃） | `./scripts/emergency-disable.sh` |
| 暂停推送（消息先攒着，恢复后补发） | `./scripts/emergency-disable.sh --pause` |
| 恢复推送 | `./scripts/emergency-enable.sh` |
| 补发推送失败的消息（死信队列） | `./scripts/replay-dlq.sh` |
| 卸载 | `./scripts/teardown-gcloud.sh`（加 `--delete-secrets` 同时删除机器人凭据） |

> 再次打开 Cloud Shell 时，项目目录在 `~/cloudshell_open/gcp-mutil-notification-hub`。

**多项目汇聚**：想把多个项目（或整个文件夹 / 组织）的告警汇总到一个群，见 [多项目汇聚（Hub 模式）](docs/multi-project-hub.md)。

---

## 常见问题

**部署成功了，但群里没有卡片？**
最常见两个原因：签名密钥填错（飞书没开签名却没填 `NONE`、钉钉加签密钥不对），或部署时有权限步骤被跳过。按 [排查指南](docs/troubleshooting.md) 开头的三条命令检查。

**告警级别全是 HIGH？**
告警策略里没设置严重级别时按 HIGH 处理（宁可多报不漏报）。在告警策略中设置 Severity 即可。

**可以只推送重要告警吗？**
可以：`./scripts/configure.sh --section=filter` 调整最低级别（默认 `MEDIUM`）；也可以按来源分别设置（`--section=source-filter`）。

**会不会刷屏 / 被平台限流？**
内置限速：飞书每分钟最多 80 张，企业微信 / 钉钉每分钟最多 16 张（平台上限的 80%）。告警风暴时消息会排队而不是丢失。

**能同时发到飞书和钉钉吗？**
一次部署只对接一个平台。确有需要可部署到不同项目。

**费用大概多少？**
主要是 Cloud Functions、Pub/Sub、Cloud Logging 的少量用量，每月几百条告警量级通常在 1 美元以内；Billing 预算告警本身不额外收费。

---

## 文档

- [创建群机器人](docs/bot-setup.md) —— 飞书 / 企业微信 / 钉钉机器人创建与 Webhook 验证
- [使用手册](docs/full-guide.md) —— 权限清单、修改配置、日常运维、配置项、FAQ
- [多项目汇聚（Hub 模式）](docs/multi-project-hub.md)
- [排查指南](docs/troubleshooting.md) —— 收不到卡片、错误码速查、诊断命令
