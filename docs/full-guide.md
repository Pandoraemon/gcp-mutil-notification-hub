# 使用手册

[← 返回 README](../README.md)

本手册是 [README](../README.md) 一键部署之外的详细说明：权限清单、部署选项、修改配置、日常运维与配置项。
还没部署的话，先按 README 点「Open in Cloud Shell」并运行 `./deploy-gcloud.sh`。

- [部署前准备](#部署前准备)
- [部署选项](#部署选项)
- [修改配置（configure.sh）](#修改配置configuresh)
- [日常运维](#日常运维)
- [配置项](#配置项)
- [FAQ](#faq)
- [已知限制（v1）](#已知限制v1)

---

## 部署前准备

- 一个 GCP 项目，部署账号具备 `roles/editor` + `roles/resourcemanager.projectIamAdmin`，或下面列出的最小角色集
- 所选平台的一个群机器人 Webhook URL，创建方法见 [创建群机器人](bot-setup.md)
- 在 Cloud Shell 中运行无需安装任何东西；在本机运行需已安装并登录 `gcloud`

### 所需 IAM 权限

`roles/editor` 能跑通核心部署，但**不含 `resourcemanager.projects.setIamPolicy`** ——
脚本要给函数 SA 和各服务代理授权，所以 editor 也必须额外配 `projectIamAdmin`。
不能发 editor 的环境，按下面三张表授予；它们分属**三个不同的授权层级**，
要用三条不同的命令，混在一层是这类配置最常见的失败方式。

**① 项目级（核心部署必需）**

| 角色 | 用于哪一步 |
|-----|-----------|
| `roles/serviceusage.serviceUsageAdmin` | 启用 11 个 API、创建服务代理（P4SA） |
| `roles/resourcemanager.projectIamAdmin` | 给函数 SA 与各服务代理授权（secret 级 `secretAccessor`、项目级 `run.invoker` 等） |
| `roles/pubsub.admin` | 建 topic、DLQ、订阅、死信策略，以及给各服务代理授 publisher |
| `roles/secretmanager.admin` | 创建 webhook / 签名密钥的 Secret 并追加版本 |
| `roles/storage.admin` | 源码 bucket |
| `roles/cloudfunctions.developer` | 部署 Gen2 函数 |
| `roles/iam.serviceAccountAdmin` | 创建自定义运行时 SA `gcp-alerts-fn` |
| `roles/iam.serviceAccountUser` | **把运行时 SA 附加给函数**（见下方注意事项） |
| `roles/monitoring.notificationChannelEditor` | 创建 / 复用 Notification Channel；`OPS_EMAIL` 非空时还要创建邮件渠道 |
| `roles/monitoring.alertPolicyEditor` | 创建 / 更新 Service Health 告警策略、推荐默认告警包；`OPS_EMAIL` 非空时还有两条自监控策略 |
| `roles/logging.configWriter` | 同上 —— Service Health 与「永久发送失败」自监控是**日志型**告警策略，另需 `logging.notificationRules.create`（见下方注意事项） |
| `roles/logging.viewer` | 部署后自检读取函数日志 |
| `roles/browser` | 列出可选项目、读取项目编号与所属组织 |

**部署前权限预检**：部署脚本会在启用 API 之前调用
`cloudresourcemanager projects:testIamPermissions`（只读，不建任何资源）探测下面 8 项权限，
缺失时列出清单并拼出一条可直接粘贴的 `add-iam-policy-binding` 补救命令
（`--member=` 默认按 `gcloud config get-value account` 解析为 `user:` / `serviceAccount:`，
WIF `principal://` 身份请用 `DEPLOYER_MEMBER` 环境变量显式指定）。
交互模式会询问是否继续；`--yes` / 非 TTY 只打印不阻塞；curl 失败或 HTTP 非 2xx（API 未启用、CBA、代理）只 WARNING 不阻塞。

| 预检的权限 | 对应角色 |
|-----------|---------|
| `resourcemanager.projects.setIamPolicy` | `roles/resourcemanager.projectIamAdmin` |
| `serviceusage.services.enable` | `roles/serviceusage.serviceUsageAdmin` |
| `iam.serviceAccounts.create` | `roles/iam.serviceAccountAdmin` |
| `secretmanager.secrets.create` | `roles/secretmanager.admin` |
| `pubsub.topics.create` | `roles/pubsub.admin` |
| `cloudfunctions.functions.create` | `roles/cloudfunctions.developer` |
| `monitoring.alertPolicies.create` | `roles/monitoring.alertPolicyEditor` |
| `monitoring.notificationChannels.create` | `roles/monitoring.notificationChannelEditor` |

探测结果**偏保守**：组成员、条件绑定、自定义角色可能不计入。预检通过 ≠ 一定成功，预检失败 ≠ 一定失败 ——
它只是把「跑到第 13 步才发现缺权限」提前到第一步。

除部署者本身外，还有**两个服务账号**需要项目级角色。它们容易被漏掉，因为报错都不指向 IAM：

| 被授权者 | 角色 | 不给会怎样 |
|---------|-----|-----------|
| `<项目号>-compute@developer.gserviceaccount.com`（Cloud Build 用） | `roles/cloudbuild.builds.builder` | 函数**构建失败**，报 "missing permission on the build service account"。2024 年起 Google 不再给新项目的默认 compute SA 自动授 Editor，新项目必踩 |
| `gcp-alerts-fn@<项目>.iam.gserviceaccount.com`（触发器身份） | `roles/run.invoker` | Eventarc 调不动函数：**投递被 403 拒绝、函数从未执行、日志里只有 WARNING**，部署与控制台看起来一切正常 |

**② 组织级（仅在启用 SCC 时需要）**

| 角色 | 授予位置 |
|-----|---------|
| `roles/securitycenter.notificationConfigEditor` | **组织**，非项目 |

**③ 结算账号级（仅在启用 Billing 预算时需要）**

| 角色 | 授予位置 |
|-----|---------|
| `roles/billing.costsManager` | **结算账号**，非项目。含 `billing.budgets.*` 全部权限；`roles/billing.admin` 是其超集 |
| `roles/billing.viewer` | 项目级，用于读出项目关联的结算账号 |

一键授予（把三个 `XXX` 换成你的值）：

```bash
PROJECT_ID=your-project
MEMBER='user:someone@example.com'      # 或 serviceAccount:ci@....iam.gserviceaccount.com

for role in serviceusage.serviceUsageAdmin resourcemanager.projectIamAdmin \
            pubsub.admin secretmanager.admin storage.admin \
            cloudfunctions.developer iam.serviceAccountAdmin iam.serviceAccountUser \
            monitoring.notificationChannelEditor monitoring.alertPolicyEditor \
            logging.configWriter logging.viewer browser; do
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="${MEMBER}" --role="roles/${role}" --condition=None >/dev/null
done

# 两个服务账号（缺了都不报 IAM 错，只是悄悄不工作）
PROJECT_NUMBER=$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)')
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
  --role='roles/cloudbuild.builds.builder' --condition=None >/dev/null
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:gcp-alerts-fn@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role='roles/run.invoker' --condition=None >/dev/null   # 须在函数首次部署后执行

# 仅启用 SCC 时（需要组织管理员执行）
gcloud organizations add-iam-policy-binding YOUR_ORG_ID \
  --member="${MEMBER}" --role='roles/securitycenter.notificationConfigEditor'

# 仅启用 Billing 预算时（需要结算账号管理员执行）
gcloud billing accounts add-iam-policy-binding YOUR_BILLING_ACCOUNT_ID \
  --member="${MEMBER}" --role='roles/billing.costsManager'
```

三个容易踩的点：

- **`roles/iam.serviceAccountUser` 是最容易漏的一个。** 缺它时，前面所有资源都会创建成功，
  只在 `gcloud functions deploy` 那一步失败，报错指向 `actAs` 权限而不提运行时 SA ——
  看起来像"函数部署炸了"，实际是授权问题。
- **Gen2 的部署动作不需要单独授 `run.*` / `eventarc.*` / `artifactregistry.*` / `cloudbuild.*`**
  —— 这些已包含在 `roles/cloudfunctions.developer` 内。但**给 Run 服务改 IAM 是例外**：
  `run.services.setIamPolicy` 不在该角色里，所以上表那条 `run.invoker` 要么授在
  **项目级**（用已有的 `projectIamAdmin` 即可），要么额外给部署者 `roles/run.admin`
  才能授在服务级。部署脚本优先检查并使用项目级绑定，避免为此扩权。
- **Service Health 策略是日志型的，`monitoring.alertPolicyEditor` 不够。**
  实际被拒的权限是 `logging.notificationRules.create`，来自 `roles/logging.configWriter`。
- **缺权限不会中断部署，但也不会假装成功。** 见下节。

以上是**部署者身份**的权限。**函数运行时**用的是另一个身份（自定义 SA `gcp-alerts-fn`），
由脚本自动创建，只有 `roles/secretmanager.secretAccessor`（逐 Secret 绑定）与底层 Run 服务上的
`roles/run.invoker`（作为 Eventarc 触发器身份）—— 函数只写 stdout，由平台采集，**不需要也不再授 `roles/logging.logWriter`**
（teardown 仍会回收旧环境里的该绑定）。不要把上面这些部署权限授给它。

自定义 SA 创建失败时脚本会回落到默认 compute SA：能跑，但权限面大得多，
且 secretAccessor 与触发器身份也都落在默认 compute SA 上 —— 这应被视为降级而非常态。

### 权限不够时会怎样

**不中断主流程，但也不会假装成功。** 步骤分两级：

- **必需**（topic 与订阅、Secret 写入、源码上传、函数部署）—— 缺权限立即中止。
  缺了它们，继续下去只会产出一个不工作的空壳。
- **可降级**（服务代理授权、自定义 SA 与 IAM 绑定、死信策略、Notification Channel、
  Service Health 策略、推荐默认告警包、自监控（`OPS_EMAIL`）、SCC、Billing、自检读日志）—— 打印影响与补权命令后**跳过，继续往下跑**。

结尾会汇总一份清单：

```
⚠️  本次部署【不完整】：2 个步骤因权限不足被跳过

  1. 给 Monitoring 服务代理授 gcp-alerts-hub 的 publisher
     影响：Cloud Monitoring 指标告警将【静默】进不来 —— 部署看起来成功、
           日志也没有错误，群里就是收不到卡片
     补救：gcloud pubsub topics add-iam-policy-binding gcp-alerts-hub \
             --member=serviceAccount:service-...@gcp-sa-monitoring-notification... \
             --role=roles/pubsub.publisher --project=...
  2. ...

  补齐权限后重跑本脚本即可 —— 全流程幂等，已建成的资源不会重复创建。
```

**退出码区分三态**：`0` 完全成功 / `2` 不完整（核心链路已建立，有步骤被跳过）/
`1` 失败或自检未通过。CI 里请按这三态判断，不要只看"是否非 0"。

只要有任何跳过项，脚本就**不会**打印"部署完成"。这是有意的：跳过一步服务代理授权，
表现恰恰是"资源都在、日志无错、控制台全绿，告警就是进不来" —— 也就是本项目开篇那张
静默失效表里的一行。让不完整的部署看起来成功，等于亲手制造它。

有一个级联行为值得知道：Notification Channel 创建失败时，脚本**不会**继续创建 Service
Health 告警策略。一条没有通知渠道的策略在控制台里显示为正常，却永远不发通知 ——
比不创建更糟。

---

## 部署选项

```bash
./deploy-gcloud.sh                                         # 交互式（推荐）
./deploy-gcloud.sh --project=my-proj --region=asia-east1   # 指定项目与区域（默认 asia-east1）
./deploy-gcloud.sh --help                                  # 全部参数与环境变量
```

脚本先让你选择项目，再依次询问通知渠道、Webhook 与签名密钥、是否启用 Google Cloud 服务故障告警（PSH）/ 推荐默认告警包 / SCC / Billing 预算，
以及**运维通知邮箱**（IM 链路自身故障时的兜底收件人；留空会登记为「已跳过」并使退出码为 2）。随后按以下顺序执行：

| 步骤 | 内容 |
|-----|------|
| 1 | 交互式输入（先问，避免启用一堆 API 后才发现用户想取消）；含渠道选择与 `速率 × MAX_INSTANCES` 上限校验（超限直接退出 1） |
| 1.5 | **部署者权限预检**（只读，见上节） |
| 2 | 启用 API + 创建服务代理 |
| 2.5 | 构建身份：给默认 compute SA 补 `cloudbuild.builds.builder` |
| 3 | Secret Manager（只写所选渠道的 Secret；幂等：已存在则追加新版本） |
| 4 | 自定义运行时 SA（失败回落默认 compute SA）；对所选渠道每个 Secret 逐个授 `secretAccessor` |
| 5 | Pub/Sub：主 topic + DLQ topic + DLQ 订阅 |
| 6 | 各服务代理的 publisher 授权 |
| 7 | 源码打包上传 |
| 8 | 部署 Cloud Functions Gen2（只挂载所选渠道的 Secret） |
| 8.5 | 确保触发器身份有 `run.invoker` |
| 9 | 给 Eventarc 生成的订阅挂死信策略 |
| 10 | Monitoring Notification Channel「Feishu Alert Hub」（历史命名，与所选渠道无关） |
| 11 | PSH 两类策略 + 推荐默认告警包（可选，包含五大类共 11 条开箱即用策略，含 `Recommended - GCE & GPU Upcoming Host Maintenance`） |
| 11.5 | **自监控告警**（`OPS_EMAIL` 非空时：邮件渠道 + 两条策略） |
| 12 | SCC（可选） |
| 13 | Billing Budgets（可选；重跑时用 `--clear-threshold-rules` + `--add-threshold-rule` 更新） |
| 14 | 自检（发 `test_event`，按 `jsonPayload.alert_type="test_event"` 且时间晚于自检开始来判定） |
| 15 | 结论与跳过清单 |

### 选择通知渠道（三选一）

每次部署只对接**一个** IM 平台（`NOTIFY_CHANNEL`），default / security / billing 三个路由组都走它。
未设置时为 `feishu`（函数已存在时沿用线上渠道，见[重跑部署不回退配置](#重跑部署不回退配置)），存量部署与存量命令行零变化。

> 函数名 `gcp-alerts-to-feishu`、通知渠道 `Feishu Alert Hub`、Secret `feishu-*`、预算 `Feishu Alert Budget - <项目>`、
> SCC 导出 `feishu-scc-export` 中的 feishu 均为**历史命名，与所选渠道无关**，选企业微信 / 钉钉时同样沿用。

**交互模式**先出菜单（直接回车 = 飞书；若预置了 `NOTIFY_CHANNEL` 或沿用了线上渠道则默认选它）：

```
请选择通知渠道（每次部署只能选一个，default/security/billing 三类告警都发往该平台）：
  1) 飞书/Lark
  2) 企业微信
  3) 钉钉
输入编号 [1]:
```

**非交互模式**（`--yes` / CI）从环境变量读取：

| 渠道 | `NOTIFY_CHANNEL` | 必填环境变量 | 脚本侧校验 |
|-----|------------------|-------------|-----------|
| 飞书/Lark | `feishu`（默认） | `FEISHU_WEBHOOK`、`FEISHU_SECRET`（未开签名填 `NONE`） | 不变 |
| 企业微信 | `wecom` | `WECOM_WEBHOOK` | `^https://qyapi\.weixin\.qq\.com/cgi-bin/webhook/send\?key=[A-Za-z0-9-]+$` |
| 钉钉 | `dingtalk` | `DINGTALK_WEBHOOK`、`DINGTALK_SECRET`（未开加签填 `NONE`，空值拒绝） | `^https://oapi\.dingtalk\.com/robot/send\?access_token=[A-Za-z0-9]+$`；密钥含空白字符拒绝，不以 `SEC` 开头仅 WARNING |

```bash
# 企业微信
NOTIFY_CHANNEL=wecom WECOM_WEBHOOK='https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=xxx' \
  ./deploy-gcloud.sh --project=my-proj --region=asia-east1 --yes

# 钉钉（DINGTALK_SECRET 填 SEC 开头的加签密钥，或 NONE）
NOTIFY_CHANNEL=dingtalk DINGTALK_WEBHOOK='https://oapi.dingtalk.com/robot/send?access_token=xxx' DINGTALK_SECRET='SECxxx' \
  ./deploy-gcloud.sh --project=my-proj --region=asia-east1 --yes
```

#### 各平台机器人创建要点

> 分步教程（入口路径、常见问题、部署前手工验证 Webhook 的命令）见 **[bot-setup.md](bot-setup.md)**；下面只列与部署相关的要点。

- **飞书/Lark**：群设置 → 群机器人 → 添加机器人 → 自定义机器人。签名见下文[签名密钥怎么填](#签名密钥怎么填)。
- **企业微信**：群聊 → 群机器人（消息推送）→ 添加机器人后复制 Webhook。**没有签名机制**，
  URL 里的 `key` 就是凭据 —— 只放进 Secret Manager，不要贴进工单或代码。
- **钉钉**：群设置 → 机器人 → 添加机器人 → 自定义。安全设置三种至少选一种：
  - **加签（推荐）**：填 `SEC` 开头的密钥到 `DINGTALK_SECRET`。函数每次发送时实时计算
    `sign = urlencode(base64(HmacSHA256(key=secret, msg="{毫秒时间戳}\n{secret}")))`，以 `&timestamp=…&sign=…`
    追加到 webhook query —— 与飞书（key=`"{秒级时间戳}\n{secret}"`、消息为空串、签名放请求体）**正好相反**，写反的表现是 `errcode=310000`。
    所以 webhook **不要**自己拼 `&timestamp=&sign=`。
  - **自定义关键词**：`DINGTALK_SECRET=NONE`，关键词**必须设为 `GCP告警`**（卡片标题固定以它开头，正文首行也含它）；
    其它关键词会让全部卡片被拒。
  - **IP 地址（段）**：需要固定出口 IP，本方案默认函数出口 IP 不固定，**不建议单独使用**。

#### 限流差异与默认速率

| 渠道 | 平台限流（单机器人） | 超限表现 | 默认 `MAX_SENDS_PER_MINUTE`（每实例） | `速率 × MAX_INSTANCES` 上限 |
|-----|-------------------|---------|-------------------------------------|---------------------------|
| 飞书/Lark | 100 条/分钟 | HTTP 429（按瞬时失败重试） | 40 | 80 |
| 企业微信 | 20 条/分钟 | `errcode=45009`，约 1 分钟解除 | 8 | 16 |
| 钉钉 | 20 条/分钟 | `errcode=130101`，**封禁 10 分钟** | 8 | 16 |

上限 = 平台限流 × 80%。部署脚本在**创建任何资源之前**校验，超限直接退出 1
（shell 里残留 `MAX_SENDS_PER_MINUTE=40` 再切到企业微信 / 钉钉会被拦下，`unset MAX_SENDS_PER_MINUTE` 即可）。`MAX_INSTANCES` 默认 2。

#### Secret 与授权

| 渠道 | Secret（部署脚本创建） | 函数环境变量 | 名称覆盖变量 |
|-----|-------------------------------------------|-------------|------------|
| 飞书 | `feishu-default-webhook`、`feishu-default-secret` | `FEISHU_DEFAULT_WEBHOOK`、`FEISHU_DEFAULT_SECRET` | `SECRET_WEBHOOK_NAME` / `SECRET_SIGN_NAME` |
| 企业微信 | `wecom-default-webhook` | `WECOM_DEFAULT_WEBHOOK` | `SECRET_WECOM_WEBHOOK_NAME` |
| 钉钉 | `dingtalk-default-webhook`、`dingtalk-default-secret` | `DINGTALK_DEFAULT_WEBHOOK`、`DINGTALK_DEFAULT_SECRET` | `SECRET_DINGTALK_WEBHOOK_NAME` / `SECRET_DINGTALK_SIGN_NAME` |

只 upsert / 只授 `secretAccessor` 给所选渠道的 Secret（授给函数实际运行身份：自定义 SA，回落时为默认 compute SA）。
用了名称覆盖变量时，teardown 须传相同的值。

#### 切换渠道

推荐用 `./scripts/configure.sh --section=channel`；也可以换一组环境变量重跑部署脚本：

- `--set-env-vars` / `--set-secrets` 都是整体替换，旧渠道的挂载自然消失；
  旧渠道 Secret 本体及其 accessor 绑定**保留**（不再被挂载）。
- **回收**：`./scripts/teardown-gcloud.sh --delete-secrets` 按精确名探测五个渠道 Secret，存在才删
  （不加该参数时只回收 Secret 上授给函数 SA / 默认 compute SA 的 accessor，Secret 本体保留）。

部署结束的自检会在群里发一张「🟢 [GCP 监控告警中心] 连通性自检成功」卡片。

### 选择部署项目

所有部署与运维脚本都支持 `--project=ID`，不传则交互式选择：

```
请选择要部署的 GCP 项目：
   1) my-prod-project                   My Prod
   2) my-staging-project                Staging
   3) my-poc-project                    POC  ← 当前默认
输入编号或项目 ID [3]:
```

优先级 `--project` > `PROJECT_ID` 环境变量 > 交互式选择 > `gcloud` 默认项目。
若当前账号没有 `resourcemanager.projects.list` 权限（只被授予单个项目时很常见），
会降级为手工输入项目 ID 而不是直接失败。

选定的项目通过 `CLOUDSDK_CORE_PROJECT` 只在本次运行内生效，**不会改写你的 `gcloud`
默认配置** —— 部署一次就把机器上的默认项目换掉，是最容易引发后续误操作的副作用。

`--yes` 非交互模式下不会询问，必须显式给 `--project` 或预先设好默认项目。

### 多项目汇聚（Hub 模式）

把多个源项目（或整个文件夹 / 组织）的告警汇聚到本项目再推送，通过 `./scripts/configure.sh` 的 ⑧ 号菜单交互式添加 / 移除源项目。
详见 [多项目汇聚（Hub 模式）](multi-project-hub.md)。

### 签名密钥怎么填

| 机器人配置 | 应填内容 |
|-----------|---------|
| 飞书：开启了"签名校验" | 飞书给出的那串密钥（`FEISHU_SECRET`） |
| 飞书：没开签名校验 | 字符串 `NONE`（**必须显式填**，不能留空） |
| 钉钉：安全设置为「加签」（推荐） | 钉钉给出的 `SEC` 开头密钥（`DINGTALK_SECRET`） |
| 钉钉：只用「自定义关键词」/「IP 地址（段）」 | 字符串 `NONE`；关键词必须为 `GCP告警` |
| 企业微信 | 无需填写 —— 群机器人没有签名机制 |

留空是非法的：空密钥会让所有卡片被飞书以 `sign match fail` 拒绝（钉钉为 `errcode=310000`），
而 HTTP 状态码仍然是 200 —— 这正是最典型的静默失效。

### 接入更多告警策略

部署完成后，任何 Cloud Monitoring 告警策略只要把通知渠道选成
**"Feishu Alert Hub"**（历史命名，与所选渠道无关），就会自动流入这条链路，无需改动代码。

---

## 修改配置（configure.sh）

`scripts/configure.sh` 用来**修改已部署环境**的配置：读取线上现状 → 分区引导 → 预览差异 → 确认 →
复用部署脚本应用 → 校验函数已重启。它不直接改 Cloud Run 服务，而是复用部署脚本应用，保证之后重跑部署不会把改动静默回退。

```bash
./scripts/configure.sh [--project=ID] [--region=REGION] \
  [--section=channel,filter,rate,policies,sources,switches,source-filter,hub] [--dry-run] [--yes]
```

| 参数 | 说明 |
|-----|------|
| `--project=ID` | 目标项目；不传则交互式选择，规则同部署脚本 |
| `--region=REGION` | 函数所在区域，默认 `asia-east1` |
| `--section=LIST` | 只走指定分区（逗号分隔），其余保持现值；`--yes` 下未选中分区的环境变量被忽略 |
| `--dry-run` | 只展示「当前值 → 新值」差异，**不执行任何写操作**（不调用部署脚本） |
| `--yes` | 非交互：各项取环境变量，未提供则保持现值 |

### 流程

1. **识别部署方式**：自动识别，无需指定。
2. **读取线上现状**：函数 env 与 Secret 挂载、各告警策略 / 预算 / SCC 导出是否存在。函数不存在时提示先部署并退出 1；
   同名函数在其它区域时提示「在其它区域发现同名函数：… —— 请用 --region=<区域> 重跑」。
3. **打印「当前配置」**：webhook 只显示打码前缀；读不到明文（缺 `secretmanager.versions.access`）时降级为
   「Secret <名>（最新版本 N，创建于 <时间>）」，元数据也读不到则显示「版本信息不可读」，均不报错。
   当前 `KILL_SWITCH` / `PAUSE_MODE` 为 true 时会醒目提示。
4. **主菜单引导**：交互模式下且未传 `--section` 时，显示编号多选主菜单（1 通知渠道与凭据 ... 6 运行开关、7 按来源过滤、8 多项目汇聚）。输入编号多选并以逗号分隔，直接回车等于依次修改全部，输入 0 退出不改。连续 3 次非法输入将退出。
5. **差异预览**：走完所选分区后，列出「当前值 → 新值」；关闭类变更单列，并说明会删除哪些资源。
6. **确认**：交互模式提供 `[a] 应用 / [m] 返回菜单继续修改（保留已改值） / [q] 放弃`。**必须显式输入 `a` 才会应用**，回车无效。无任何变化时询问「是否仍要强制重启函数」（默认 Y）。
7. **调用部署脚本**：`<部署脚本> --project=… --region=… --yes`，所有取值（含新的 `CONFIG_REVISION`）经环境变量传入，
   凭据不进 argv、不落文件。
8. **校验重启**：确认函数上的 `CONFIG_REVISION` 等于本次值、且最新 revision 创建时间晚于应用开始（容忍 60 秒时钟偏差），
   打印 `函数已重启：最新 revision <名>（创建于 …，应用开始于 …），CONFIG_REVISION=…`。
9. **删除关闭项**：部署脚本只 upsert 不删除，所以「开 → 关」的资源由 configure 在此按精确名删除
   （配置未生效时跳过删除）。

示例（值为占位）：

```
━━━━━━━━━━━━━━━━━━━━━━ 当前配置 ━━━━━━━━━━━━━━━━━━━━━━
  部署模式                 gcloud（将调用 ./deploy-gcloud.sh）
  ① 通知渠道             飞书（NOTIFY_CHANNEL=feishu）
     Webhook                   https://open.feishu.cn/open-apis/bot/v2/hook/abcd****
  ② MIN_SEVERITY             MEDIUM
  ...
━━━━━━━━━━━━━━━━━━━━━━ 变更预览 ━━━━━━━━━━━━━━━━━━━━━━
  项目                     当前值 → 新值
  MIN_SEVERITY               MEDIUM → HIGH
  推荐默认告警包      开启 → 关闭

  关闭类变更（会删除资源）：
    - 推荐默认告警包：删除 11 条「Recommended - …」告警策略（按精确名）
...
✅ 函数已重启：最新 revision gcp-alerts-to-feishu-000NN-xxx（创建于 …，应用开始于 …），CONFIG_REVISION=20260101T000000Z
✅ 关闭类变更已落实
✅ 配置已更新并重启生效（gcloud 模式）
```

### 各分区可改项

| 分区（`--section`） | 可改项 | 说明 |
|-----|------|------|
| ① `channel` | `NOTIFY_CHANNEL` 与凭据 | 同渠道可选「保持现有凭据」（`KEEP_EXISTING_SECRETS=true`，不追加 Secret 版本）或「输入新凭据」（写入 Secret 新版本）；换渠道必须输入新渠道凭据。`--yes` 下提供某渠道凭据环境变量 = 输入新凭据 |
| ② `filter` | `MIN_SEVERITY` / `LOG_LEVEL` | `CRITICAL/HIGH/MEDIUM/LOW/INFO`；`DEBUG/INFO/WARNING/ERROR` |
| ③ `rate` | `MAX_SENDS_PER_MINUTE` / `MAX_INSTANCES` | 按渠道上限（80 / 16 / 16）校验；换渠道时速率自动改为新渠道默认值 |
| ④ `policies` | `ENABLE_PSH` / `ENABLE_DEFAULT_ALERTS` / `OPS_EMAIL` | 交互中输入 `-` 关闭自监控；`--yes` 下 `OPS_EMAIL=`（空串）关闭 |
| ⑤ `sources` | `ENABLE_BILLING` + `BUDGET_AMOUNT` / `ENABLE_SCC` | 金额如 `100` 或 `100USD` |
| ⑥ `switches` | `KILL_SWITCH` / `PAUSE_MODE` | 当前为 true 时向导里回车 = **保持**急停 / 暂停（与重跑部署脚本相反，见下文） |
| ⑦ `source-filter` | `SOURCE_MIN_SEVERITY` | 逐个来源（Monitoring / Service Health / Billing / SCC）设置；回车=保持，1=跟随全局，2=关闭（OFF），3~7=级别。数据源/策略仍开启但此处设为 OFF 时会提示被函数丢弃 |
| ⑧ `hub` | `HUB_SOURCE_PROJECTS` / `HUB_SCOPE` / 绑定源项目已有策略 | 交互式添加/移除源项目、配置文件夹/组织范围聚合 Sink、授权与绑定策略；详情见 [多项目汇聚](multi-project-hub.md) |

各关闭项删除的资源（均按精确 displayName / 资源名）：

| 关闭项 | 删除的资源 |
|-------|----------|
| PSH | `GCP Service Health Incident` / `GCP Service Health Emerging Incident`，以及旧版「计划维护」「安全公告」两条 |
| 推荐默认告警包 | 11 条 `Recommended - …` 策略 |
| 自监控（`OPS_EMAIL` 置空） | `GCP Alerts Hub - Permanent Send Failure` / `GCP Alerts Hub - DLQ Backlog` 两条策略 + 邮件渠道 `GCP Alerts Hub Ops Email` |
| Billing | 预算 `Feishu Alert Budget - <项目>` |
| SCC | 导出 `feishu-scc-export`（仅当其指向本项目 topic） |

### 退出码

| 退出码 | 含义 |
|------|------|
| `0` | 已生效且已确认重启；`--dry-run`、确认处取消也返回 0（未做修改） |
| `2` | 已生效，但部署脚本以「不完整」结束 / 连通性自检未过 / 未能确认新 revision / 关闭项有删除失败 |
| `1` | 未生效（部署脚本失败、函数上的 `CONFIG_REVISION` 不是本次值、参数或输入无效） |

`KILL_SWITCH` / `PAUSE_MODE` 设为 true 时，部署脚本的连通性自检**必然失败**（函数不投递任何告警），
configure 会提示「属预期」并以 `2` 退出。

### 关键变量

- **`CONFIG_REVISION`**：configure 每次应用写入 UTC 时间戳（如 `20261019T031936Z`，与线上相同时追加 `-1`），
  env 值变化保证一定拉新 revision —— 也是「只换了 Secret 值」时让 `:latest` 被重新解析的手段（无变化时选「强制重启」即可）。
- **`KEEP_EXISTING_SECRETS=true`**：沿用 Secret Manager 中本渠道现有凭据：不输入、不追加新版本；
  会校验本渠道每个 Secret 存在且至少有一个启用版本，否则报错退出。configure 的「保持现有凭据」即用它。

### 现状读不到时怎么办

缺 `roles/billing.viewer`、SCC 组织级 `notificationConfigViewer` 等只读权限时，部分现状为「未知」：

- 保持不动（不创建也不删除），部署脚本打印「无法读取线上现状、本次保持不动（不创建也不删除）：…」。

所需只读权限：`cloudfunctions.viewer`、`monitoring.viewer`、（可选）`billing.viewer`、SCC `notificationConfigViewer`；
预览 webhook 明文需 `secretmanager.versions.access`（没有也不影响流程）。

### 重跑部署不回退配置

重跑 `./deploy-gcloud.sh` 不会把改过的配置回退：**函数已存在时**，未显式提供的以下变量沿用线上现值，
并打印一行 `沿用线上配置：…（显式设置同名环境变量可覆盖）`：

- 运行时：`NOTIFY_CHANNEL`、`MIN_SEVERITY`、`SOURCE_MIN_SEVERITY`、`LOG_LEVEL`、`MAX_SENDS_PER_MINUTE`（仅同渠道）、`MAX_INSTANCES`、`CONFIG_REVISION`；
  wecom / dingtalk 部署重跑不再回到飞书（`--yes` 下需提供该渠道凭据或 `KEEP_EXISTING_SECRETS=true`）。
- 数据源 / 告警策略：`ENABLE_PSH`、`ENABLE_DEFAULT_ALERTS`、`ENABLE_SCC`、`ENABLE_BILLING`、`BUDGET_AMOUNT`、`OPS_EMAIL`
  （PSH / 默认包 / 自监控按精确 displayName 判断，预算按 `Feishu Alert Budget - <项目>`，SCC 按 `feishu-scc-export`）。
  交互部署时相应提问的回车默认值 = 线上现状（「回车沿用线上：Y」）。显式设置（包括 `OPS_EMAIL=` 空值）优先；
  现状读不到时的处理同上节。

例外与边界：

- **`KILL_SWITCH` / `PAUSE_MODE` 仍复位为 `false`**（「重跑部署 = 解除急停」语义不变），但线上为 true 时打印醒目 WARNING。
  要保持急停：`KILL_SWITCH=true ./deploy-gcloud.sh`，或 `./scripts/configure.sh --section=switches`。
- **首次部署**（函数不存在）不读这些现状。
- 重跑部署仍然**只 upsert、不删除**；要关闭并删除资源请用 configure。
- `deploy-gcloud.sh` 在输入凭据前会多一次只读的 `gcloud functions describe`。

---

---

## 日常运维

```bash
./scripts/configure.sh                      # 修改配置并重启生效（见上节）
./scripts/emergency-disable.sh              # 紧急停止（丢弃消息，~30 秒生效）
./scripts/emergency-disable.sh --pause      # 暂停（消息堆积，恢复后自动重投）
./scripts/emergency-enable.sh               # 恢复
./scripts/replay-dlq.sh                     # 交互式重放死信队列
./scripts/update-dependencies.sh --check    # 检查依赖更新与已知漏洞
./scripts/teardown-gcloud.sh                # 卸载（加 --delete-secrets 同时删除机器人凭据）
```

每个脚本都支持 `--help`。除 `update-dependencies.sh` 外都支持 `--project=ID`，
不传则交互式选择 —— 尤其是 `teardown-gcloud.sh`，"部署时选了 A、卸载时打到默认的 B"
是这类脚本最典型的事故。

几条行为说明：

- **急停不是持久配置。** `emergency-*.sh` 直接改底层 Cloud Run 服务的环境变量，
  下一次 `deploy-gcloud.sh` 会把 `KILL_SWITCH` / `PAUSE_MODE` 复位 ——
  急停期间重部署 = 恢复转发（线上为 true 时部署脚本打印 WARNING）。要持久急停：
  `./scripts/configure.sh --section=switches` 或 `KILL_SWITCH=true ./deploy-gcloud.sh`。
- **`replay-dlq.sh` 的流程**：预览 pull → 立即 `modify-ack-deadline=0` 归还租约 → 人工确认 →
  重新 pull（拿新鲜 ackId）→ publish 成功后 ack。实际重放集合以重新拉取为准，可能与预览略有出入。
- **换 webhook / 密钥后需要拉新 revision。** 部署脚本只往 Secret 追加新版本；函数以 `:latest`
  在实例启动时解析，已运行实例会沿用旧值直到缩容为 0。
  要立即生效，推荐 `./scripts/configure.sh --section=channel` 选「输入新凭据」（会写入新版本并重启），
  或只换了 Secret 值时直接运行 configure、在「无变化」处选择强制重启（更新 `CONFIG_REVISION` 拉新 revision）。
- **`teardown-gcloud.sh`** 只按本项目固定的资源名 / displayName 精确匹配删除，不会碰你自建的同前缀资源；
  Secret 默认保留（只回收其上的 accessor 绑定），加 `--delete-secrets` 才删除机器人凭据。

---

---

## 配置项

全部通过环境变量配置，函数在**启动期**校验，非法配置直接崩溃而不是静默降级。

| 变量 | 必填 | 默认 | 说明 |
|-----|------|------|------|
| `NOTIFY_CHANNEL` | ❌ | `feishu` | `feishu` \| `wecom` \| `dingtalk`（大小写与首尾空格不敏感）；其它值启动即 `ConfigError`。**只读所选渠道的变量**，其余渠道的变量被忽略（残留的 `FEISHU_*` 不会让企微部署"看起来配好了"） |
| `FEISHU_DEFAULT_WEBHOOK` | ✅（feishu） | — | 默认群的 webhook；必须以 `https://open.feishu.cn/` 或 `https://open.larksuite.com/` 开头，否则启动失败（`ConfigError`） |
| `FEISHU_DEFAULT_SECRET` | ✅（feishu） | — | 签名密钥；未开签名校验填 `NONE` |
| `FEISHU_SECURITY_WEBHOOK` / `_SECRET` | ❌ | 回落默认群 | SCC 告警专用群，**必须成对配置**；webhook 同样受前缀校验 |
| `FEISHU_BILLING_WEBHOOK` / `_SECRET` | ❌ | 回落默认群 | Billing 告警专用群，同上 |
| `WECOM_DEFAULT_WEBHOOK` | ✅（wecom） | — | 必须以 `https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=` 开头；企微无签名，**没有** `WECOM_*_SECRET` |
| `WECOM_SECURITY_WEBHOOK` / `WECOM_BILLING_WEBHOOK` | ❌ | 回落默认群 | 同上前缀校验 |
| `DINGTALK_DEFAULT_WEBHOOK` | ✅（dingtalk） | — | 必须以 `https://oapi.dingtalk.com/robot/send?access_token=` 开头 |
| `DINGTALK_DEFAULT_SECRET` | ✅（dingtalk） | — | 加签密钥；关键词 / IP 模式填 `NONE`（空串拒绝） |
| `DINGTALK_SECURITY_WEBHOOK` / `_SECRET`、`DINGTALK_BILLING_WEBHOOK` / `_SECRET` | ❌ | 回落默认群 | **必须成对配置** |
| `MIN_SEVERITY` | ❌ | `MEDIUM` | 低于此级别不转发（自检事件绕过） |
| `SOURCE_MIN_SEVERITY` | ❌ | 未设置 | 按来源过滤，格式 `key=VALUE;...`（如 `monitoring=HIGH;billing=OFF`）。优先级高于全局 `MIN_SEVERITY`，设为 `OFF` 不转发；未设置或空串则跟随全局。 |
| `LOG_LEVEL` | ❌ | `INFO` | 调成 WARNING 会丢掉排查所需的信号 |
| `KILL_SWITCH` | ❌ | `false` | 紧急开关：直接 ack 丢弃 |
| `PAUSE_MODE` | ❌ | `false` | 暂停：nack 堆积，恢复后重投 |
| `MAX_SENDS_PER_MINUTE` | ❌ | 按渠道 `40` / `8` / `8` | 单实例出速率，× 实例数须 ≤ 80 / 16 / 16（飞书 / 企业微信 / 钉钉）；单实例就超过平台单机器人限额（100 / 20 / 20）时不拒绝启动，但记 WARNING `reason=rate_exceeds_platform_limit` |
| `MAX_REPLAY_COUNT` | ❌ | `2` | 重放次数上限，阻断 DLQ 死循环 |
| `SELF_PROJECT_ID` | ❌ | 自动探测 | 回环保护用 |
| `CONFIG_REVISION` | ❌ | 未设置 | 配置修订号，函数不解析其值；仅在设置时注入，`configure.sh` 每次应用写入 UTC 时间戳以强制拉新 revision |

部署脚本额外读取的环境变量（完整说明见各脚本 `--help`）：

| 变量 | 说明 |
|-----|------|
| `MAX_INSTANCES` | 函数最大实例数（默认 2） |
| `KEEP_EXISTING_SECRETS=true` | 沿用本渠道现有 Secret，不输入、不追加版本；Secret 不存在或无启用版本则报错退出 |
| `CONFIG_REVISION` | 见上表 |
| `KILL_SWITCH` / `PAUSE_MODE` | `true` \| `false`，取值有校验；**未提供时一律复位为 false** |
| `MIN_SEVERITY` / `LOG_LEVEL` | 取值有校验；函数已存在且未提供时沿用线上 |
| `SECRET_*_NAME` | Secret 名覆盖，见[Secret 与授权](#secret-与授权) |

多群路由的配置步骤见 [排查指南 · 多群路由](troubleshooting.md#5-多群路由)。

函数启动时会以结构化 JSON 记一条 `Config loaded` INFO 日志（含 `channel` / `min_severity` / `kill_switch` /
`pause_mode` / `self_project_id` 等快照，webhook 与密钥不出现），在 Cloud Logging 里可直接核对实际生效的配置。

---

---

## FAQ

**Q：为什么我的告警严重性全是 HIGH？**
Cloud Monitoring 的 `severity` 只有在告警策略里显式配置了才存在。没配的策略，
其告警一律按 HIGH 处理 —— 这是有意的 fail-open：把未知严重性当成最低级，
会在默认 `MIN_SEVERITY=MEDIUM` 下**静默丢弃全部告警**。
监控系统的失效方向必须是"多报"而非"漏报"。

**Q：部署成功了，但群里一张卡片都没有。**
按 [排查指南](troubleshooting.md) 开头的三条命令走一遍。
最常见的两个原因是签名密钥不匹配（飞书日志里会有 `code=19021`，钉钉为 `errcode=310000`）和
数据源的服务代理缺少 topic publisher 权限（没有任何报错，就是不进消息）。

**Q：同一个告警收到了两张卡片。**
v1 的去重是**进程内**的，`max_instances=2` 时最坏会重复一次。这是已知限制，
跨实例强一致去重需要 Firestore，列入 v2。
如果是 OPEN 与 CLOSED 各一张，那是正常行为。

**Q：告警风暴时会丢消息吗？**
不会，但会排队。出口令牌桶把速率限制在所选平台的单机器人限额以内
（`MAX_SENDS_PER_MINUTE × max_instances` 飞书 ≤ 80、企业微信 / 钉钉 ≤ 16），
积压时延迟线性增长属于预期行为。调大 `max_instances` 不会提高吞吐，
只会更快触发平台限流（钉钉会因此封禁 10 分钟）。

**Q：Cloud Functions 冷启动会不会漏告警？**
不会。冷启动约 2–3 秒，Pub/Sub 会等待。
即使实例启动失败（例如 Secret Manager 故障），消息也只是堆积在订阅中（保留 7 天），
恢复后自动重投。

**Q：支持 Lark 国际版吗？**
支持。`open.feishu.cn` 与 `open.larksuite.com` 两种 webhook 都能通过校验。

**Q：能发到企业微信/钉钉/Slack 吗？**
企业微信、钉钉：支持，用 `NOTIFY_CHANNEL` 选择（每次部署一个平台），见[选择通知渠道](#选择通知渠道三选一)。
Slack 暂不支持。

**Q：能同时发到飞书和钉钉吗？**
不能，一次部署只对接一个平台（这是有意的取舍：三个路由组、限流、自检都按单平台设计）。
确有需要时，分别部署到不同项目。

---

**Q：支持用 Terraform 部署吗？**
支持，属于高级选项（适合需要用 IaC / GitOps 管理基础设施的团队），本文不展开；需要时请联系提供本方案的技术支持获取说明。

---

## 已知限制（v1）

| 限制 | 影响 | 计划 |
|-----|------|------|
| 去重是进程内的 | 最坏重复 1 次 | v2：Firestore 强一致去重 |
| 令牌桶是进程内的 | 靠 `速率 × 实例数 ≤ 80 / 16 / 16` 静态保证 | v2：分布式限流 |
| 卡片一次性发送 | 同一 incident 的更新会发多张卡 | v2：飞书自建应用，更新同一张卡片 |
| 多群路由需手工加 secret | 脚本只创建默认群 | 见排查文档 |
| 单平台部署 | 不能同时发多个 IM 平台 | 按需分项目部署 |

---

---

## 相关文档

- [创建群机器人](bot-setup.md) —— 飞书 / 企业微信 / 钉钉机器人分步创建与 Webhook 验证
- [多项目汇聚（Hub 模式）](multi-project-hub.md)
- [排查指南](troubleshooting.md) —— 收不到卡片、三渠道错误码速查、诊断命令
