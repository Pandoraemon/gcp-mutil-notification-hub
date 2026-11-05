# 排查指南

本系统的失效模式高度集中于一类：**部署显示成功、日志显示正常、但 IM 群（飞书 / 企业微信 / 钉钉）里就是没有卡片。**
下面按"从哪一步断掉"的顺序排列。各渠道的发送错误码见 [2.7 三渠道错误码速查](#27-三渠道错误码速查)。

> 下文命令里的函数名 `gcp-alerts-to-feishu`、通知渠道 `Feishu Alert Hub`、state bucket `*-gcp-feishu-tfstate`
> 是历史命名，与所选渠道无关，企业微信 / 钉钉部署照用。

---

## 目录

- [1. 部署期](#1-部署期)
  - [1.1 部署前权限预检报缺权限](#11-部署前权限预检报缺权限)
  - [1.2 冷启动失败 / 函数起不来](#12-冷启动失败--函数起不来)
- [2. 运行期收不到](#2-运行期收不到)
  - [2.1 部署成功，但完全收不到告警](#21-部署成功但完全收不到告警)
  - [2.2 PSH 事件为什么没收到](#22-psh-事件为什么没收到)
  - [2.3 预算告警为什么没发卡](#23-预算告警为什么没发卡)
  - [2.4 自检说成功，但群里没卡片](#24-自检说成功但群里没卡片)
  - [2.5 sign match fail（最常见）](#25-sign-match-fail最常见)
  - [2.6 钉钉 errcode=310000：安全设置校验失败](#26-钉钉-errcode310000安全设置校验失败)
  - [2.7 三渠道错误码速查](#27-三渠道错误码速查)
- [3. 卡片异常](#3-卡片异常)
  - [3.1 卡片来了，但严重性不对（全是 HIGH）](#31-卡片来了但严重性不对全是-high)
  - [3.2 同一个告警收到多张卡片](#32-同一个告警收到多张卡片)
  - [3.3 卡片渲染失败 / 卡片内容错乱](#33-卡片渲染失败--卡片内容错乱)
- [4. 限流与死信队列（DLQ）](#4-限流与死信队列dlq)
  - [4.1 告警风暴时消息丢失 / 限流（429 / 45009 / 130101）](#41-告警风暴时消息丢失--限流429--45009--130101)
  - [4.2 DLQ 里堆了消息](#42-dlq-里堆了消息)
- [5. 多群路由](#5-多群路由)
- [6. Terraform 相关](#6-terraform-相关)
- [7. 修改配置（configure.sh）与重跑部署](#7-修改配置configuresh与重跑部署)
- [附：日志字段速查](#附日志字段速查)

## 先做这三件事

```bash
# 部署脚本支持 --project，部署目标未必等于 gcloud 默认项目。
# 排查时显式对齐到同一个项目，否则下面的命令会打到别的项目上，查出来"什么都没有"。
export CLOUDSDK_CORE_PROJECT=YOUR_PROJECT_ID
PROJECT_ID="${CLOUDSDK_CORE_PROJECT}"
REGION=asia-east1

# 1. 函数最近有没有报错
gcloud logging read \
  'resource.labels.service_name="gcp-alerts-to-feishu" AND severity>=WARNING' \
  --freshness=1h --limit=20 --format='table(timestamp, jsonPayload.message, jsonPayload.reason)'

# 2. 消息到底有没有进主题（有则说明数据源侧是通的）
gcloud pubsub topics list-subscriptions gcp-alerts-hub

# 3. DLQ 里有没有堆积
gcloud pubsub subscriptions pull gcp-alerts-dlq-sub --limit=5 --format=json
```

第 1 步没有任何日志 = 函数根本没被触发（问题在数据源或订阅）；
有日志但没有 `Alert delivered` = 消息被主动丢弃了（看 `jsonPayload.reason`）；
有 ERROR = 直奔对应小节。

---

## 1. 部署期

### 1.1 部署前权限预检报缺权限

两条部署脚本在启用 API 之前会用 `projects:testIamPermissions` 只读探测 8 项权限，输出形如：

```
⚠️  部署者 user:someone@example.com 缺少 2 项权限（探测结果偏保守：组/条件绑定可能未计入）：
    - resourcemanager.projects.setIamPolicy（roles/resourcemanager.projectIamAdmin）
    - monitoring.alertPolicies.create（roles/monitoring.alertPolicyEditor）
    补救（需项目 IAM 管理员执行，之后等约 60 秒再重跑）：
    gcloud projects add-iam-policy-binding PROJECT --member="user:someone@example.com" --role=roles/resourcemanager.projectIamAdmin && gcloud projects add-iam-policy-binding PROJECT --member="user:someone@example.com" --role=roles/monitoring.alertPolicyEditor

    继续的话，缺权限的步骤会被跳过并在结尾列出，核心链路可能不完整。
```

- 交互模式会问是否继续；`--yes` / 非 TTY 只打印不阻塞。
- `--member=` 按 `gcloud config get-value account` 自动解析；WIF `principal://` 身份或想替别人生成命令时，
  设 `DEPLOYER_MEMBER='principal://...'` 环境变量覆盖。
- 探测**偏保守**：通过组、条件绑定、自定义角色获得的权限可能不计入。预检失败不等于部署一定失败，
  可以继续跑，以结尾的跳过清单为准；预检通过也不等于一定成功（例如 `iam.serviceAccountUser` 不在探测范围内）。
- 没有 curl / 拿不到 access token / HTTP 非 2xx（`cloudresourcemanager` API 未启用、CBA、代理）只 WARNING，预检被跳过。

---

### 1.2 冷启动失败 / 函数起不来

```bash
gcloud functions logs read gcp-alerts-to-feishu --region=asia-east1 --limit=50
```

常见原因：

| 日志关键字 | 原因 | 修复 |
|-----------|------|------|
| `ConfigError: NOTIFY_CHANNEL 非法: 'xxx'，可选 ['feishu', 'wecom', 'dingtalk']` | 渠道名拼错 | 改成三者之一（未设置 = feishu） |
| `ConfigError: FEISHU_DEFAULT_WEBHOOK 与 FEISHU_DEFAULT_SECRET 为必填项，请检查 --set-secrets 是否正确挂载` | Secret 没挂上（企微为 `WECOM_DEFAULT_WEBHOOK 为必填项…`，钉钉为 `DINGTALK_DEFAULT_WEBHOOK 与 DINGTALK_DEFAULT_SECRET 为必填项…`） | 检查 `--set-secrets` 与 SA 的 accessor 权限；切换过渠道时确认挂载的是**新渠道**的 Secret |
| `ConfigError: FEISHU_DEFAULT_WEBHOOK 与 FEISHU_DEFAULT_SECRET 必须成对配置` | 只配了一个；或密钥为空串 | 未开签名校验时必须显式填 `NONE`（钉钉同理） |
| `ConfigError: FEISHU_SECURITY_WEBHOOK 与 FEISHU_SECURITY_SECRET 必须成对配置` | 只配了一个 | 两个都配，或都删掉 |
| `ConfigError: FEISHU_DEFAULT_WEBHOOK 必须以 https://open.feishu.cn/ 或 https://open.larksuite.com/ 开头，当前值前缀: '...'` | Secret 里写进了别的 URL（复制错、带了前导空格、填成了群链接） | 重跑部署脚本重新输入 webhook，或 `secrets versions add` 后滚动一次；日志只回显前 40 字符，不会泄露 token |
| `ConfigError: WECOM_DEFAULT_WEBHOOK 必须以 https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key= 开头，当前值前缀: '...'` | 企微 webhook 前缀不符 | 同上 |
| `ConfigError: DINGTALK_DEFAULT_WEBHOOK 必须以 https://oapi.dingtalk.com/robot/send?access_token= 开头，当前值前缀: '...'` | 钉钉 webhook 前缀不符（例如把飞书 webhook 留在了钉钉 Secret 里） | 同上 |
| `ConfigError: SOURCE_MIN_SEVERITY 格式错误` / `非法级别` / `未知来源` | 填写的 `SOURCE_MIN_SEVERITY` 包含不能识别的 key（不是 monitoring/service_health/billing/scc）、级别错误，或格式不是 key=value;... | 重跑部署脚本，清空或输入合法格式，如 `monitoring=HIGH;billing=OFF` |
| `PERMISSION_DENIED` on secret | SA 缺 accessor | 见下 |

部署脚本在更早的阶段就会做更严格的格式校验（不建任何资源就退出 1），例如：

```
错误：无效的企业微信 Webhook URL。应形如
  https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
（在群聊 → 群机器人 / 消息推送 → 添加机器人后复制；不要带多余参数或空格）

错误：无效的钉钉 Webhook URL。应形如
  https://oapi.dingtalk.com/robot/send?access_token=xxxxxxxx
（不要把 &timestamp=…&sign=… 拼进来：签名由函数在每次发送时实时计算）

错误：钉钉加签密钥不能为空。未开启加签请显式输入 NONE。
```

启动成功时会有一条 `Config loaded` INFO（结构化 JSON，含 `channel` / `min_severity` / `kill_switch` / `pause_mode` /
`self_project_id` 等），用它核对实际生效的配置，比 `functions describe` 更接近真相。

```bash
# Secret 名按渠道替换：feishu-default-webhook / wecom-default-webhook / dingtalk-default-webhook ...
gcloud secrets add-iam-policy-binding feishu-default-webhook \
  --member="serviceAccount:gcp-alerts-fn@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role=roles/secretmanager.secretAccessor
```

> Secret Manager 故障时**没有降级路径**：`--set-secrets` 在实例启动时解析，
> 保留明文环境变量副本会违背"无硬编码密钥"。此时实例启动失败，
> 消息会堆积在订阅中（保留 7 天），恢复后自动重投 —— 消息不会丢。

---

## 2. 运行期收不到

### 2.1 部署成功，但完全收不到告警

按数据流顺序逐段排除。

#### 消息有没有进 topic

```bash
# 手工发一条自检消息，绕过所有数据源
gcloud pubsub topics publish gcp-alerts-hub \
  --message="{\"type\":\"test_event\",\"project_id\":\"${PROJECT_ID}\",\"deployment_time\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}"
```

收到卡片 → topic 到 IM 群这一段是好的，问题在数据源接入（看 2.2）。
没收到 → 继续往下。

#### 数据源的服务代理有没有 publisher 权限

**这是"静默无告警"的头号根因。** 每个数据源用不同的服务代理投递，
漏授权时 GCP 不会报错，消息就是进不来。

```bash
PROJECT_NUMBER=$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)')
gcloud pubsub topics get-iam-policy gcp-alerts-hub
```

应当能看到（按启用的数据源）：

| 数据源 | 必须存在的成员 |
|--------|--------------|
| Cloud Monitoring | `service-${PROJECT_NUMBER}@gcp-sa-monitoring-notification.iam.gserviceaccount.com` |
| SCC | `service-org-${ORG_ID}@gcp-sa-scc-notification.iam.gserviceaccount.com` |
| Billing | `billing-budgets-pubsub@system.gserviceaccount.com` |

缺失就补：

```bash
gcloud beta services identity create --service=monitoring.googleapis.com   # 先确保 SA 存在
gcloud pubsub topics add-iam-policy-binding gcp-alerts-hub \
  --member="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-monitoring-notification.iam.gserviceaccount.com" \
  --role=roles/pubsub.publisher
```

> 服务代理是**懒创建**的。对尚不存在的 SA 做绑定会失败，或写入一条永不生效的绑定 ——
> 后者尤其阴险：`get-iam-policy` 里看得到，实际却不工作。
> 所以一定要先 `services identity create`。

#### 告警策略有没有绑到通知渠道

```bash
gcloud beta monitoring policies list --format='table(displayName, notificationChannels)'
```

`notificationChannels` 为空 = 策略创建成功了但**永远不会发通知**。
gcloud 路径下最常见的原因是 `CHANNEL_ID` 没 export，`envsubst` 没替换成功。
部署脚本已内置 `grep '\${'` 断言来拦截这种情况；手工建的策略需要自己检查。

补绑：
```bash
CHANNEL=$(gcloud beta monitoring channels list \
  --filter="displayName='Feishu Alert Hub'" --format='value(name)')
gcloud beta monitoring policies update POLICY_ID --set-notification-channels="${CHANNEL}"
```

#### 函数是不是被软开关关掉了

```bash
gcloud functions describe gcp-alerts-to-feishu --region=asia-east1 --gen2 \
  --format='value(serviceConfig.environmentVariables)'
```

`KILL_SWITCH=true` 或 `PAUSE_MODE=true` → 有人（也许是你自己）执行过 `emergency-disable.sh`，
或者有人以 `KILL_SWITCH=true` / `PAUSE_MODE=true` 重跑了部署脚本 / 用 `configure.sh --section=switches` 打开了开关
（Terraform 路径会体现在 `terraform.tfvars` 的 `kill_switch` / `pause_mode = true`）。

```bash
./scripts/emergency-enable.sh --region=asia-east1
```

反过来的情况也要知道：**急停不是持久配置**。`emergency-*.sh` 直接改底层 Cloud Run 服务的环境变量，
下一次 `deploy-gcloud.sh` / `deploy-terraform.sh` / `terraform apply` 会把两个开关复位（未显式提供时都是 `false`）——
急停期间重部署 = 恢复转发。部署脚本在线上为 true 时会打印醒目 WARNING 提醒，但仍会复位。
要持久急停：`KILL_SWITCH=true ./deploy-*.sh`，或 `./scripts/configure.sh --section=switches`（向导里回车 = 保持急停）。
`deploy-terraform.sh` 每次按环境变量重写 tfvars 的 `kill_switch` / `pause_mode`，只改 tfvars 仅对直接 `terraform apply` 有效。

#### 告警是不是被 MIN_SEVERITY 过滤了

日志里会有明确记录：

```bash
gcloud logging read \
  'resource.labels.service_name="gcp-alerts-to-feishu" AND jsonPayload.reason="severity_filtered"' \
  --freshness=1h --limit=10 --format='value(jsonPayload.severity, jsonPayload.min_severity, jsonPayload.source, jsonPayload.threshold, jsonPayload.rule)'

# 因按来源规则设为 OFF 被过滤的告警：
gcloud logging read \
  'resource.labels.service_name="gcp-alerts-to-feishu" AND jsonPayload.reason="source_disabled"' \
  --freshness=1h --limit=10 --format='value(jsonPayload.source, jsonPayload.dedup_key)'
```

默认 `MIN_SEVERITY=MEDIUM` 会丢掉 LOW 与 INFO。调整：

```bash
./scripts/configure.sh --section=filter            # 推荐：走部署脚本，Terraform 模式同样适用
# 或 gcloud 路径临时调整：
gcloud functions deploy gcp-alerts-to-feishu --region=asia-east1 --gen2 \
  --update-env-vars=MIN_SEVERITY=LOW
```

手工改的 `MIN_SEVERITY` / `LOG_LEVEL` 在下次重跑部署脚本时会被沿用（打印「沿用线上配置：…」），不再被回退为默认值。

---

### 2.2 PSH 事件为什么没收到

如果是**刚新建**或**刚接入 Hub** 的源项目：
由于 Google 后台的就绪延迟，源项目在首次启用 `servicehealth.googleapis.com` API 之后，通常需要等待 **1.5 到 2 小时** 才会开始将 PSH 真实日志输送到 `servicehealth.googleapis.com/activity`。在此期间发生的服务健康事件可能无法通过日志型策略转化为告警。

另外，PSH 真实事件日志记录在 `%2Factivity`，而不是早先版本的 `%2Fevent_log`，且 `category` 只有 `INCIDENT`（没有计划维护或安全公告等类别）。如果手工发送合成测试消息，必须遵循这些 schema 特征。

---

### 2.3 预算告警为什么没发卡

GCP 预算每天会多次向 Pub/Sub 推送**状态消息**，只有真正突破阈值时才带 `alertThresholdExceeded`
（或预测突破时带 `forecastThresholdExceeded`）。两者都缺失的消息不是告警，函数会以 INFO 记
`reason="budget_status_no_threshold"` 后 ack，**不发卡**（旧版本会把它当成 HIGH 卡刷屏）。

```bash
gcloud logging read \
  'resource.labels.service_name="gcp-alerts-to-feishu" AND jsonPayload.reason="budget_status_no_threshold"' \
  --freshness=24h --limit=5 --format='value(timestamp, jsonPayload.detail)'
```

有这条日志 = 链路是通的，只是预算还没突破。真突破后，同一阈值在同一预算周期内只发一张卡
（`dedup_key` 带 `costIntervalStart`，下一周期再次突破会重新发）。

---

### 2.4 自检说成功，但群里没卡片

自检的判定条件是函数日志里出现
`jsonPayload.message="Alert delivered" AND jsonPayload.alert_type="test_event" AND timestamp>=<自检开始-60s>`，
它无法验证卡片是否真的出现在群里（三个 IM 平台都不提供这个回执）。部署脚本的结论按渠道显示
「飞书群 / 企业微信群 / 钉钉群应已收到卡片：🟢 [GCP 监控告警中心] 连通性自检成功」。日志无错误 + 群里没卡片，按概率排：

1. **签名密钥不匹配** → 见第 1 节 / 1.5 节（但这种情况会有 ERROR 日志，飞书 `jsonPayload.feishu_code=19021`，钉钉 `jsonPayload.platform_code=310000`）；
2. **机器人被移出群** → 飞书日志会有 `feishu code=9499: bot not in chat`（`jsonPayload.feishu_code=9499`）；
   企业微信为 `errcode=93000` / `93008`，钉钉为 `300001` / `300005`（`jsonPayload.platform_code`）；
3. **webhook 指向了另一个群** → 检查 secret 的最新版本，并确认函数已拉过新 revision（见第 1 节末尾）：
   ```bash
   # 按渠道替换：feishu-default-webhook / wecom-default-webhook / dingtalk-default-webhook
   gcloud secrets versions access latest --secret=feishu-default-webhook
   ```
4. **函数实际跑的渠道不是你以为的那个**（例如切换渠道后没重新部署成功）→ 看 `Config loaded` 或 `Alert delivered` 里的 `jsonPayload.channel`；
5. **消息被自检以外的逻辑丢弃** → 查 `jsonPayload.reason`：
   ```bash
   gcloud logging read 'jsonPayload.alert_type="test_event"' --freshness=10m \
     --format='value(timestamp, jsonPayload.message, jsonPayload.reason)'
   ```

自检本身的两种快速失败：自检消息发布失败（部署者无 `pubsub.publisher`）会立即报错并给补救命令，
不再空等 150 秒；403 诊断查的是实际触发器身份（gcloud 路径 = `--trigger-service-account` 指定的函数 SA，回落时为默认 compute SA）。

---

### 2.5 sign match fail（最常见）

> 本节针对飞书。钉钉的同类问题（`errcode=310000`）见 [2.6](#26-钉钉-errcode310000安全设置校验失败)；企业微信没有签名。

**症状**：日志里有 `feishu code=19021: sign match fail`，或者日志毫无异常但群里没卡片。

飞书的签名校验失败返回的是 **HTTP 200 + `{"code": 19021}`**。
如果你的排查工具只看状态码，会认为一切正常 —— 本系统会校验响应体，
所以这个错误一定会出现在 ERROR 日志里。

**原因与对策**：

| 原因 | 判断方法 | 修复 |
|-----|---------|------|
| 密钥填错/复制时带了空格 | 最常见 | 重跑部署脚本，重新输入密钥 |
| 机器人**没开**签名校验，却配了密钥 | 飞书群机器人设置里看"签名校验"开关 | 密钥填 `NONE` |
| 机器人**开了**签名校验，密钥填了 `NONE` | 同上 | 填真实密钥 |
| 改了机器人密钥但没更新 Secret | `gcloud secrets versions list feishu-default-secret` 看最新版本时间 | 重跑部署脚本 |

```bash
# 只更新密钥（不重新部署整个函数）
printf '%s' 'YOUR_NEW_SECRET' | gcloud secrets versions add feishu-default-secret --data-file=-
# 函数用的是 :latest，但已运行的实例不会自动刷新，需要滚动一次
gcloud functions deploy gcp-alerts-to-feishu --region=asia-east1 --gen2 \
  --update-env-vars=SECRET_ROLLED_AT="$(date -u +%s)"
```

> 换 webhook 同理，而且 **Terraform 路径也一样**：`deploy-terraform.sh` 只往 Secret 追加版本，
> Terraform 侧没有 diff，不会拉新 revision；老实例继续用旧值直到缩容为 0 ——
> 自检可能发到**旧群**并判成功。要立即生效，改任一 env 值（如上）或重新部署源码。
> 更省事的做法：`./scripts/configure.sh --section=channel` 选「输入新凭据」（写入新版本并强制拉新 revision）；
> 若已经用 `gcloud secrets versions add` 换了值，直接运行 `./scripts/configure.sh`，在「无变化」处选择强制重启即可，
> 见[第 7 节](#7-修改配置configuresh与重跑部署)。

> 签名算法细节：key = `"{timestamp}\n{secret}"`，message = **空字节串**，HMAC-SHA256 后 base64。
> 这个"用密钥当 key、拿空串当消息"的用法很反直觉，自己实现时极易写反。

---

### 2.6 钉钉 errcode=310000：安全设置校验失败

**症状**：`jsonPayload.reason="permanent_send_failure" AND jsonPayload.channel="dingtalk" AND jsonPayload.platform_code=310000`，
日志文案形如 `dingtalk errcode=310000: 安全设置校验失败（sign not match / keywords not in content / ip not in whitelist）`。
钉钉同样返回 **HTTP 200**，函数按永久失败 ack + ERROR，不进 DLQ。

钉钉机器人的三种安全设置任一不满足都会报 310000，按机器人实际开启的项逐一排查：

| 原因 | 判断方法 | 修复 |
|-----|---------|------|
| **加签不符**：`DINGTALK_SECRET` 与机器人密钥不一致 / 复制时带了空格 / 机器人开了加签却填了 `NONE` | 钉钉群 → 机器人设置 → 安全设置看是否勾了「加签」，对比 `gcloud secrets versions access latest --secret=dingtalk-default-secret` 的前几位 | 重跑部署脚本重新输入（脚本会拒绝含空白的密钥，不以 `SEC` 开头会 WARNING），或 `secrets versions add` 后滚动一次 |
| **加签不符**：webhook 里自己拼了 `&timestamp=…&sign=…` | `gcloud secrets versions access latest --secret=dingtalk-default-webhook` 看是否只有 `?access_token=` | 只保留 `https://oapi.dingtalk.com/robot/send?access_token=xxx`，签名由函数每次实时计算（部署脚本的正则会拦这种输入，手工写 Secret 时才会出现） |
| **加签不符**：函数所在环境时钟偏差 > 1 小时 | 极少见（Cloud Functions 时钟由平台同步） | — |
| **关键词不符**：开了「自定义关键词」但关键词不是 `GCP告警` | 安全设置里看关键词列表 | 把关键词改成（或加上）`GCP告警`；卡片 title 固定以 `GCP告警` 开头，正文首行也含它 |
| **IP 不符**：开了「IP 地址（段）」 | 安全设置里看 IP 列表 | 函数默认出口 IP 不固定，**不建议单独使用 IP 白名单**；改用加签，或自行配置固定出口（Serverless VPC Access + Cloud NAT 静态 IP）后再把该 IP 加进去 |

```bash
# 只更新钉钉加签密钥并滚动一次
printf '%s' 'SECxxxxxxxx' | gcloud secrets versions add dingtalk-default-secret --data-file=-
gcloud functions deploy gcp-alerts-to-feishu --region=asia-east1 --gen2 \
  --update-env-vars=SECRET_ROLLED_AT="$(date -u +%s)"
```

> 钉钉签名与飞书**正好相反**：`HmacSHA256(key=secret, msg="{毫秒时间戳}\n{secret}")` → Base64 → urlencode，
> 以 `timestamp` / `sign` query 参数追加到 webhook；飞书是 key=`"{秒级时间戳}\n{secret}"`、消息为空串、签名放请求体。

---

### 2.7 三渠道错误码速查

三个平台业务失败时都返回 **HTTP 200**，错误码在响应体里（飞书 `code`、企业微信 / 钉钉 `errcode`），0 才是成功。
分类规则（`src/channels/base.py` 的 `classify_errcode_response` 与各渠道 `webhook_sender.py`）：

- **Permanent**（永久）：重试不可能改变结果 → 立即抛出，`main.py` ack + ERROR `reason=permanent_send_failure`，**不进 DLQ**；
- **Transient**（瞬时）：函数内最多 3 次尝试（间隔约 1 / 2 秒 + 抖动，每次尝试各取 1 个令牌），仍失败则 nack → Pub/Sub 重投 → 5 次后进 DLQ；
- 三渠道共同的 HTTP 层规则：429 / 5xx / 200 但响应体非 JSON 或不是 JSON 对象 / 网络错误 → Transient；**其它非 200（4xx）→ Permanent**；
- **未列出的错误码一律 Transient**：最坏结果是多重试几次后进 DLQ（可重放），而不是把告警静默 ack 掉。

**飞书/Lark**（`code`）：

| code | 含义 | 分类 |
|------|------|------|
| 19001 | webhook token 无效 | Permanent |
| 19021 | sign match fail（签名不匹配，见第 1 节） | Permanent |
| 19024 | invalid timestamp（时钟偏移过大） | Permanent |
| 9499 | bot not in chat（机器人被移出群） | Permanent |
| 其它非 0 | — | Transient |

**企业微信**（`errcode`，来源：[全局错误码](https://developer.work.weixin.qq.com/document/path/90313)、[消息推送配置说明](https://developer.work.weixin.qq.com/document/path/91770)）：

| errcode | 含义 | 分类 |
|---------|------|------|
| 93000 | webhook url 不合法或机器人已被移出群 | Permanent |
| 93001 | 当前群聊不允许推送消息 | Permanent |
| 93004 | 消息推送被停用 | Permanent |
| 93008 | 机器人不在群里 | Permanent |
| 93017 | 请求内容不能为空 | Permanent |
| 40008 / 40035 / 40058 / 40063 | 不合法的 msgtype / 参数 / 参数为空 | Permanent |
| 40039 | 不合法的 url 长度（上限 1024 字节） | Permanent |
| 44004 / 45002 | content 为空 / 消息内容大小超过限制 | Permanent |
| 42030 / 42031 / 42033 / 42035 | template_card 缺失 url / card_type 不合法 / 缺失 title / horizontal_content_list 长度不合法 | Permanent |
| 45009 | 接口调用超过限制（20 条/分钟，约 1 分钟后自动解除） | Transient |
| -1 | 系统繁忙 | Transient |

**钉钉**（`errcode`；钉钉开放平台错误码页为前端渲染，下列取值来自公开资料与社区实测，**待官方页面二次确认**）：

| errcode | 含义 | 分类 |
|---------|------|------|
| 310000 | 安全设置校验失败：加签 / 关键词 / IP 不符（见 1.5） | Permanent |
| 300001 | access_token 不存在或机器人已被删除 | Permanent |
| 300005 | token is not exist（webhook token 无效） | Permanent |
| 40035 | 缺少参数 json（请求体非法） | Permanent |
| 43004 | 无效的 HTTP HEADER Content-Type | Permanent |
| 130101 | 发送太快（20 条/分钟），触发后**封禁约 10 分钟** | Transient，**不做函数内重试**（见第 6 节） |
| -1 | 系统繁忙 | Transient |

按渠道 + 错误码过滤：

```bash
gcloud logging read \
  'resource.labels.service_name="gcp-alerts-to-feishu" AND jsonPayload.reason="permanent_send_failure" AND jsonPayload.platform_code=93000' \
  --freshness=24h --limit=10 --format='value(timestamp, jsonPayload.channel, jsonPayload.error)'
```

`platform_code` 三渠道通用；飞书日志另保留 `feishu_code`（同值），存量过滤器 `jsonPayload.feishu_code=19021` 继续可用。

---

## 3. 卡片异常

### 3.1 卡片来了，但严重性不对（全是 HIGH）

这是**有意的行为**（ADR-004）：未知或缺失的 severity 一律 fail-open 到 `HIGH`。

Cloud Monitoring 的 `severity` **只有在告警策略里显式配置了才存在**。
没配的策略，其告警一律按 HIGH 处理。

```bash
# 找出所有 fail-open 的记录，看看原始值是什么
gcloud logging read \
  'jsonPayload.message="Unknown severity, failing open to HIGH"' \
  --freshness=24h --limit=20 --format='value(jsonPayload.source, jsonPayload.raw_severity)'
```

如果 `raw_severity` 是个映射表里没有的合法取值，说明映射表有缺口 ——
往 `src/parsers/severity.py` 的 `_MAPS` 里补一行即可。

如果是空的，去告警策略里配上 severity。

---

### 3.2 同一个告警收到多张卡片

| 张数 | 原因 | 说明 |
|-----|------|------|
| 2 张 | 跨实例去重失效 | v1 的去重是**进程内**的，`max_instances=2` 时最坏重复一次。已知限制，v2 用 Firestore 解决 |
| 2 张（OPEN + CLOSED） | 正常行为 | `dedup_key` 含 `state`，故障开始与恢复各发一次 |
| 很多张 | 告警策略配了多个通知渠道，或建了重复的策略/预算 | 见下 |

```bash
# 查重复的告警策略（gcloud 路径下老版本脚本可能建过多条）
gcloud beta monitoring policies list --format='table(name, displayName)' \
  | grep 'Service Health'
# 查重复的 Billing 预算
gcloud billing budgets list --billing-account=BILLING_ACCOUNT_ID \
  --format='table(name, displayName)'
```

当前版本的部署脚本对这两者都做了"先查后 update"的幂等处理；
如果历史上跑过老版本，需要手工删掉多余的。

---

### 3.3 卡片渲染失败 / 卡片内容错乱

日志里出现 `Card template rendering failed`（`reason=render_failed`，extra 含 `alert_type` / `template` / `error`）
或 `feishu code=` 其它非 0 值。企业微信 / 钉钉渲染器不用模板，渲染失败时先记 `WeCom card rendering failed` /
`DingTalk card rendering failed`（extra 含 `alert_type` / `error`），再由 `main.py` 以 `reason=render_failed`（带 `channel`）ack。

渲染失败一律是 **ack + ERROR，不进 DLQ**：`template.render()` 抛出的 `jinja2.TemplateError`
（含 `StrictUndefined` 的 `UndefinedError`：模板引用了 `ParsedAlert` 没有的字段）、`TypeError`、`ValueError`
都归为 PermanentError —— 模板问题重试一万次也不会变好。看 `jsonPayload.template` 与 `jsonPayload.error` 即可定位。

JSON 非法的情况（告警文本里含引号、换行、反斜杠）理论上不会出现，因为飞书模板的所有插值都走 `| tojson`
（企业微信 / 钉钉直接构造 dict，由 `requests` 序列化）——
若真出现了，说明有模板漏了转义：

```bash
grep -rn '{{' src/channels/feishu/templates/ | grep -v 'tojson'
```

输出应当为空（除了 `{% %}` 控制结构）。
注意 `tojson` **自带外层引号**，写成 `"{{ x | tojson }}"` 会渲染出双层引号，同样是非法 JSON。

**卡片字段不再加粗、链接不可点**：这是有意的。来自告警数据的字段（标题 / 字段名 / 字段值 / 时间）
全部以纯文本渲染，告警策略文档或 SCC 描述里的 `[文案](url)`、`<at id=all>` 不会生效：
飞书用 `plain_text`；企业微信只放进 `template_card` 的纯文本字段（超长截断、放不下的字段拼进 `sub_title_text`）；
钉钉把 `[ ] < > *` 换成全角 `［ ］ ＜ ＞ ＊`、换行折叠为空格。两者的裸 URL 都会显示成 `https[:]//…`（去活，防钓鱼），不是乱码。
「查看详情」按钮的 URL 只接受 `https://console.cloud.google.com/` 与 `https://cloud.google.com/` 前缀，
不满足时记 WARNING `reason=console_url_rejected`（extra 带 `url_prefix`）并回落到该数据源的默认控制台链接 —— 按钮不会消失
（企业微信 / 钉钉另对超过 1024 字节的 URL 回落到 `https://console.cloud.google.com/`）。

企业微信卡片收到 `errcode=42035`（`horizontal_content_list` 长度不合法）或 `42033`（缺 title）说明渲染器的字段约束被破坏，
属于代码缺陷 —— 按永久失败 ack，请带上 `jsonPayload.alert_type` 提 issue。

---

## 4. 限流与死信队列（DLQ）

### 4.1 告警风暴时消息丢失 / 限流（429 / 45009 / 130101）

各平台单机器人限流与本系统的默认值：

| 渠道 | 平台限流 | 超限表现 | 默认 `MAX_SENDS_PER_MINUTE` | 约束 `MAX_SENDS_PER_MINUTE × max_instances ≤` |
|-----|---------|---------|---------------------------|---------------------------------------------|
| 飞书/Lark | 约 100 次/分钟 | HTTP 429 | 40 | 80 |
| 企业微信 | 20 条/分钟 | `errcode=45009`，约 1 分钟解除 | 8 | 16 |
| 钉钉 | 20 条/分钟 | `errcode=130101`，**封禁约 10 分钟** | 8 | 16 |

默认 `40 × 2 = 80` / `8 × 2 = 16`。改了其中一个就要同步检查另一个。
Terraform 路径下这个约束写成了 `precondition`，违反时 `terraform plan` 直接失败（报错会打印渠道、实际速率、实例数与上限）。

**部署脚本提前退出**：两条部署脚本在创建任何资源之前做同样的校验，超限时直接退出 1，输出形如：

```
❌ 发送速率超出 钉钉 群机器人限额：MAX_SENDS_PER_MINUTE(40) × MAX_INSTANCES(2) = 80 > 16。
   超限的消息会被平台拒绝（钉钉超限会封禁 10 分钟）。请调低 MAX_SENDS_PER_MINUTE（钉钉 默认 8）或 MAX_INSTANCES；
   若是从其它渠道切换过来，请 unset MAX_SENDS_PER_MINUTE 以使用渠道默认值。
```

最常见的触发方式是：shell 里残留了飞书时代的 `MAX_SENDS_PER_MINUTE=40`（gcloud 路径以前写死 40，现在会读这个环境变量），
再切到企业微信 / 钉钉。`unset MAX_SENDS_PER_MINUTE` 后重跑即可。Terraform 路径的同类陷阱是 tfvars 里显式写了
`max_sends_per_minute = 40`：删掉该行（回到 `null`，按渠道推导）。

```bash
gcloud functions describe gcp-alerts-to-feishu --region=asia-east1 --gen2 \
  --format='value(serviceConfig.maxInstanceCount, serviceConfig.environmentVariables.MAX_SENDS_PER_MINUTE, serviceConfig.environmentVariables.NOTIFY_CHANNEL)'
```

函数启动时若单实例速率就超过平台单机器人限额（100 / 20 / 20），不会拒绝启动，但会记 WARNING
`reason=rate_exceeds_platform_limit`（extra 带 `channel` / `max_sends_per_minute` / `platform_limit_per_minute`）。

**钉钉 130101：不在函数内重试**。130101 会封禁约 10 分钟，函数内 1 / 2 秒的退避重试必然再失败，只会白耗令牌、拉长函数执行时间。
所以钉钉 sender 遇到 130101 直接抛 `TransientError`，记一条 WARNING
`Transient failure not retried in-process, deferring to Pub/Sub redelivery`（带 `channel` / `platform_code`），
然后 nack 交给 Pub/Sub 指数退避重投。钉钉渠道部署时订阅侧默认设置 `min-retry-delay=80s`（5 次投递跨度约 19 分钟，能够有效覆盖 10 分钟封禁期以自动恢复），仅在持续超限或告警风暴严重堆积时才进入 DLQ。这属于预期保护机制，消息没有丢失：

```bash
# 1. 确认是 130101 导致的
gcloud logging read \
  'resource.labels.service_name="gcp-alerts-to-feishu" AND jsonPayload.channel="dingtalk" AND jsonPayload.platform_code=130101' \
  --freshness=1h --limit=10 --format='value(timestamp, jsonPayload.message)'
# 2. 等封禁解除（距最后一条 130101 至少 10 分钟），并确认风暴已过去、速率配置没超 16
# 3. 再重放 DLQ（消息重新投回主 topic，仍受令牌桶 8 条/分钟/实例约束，不会再次打爆限额）
./scripts/replay-dlq.sh
```

封禁未解除就重放，消息会再次 130101 并回到 DLQ（`replay_count` 递增，超过 `MAX_REPLAY_COUNT=2` 会被丢弃）。

**注意**：调大 `max_instances` 不会提高吞吐，只会让你更快触发平台限流。
风暴时延迟线性增长是预期行为（令牌桶在排队），不是故障。企业微信 / 钉钉单机器人只有 20 条/分钟，
大规模告警建议提高 `MIN_SEVERITY` 或把 SCC / Billing 分流到独立机器人（见第 10 节）。

---

### 4.2 DLQ 里堆了消息

```bash
./scripts/replay-dlq.sh          # 交互式：预览 → 归还租约 → 确认 → 重新拉取 → 重放
```

脚本先预览 pull 并**立即** `modify-ack-deadline=0` 归还租约，人工确认后重新 pull（拿新鲜 ackId），
publish 成功后才 ack。实际重放集合以重新拉取为准，可能与预览略有出入。

**重放前先修根因**，否则消息会立刻回到 DLQ。脚本会检测函数最近 10 分钟的 ERROR 日志并警告。

DLQ 里**只会**出现两种消息：瞬时发送失败重试耗尽（IM 平台 5xx / 429 / 超时、企业微信 `45009`、钉钉 `130101` 等持续超过 5 次投递）、
`PAUSE_MODE` 期间被 nack 的消息。畸形消息、模板渲染失败、签名错等永久性失败都是 ack + ERROR，不进 DLQ ——
如果 DLQ 里出现了明显畸形的消息，说明是旧版本函数留下的，重放前先确认已部署新版本。

看消息为什么失败：

```bash
gcloud pubsub subscriptions pull gcp-alerts-dlq-sub --limit=1 --format=json \
  | jq -r '.[0].message.data' | base64 -d | jq .
```

重放的消息带 `replayed=true` 与递增的 `replay_count` 属性。
`replay_count > 2` 时函数会直接丢弃并记 ERROR —— 这是为了阻断
"DLQ → 重放 → 再入 DLQ"的死循环。真要突破，先修好根因再改 `MAX_REPLAY_COUNT`。

如果配置了 `OPS_EMAIL` / `ops_email`，DLQ 积压超过 10 分钟会由 `GCP Alerts Hub - DLQ Backlog` 策略发邮件
（见 [architecture.md · 监控的监控](architecture.md#监控的监控自监控)）。

#### DLQ 是空的，但消息确实丢了

检查死信策略到底挂上了没有：

```bash
SUB=$(gcloud eventarc triggers describe gcp-alerts-to-feishu --location=asia-east1 \
  --format='value(transport.pubsub.subscription)')
gcloud pubsub subscriptions describe "${SUB##*/}" --format='yaml(deadLetterPolicy, retryPolicy)'
```

`deadLetterPolicy` 为空 = 失败消息只会重试到过期然后消失。
重跑部署脚本会重新挂载（**函数每次重新部署都可能重建触发器订阅**，所以这一步不是一次性的）。

还要确认函数是以 `--retry` 部署的：

```bash
gcloud eventarc triggers describe gcp-alerts-to-feishu --location=asia-east1 \
  --format='value(eventDataContentType, destination)'
gcloud functions describe gcp-alerts-to-feishu --region=asia-east1 --gen2 \
  --format='value(eventTrigger.retryPolicy)'
# 期望：RETRY_POLICY_RETRY
```

`RETRY_POLICY_DO_NOT_RETRY` = 抛异常等于 ack 丢弃，死信策略永远不会触发。

---

## 5. 多群路由


部署脚本默认只创建默认群的 secret。SCC → 安全群、Billing → 财务群需要手工追加。

```bash
# 与部署时 --project 选定的项目保持一致
export CLOUDSDK_CORE_PROJECT=YOUR_PROJECT_ID
PROJECT_ID="${CLOUDSDK_CORE_PROJECT}"
FN_SA="gcp-alerts-fn@${PROJECT_ID}.iam.gserviceaccount.com"

for pair in "feishu-security-webhook:https://open.feishu.cn/open-apis/bot/v2/hook/SEC_TOKEN" \
            "feishu-security-secret:SEC_SIGN_SECRET" \
            "feishu-billing-webhook:https://open.feishu.cn/open-apis/bot/v2/hook/BIL_TOKEN" \
            "feishu-billing-secret:NONE"; do
  name="${pair%%:*}"; value="${pair#*:}"
  printf '%s' "${value}" | gcloud secrets create "${name}" \
    --replication-policy=automatic --data-file=- 2>/dev/null \
    || printf '%s' "${value}" | gcloud secrets versions add "${name}" --data-file=-
  gcloud secrets add-iam-policy-binding "${name}" \
    --member="serviceAccount:${FN_SA}" --role=roles/secretmanager.secretAccessor >/dev/null
done

gcloud functions deploy gcp-alerts-to-feishu --region=asia-east1 --gen2 \
  --update-secrets="\
FEISHU_SECURITY_WEBHOOK=feishu-security-webhook:latest,\
FEISHU_SECURITY_SECRET=feishu-security-secret:latest,\
FEISHU_BILLING_WEBHOOK=feishu-billing-webhook:latest,\
FEISHU_BILLING_SECRET=feishu-billing-secret:latest"
```

**webhook 与 secret 必须成对配置**，只配一个函数会启动失败（这是有意的：
半配置的分群会让告警发到一个签名永远校验失败的地方，比不配更糟）。
不需要签名的机器人，其 secret 填 `NONE`。

企业微信 / 钉钉部署同理，只是变量名换成所选渠道的前缀（函数只读 `NOTIFY_CHANNEL` 对应的那一组）：

| 渠道 | 安全群 | 财务群 |
|-----|-------|-------|
| 企业微信 | `WECOM_SECURITY_WEBHOOK`（无 secret） | `WECOM_BILLING_WEBHOOK` |
| 钉钉 | `DINGTALK_SECURITY_WEBHOOK` + `DINGTALK_SECURITY_SECRET`（成对，未开加签填 `NONE`） | `DINGTALK_BILLING_WEBHOOK` + `DINGTALK_BILLING_SECRET` |

每个企业微信 / 钉钉机器人各自有 20 条/分钟的限额，分流到独立机器人也能缓解风暴时的限流。

> **注意**：`deploy-gcloud.sh` 的 `--set-secrets` 是整体替换，重跑部署脚本会把手工追加的分群挂载冲掉 ——
> 重部署后需要重新执行上面的 `--update-secrets`。

---

## 6. Terraform 相关


### `Error 409: already exists` on secret

`terraform/secrets.tf` 应当只有 `data` 源，不能有 `google_secret_manager_secret` 资源。
密文归部署脚本管，Terraform 只管 IAM —— 见
[deployment-comparison.md](deployment-comparison.md#密钥所有权两条路径共同的约定)。

### `terraform plan` 显示函数要 replace

看是哪个字段触发的。`build_config.source` 变了是正常的（源码有改动）；
`location`、`name` 变了说明配置被改坏了 —— 函数被 replace 会重建触发器订阅，
期间的告警会丢。

### 升级后 `plan` 出现 `has moved to`

存量飞书部署升级到多渠道版本后，`plan` 会显示两条：

```
# google_secret_manager_secret_iam_member.webhook_accessor has moved to google_secret_manager_secret_iam_member.secret_accessor["FEISHU_DEFAULT_WEBHOOK"]
# google_secret_manager_secret_iam_member.sign_accessor has moved to google_secret_manager_secret_iam_member.secret_accessor["FEISHU_DEFAULT_SECRET"]
```

这是 `terraform/secrets.tf` 里 `moved` 块的预期效果，**不需要**手工 `terraform state mv`。
`notify_channel` 未设置（= `feishu`）时 IAM 绑定不应有任何 destroy / replace；若看到了，先确认 tfvars 里
`notify_channel` 与 `feishu_default_*_secret` 的值和升级前一致。切到 wecom / dingtalk 时旧的飞书 accessor 被 destroy 是预期的
（最小权限），飞书 Secret 本身不会被删除。

### `precondition` 失败：速率超出渠道上限

```
notify_channel = dingtalk（钉钉）：max_sends_per_minute(40) × max_instances(2) = 80，必须 ≤ 16 ...
```

tfvars 里显式写了 `max_sends_per_minute`（多半是飞书时代留下的 40）。删掉该行回到 `null`（按渠道推导 8），
或调低到满足 `速率 × max_instances ≤ 16`。见第 6 节。

### 手工改 `notify_channel` 后 `plan` 在 Secret `data` 源上报 404

切换 `notify_channel` 前必须先让对应渠道的 Secret 存在（由 `deploy-terraform.sh` 收集凭据后创建，Terraform 只 `data` 引用）。
直接改 tfvars 里的 `notify_channel` 再 `terraform apply`，会因 `wecom-default-webhook` 等 Secret 不存在而在
`data.google_secret_manager_secret.channel[...]` 上失败 —— 请改用 `NOTIFY_CHANNEL=… ./deploy-terraform.sh` 重跑。

### 切换渠道后的短暂窗口

切换 `notify_channel`（或 `configure.sh --section=channel`）时，Terraform 会销毁旧渠道 Secret 的 `secretAccessor` 绑定并部署新 revision。
两者之间存在数十秒窗口：若旧 revision 恰在此时冷启动，会因读不到旧 Secret 起不来，对应消息被 nack 后由 Pub/Sub 重投到新 revision，
一般不会丢。切换后建议看一眼自检结果与 `gcloud logging read 'severity>=ERROR' --freshness=10m`。旧渠道的 Secret 本体会保留，
确认不再回切后可用 `teardown-gcloud.sh --delete-secrets` 或手工 `gcloud secrets delete` 回收。

### `apply` 在 `google_cloud_run_v2_service_iam_member` 上 403

默认 `run_invoker_scope = "service"` 需要部署者有 `run.services.setIamPolicy`（`roles/run.admin`；
`roles/editor` 与 `projectIamAdmin` 都不含）。要么补 `run.admin`，要么在 tfvars 设 `run_invoker_scope = "project"`
改为项目级绑定（只需 `projectIamAdmin`，代价是该 SA 可调用项目内所有 Run 服务）。

### `teardown-gcloud.sh` 拒绝执行

```
❌ topic gcp-alerts-hub 带有 managed-by=terraform 标签：这是 Terraform 路径部署的环境
   本脚本只清理 gcloud 路径的资源。请改用：cd terraform && terraform destroy
```

这是有意的：Terraform 路径的资源归 state 管，用 gcloud 删会留下孤儿 state。
同理，带 `userLabels.managed-by=terraform` 的告警策略在 teardown 中会被跳过并提示。
teardown 对告警策略 / 通知渠道只按本仓库固定的 displayName **精确匹配**，不会按前缀误删客户自建的 `Recommended - *`。

### Sink 身份传播延迟导致 apply 报错

Hub 范围模式下，新建的文件夹 / 组织聚合 sink 的写入身份（`service-folder-*@gcp-sa-logging.iam.gserviceaccount.com`）创建后需要一段时间传播。同一次 apply 里紧接着给它授 `roles/logging.logWriter` 时，会报 400 `... gcp-sa-logging.iam.gserviceaccount.com does not exist`。
`deploy-terraform.sh` 检测到这条报错会等待 60 秒，然后自动再 plan / apply 一次，只应用剩余变更；gcloud 路径用 `soft_step_retry` 对等处理。手动执行 `terraform apply` 遇到时，等待约 60 秒后重跑即可。

### 读不到项目的结算账号（Terraform）

```
❌ Billing 预算已启用（沿用线上现状），但读不到项目的结算账号。
   此时若继续，Terraform 会写入 enable_billing=false 并在 apply 中【删除已有预算】，因此中止（未做任何修改）。
```

`deploy-terraform.sh` 依次尝试 `BILLING_ACCOUNT_ID` 环境变量 → `gcloud billing projects describe` → 本机
`terraform/terraform.tfvars` 原有的 `billing_account_id`（输出里有一行「Billing：结算账号取自…」）。全都拿不到，且
Billing 是沿用线上得来的、或线上预算现状为「存在 / 未知」时中止。补救三选一：

1. **授权后重跑**：给部署者授项目上的 `roles/billing.viewer`（管理预算还需结算账号上的 `roles/billing.costsManager`）。
2. **显式提供结算账号**：`BILLING_ACCOUNT_ID=01ABCD-2345EF-6789AB ./deploy-terraform.sh ...`（可带 `billingAccounts/` 前缀）。
3. **确实要关闭预算告警**：`ENABLE_BILLING=N ./deploy-terraform.sh ...`（apply 会删除预算）。

只有显式 `ENABLE_BILLING=Y` 且线上本来没有预算（或首次部署）时，才会降级为「已跳过：启用 Terraform 的 Billing 模块」并以退出码 2 结束。
`configure.sh` 在 Terraform 模式下遇到该情况会显示上述中止信息并报「配置修改未生效」（退出 1），不会 apply。
gcloud 路径不受影响（只 upsert，读不到结算账号仍是登记跳过）。

### state 丢了

```bash
gcloud storage ls "gs://${PROJECT_ID}-gcp-feishu-tfstate/terraform/state/"
# bucket 开了 versioning，可以恢复历史版本
gcloud storage ls -a "gs://${PROJECT_ID}-gcp-feishu-tfstate/terraform/state/default.tfstate"
gcloud storage cp "gs://.../default.tfstate#GENERATION" "gs://.../default.tfstate"
```

实在恢复不了，就按 [deployment-comparison.md](deployment-comparison.md#从-gcloud-迁移到-terraform)
的 import 清单把现有资源重新导入。

---

## 7. 修改配置（configure.sh）与重跑部署


### configure 报「函数不存在」或「在其它区域发现同名函数」

```
❌ 函数 gcp-alerts-to-feishu 在 <项目> / asia-east1 中不存在：尚未部署，无配置可修改
   在其它区域发现同名函数：asia-northeast1 —— 请用 --region=<区域> 重跑
```

configure 只修改已部署环境，默认区域 `asia-east1`。部署时用了别的区域就加 `--region=<区域>`；
确实没部署过则先运行 `./deploy-gcloud.sh` / `./deploy-terraform.sh`。另一种报错
「无法读取函数 … 的配置（权限不足或 Cloud Functions API 不可用）」表示缺 `roles/cloudfunctions.viewer`。

### 「无法读取「…」现状」导致 `--yes` 直接退出

```
❌ 无法读取「Billing 预算」现状。Terraform 模式下请显式设置 ENABLE_BILLING=y|n 后重跑（否则 apply 可能误删资源）
```

只出现在 **Terraform 模式**：缺 `billing.viewer`、SCC 组织级查看权限等导致现状未知，本机 `terraform.tfvars` 也没有可兜底的值。
Terraform 模式下 tfvars 写 false 会让 apply 删除资源，所以 `--yes` 拒绝替你猜。补齐只读权限，或显式设置
`ENABLE_BILLING` / `ENABLE_SCC` / `ENABLE_PSH` / `ENABLE_DEFAULT_ALERTS=y|n`、`OPS_EMAIL=<邮箱>`（或 `OPS_EMAIL=` 表示关闭）后重跑。
交互模式下则会要求必须作答（无默认值）。直接跑 `deploy-terraform.sh --yes` 时报错文案为
「无法读取「…」的线上现状（权限不足？）。Terraform 模式下请显式设置 …」，处理相同。
gcloud 模式不会因此退出：未知项保持不动（不建不删），打印「无法读取线上现状、本次保持不动（不创建也不删除）：…」。

### 在 terraform plan 确认处取消

Terraform 模式交互运行 configure 时，确认后会先展示 `terraform plan`，需再次输入 `yes` 才 apply。在这里取消：

- `deploy-terraform.sh` 以退出码 `3` 返回（`TF_APPLY_CONFIRM=interactive` 下取消的专用码）；
- configure 提示「已在 terraform plan 确认处取消：未 apply，函数配置与 revision 均未改变」，**以 0 退出**；
- 若本次选择了「输入新凭据」，还会提示**新凭据已写入 Secret 新版本**（凭据先于 plan 写入）：现有实例仍用旧值直到下次重启，
  如需回退请在 Secret Manager 中停用该版本。

plan 里若出现与本次修改无关的变更，那是控制台手工改动等**漂移**，确认后会一并应用 —— 先看清再输入 `yes`。

### 设置 KILL_SWITCH / PAUSE_MODE 后 configure 退出码为 2

预期行为。开关为 true 时函数不投递任何告警，部署脚本末尾的连通性自检必然失败；configure 会打印
「KILL_SWITCH / PAUSE_MODE 为 true 时连通性自检必然失败，属预期」，并以 `2`（已生效但自检未过）退出。
CI 判断时请把这种组合当作成功。

### 重跑部署时打印「沿用线上配置：…」

```
  沿用线上配置：NOTIFY_CHANNEL=wecom MIN_SEVERITY=HIGH LOG_LEVEL=INFO ...（显式设置同名环境变量可覆盖）
```

函数已存在时，部署脚本对**未显式提供**的变量沿用线上现值（`NOTIFY_CHANNEL` / `MIN_SEVERITY` / `LOG_LEVEL` /
`MAX_SENDS_PER_MINUTE`（同渠道）/ `MAX_INSTANCES` / `CONFIG_REVISION`，以及 `ENABLE_PSH` / `ENABLE_DEFAULT_ALERTS` /
`ENABLE_SCC` / `ENABLE_BILLING` / `BUDGET_AMOUNT` / `OPS_EMAIL`），这一行列出了本次沿用的项。想改回默认值就显式设置，
例如 `MIN_SEVERITY=MEDIUM ./deploy-gcloud.sh ...`。`KILL_SWITCH` / `PAUSE_MODE` **不在其中**：未提供时仍复位为 false，
线上为 true 时另有 WARNING。首次部署不会出现这一行。

### configure 提示 Secret 不存在或没有已启用版本

选择了「保持现有凭据」（`KEEP_EXISTING_SECRETS=true`），但本渠道 Secret 被删除或所有版本已停用。
在 `channel` 分区改选「输入新凭据」（`--yes` 下提供对应渠道的凭据环境变量）即可。

---

## 附：日志字段速查

所有日志都是单行 JSON，可在 Cloud Logging 中直接按字段过滤。

| 字段 | 含义 |
|-----|------|
| `severity` | 日志级别（不是告警的严重性） |
| `message` | 人类可读的描述 |
| `message_id` | Pub/Sub 消息 ID，用于串联一次投递的所有日志（信封畸形时取不到，`Malformed CloudEvent envelope` 这条没有它） |
| `logging.googleapis.com/trace` | Cloud Trace 关联 |
| `reason` | 消息未被投递的原因，见下表 |
| `alert_type` / `dedup_key` / `raw_severity` / `severity` | 告警本身的属性（`Alert delivered` 也带 `alert_type`，自检靠它过滤；发送失败日志也带 `alert_type`） |
| `source` / `threshold` / `rule` | `severity_filtered` 日志专属；`source_disabled` 日志带 `source` 与 `dedup_key` |
| `channel` | 投递渠道 `feishu` / `wecom` / `dingtalk`：`Config loaded`、`Alert delivered`、`render_failed`、发送失败与重试日志都带 |
| `group` | 卡片被路由到哪个群（`default` / `security` / `billing`） |
| `attempt` / `waited_s` / `backoff_s` | 发送重试次数、令牌桶等待时长、退避时长 |
| `http_status` / `platform_code` | 发送失败日志（`transient_send_failure` / `permanent_send_failure` / `Send failed, retrying` / `Transient failure not retried in-process…`）独立字段，可为 null；`platform_code` 是渠道无关的业务码（飞书 `code` / 企业微信、钉钉 `errcode`），如 `jsonPayload.platform_code=45009` |
| `feishu_code` | **仅 channel=feishu 时输出**，与 `platform_code` 同值，向后兼容：`jsonPayload.feishu_code=19021` 继续可用；企业微信 / 钉钉日志不带该字段 |
| `template` / `error` | `render_failed` 时的模板文件名与异常文本 |
| `url_prefix` | `console_url_rejected` 时被拒 URL 的前 120 字符 |
| `detail` | `SkipAlert` 的说明文本 |

`reason` 的取值（`jsonPayload.reason="xxx"` 可直接过滤）：

| 取值 | 含义 | 日志级别 |
|-----|------|---------|
| `kill_switch` | 紧急开关打开，直接丢弃 | WARNING |
| `pause_mode` | 暂停模式，nack 后堆积待重投 | WARNING |
| `replay_limit` | 重放次数超限，阻断死循环 | ERROR |
| `unparseable` | 消息畸形或无法识别数据源：非对象 JSON（`[1,2]` / `"x"` / `null`）、`incident` 不是对象、CloudEvent 信封畸形（日志文案 `Malformed CloudEvent envelope, dropping (no retry)`）—— 一律 ack，不进 DLQ | ERROR |
| `budget_status_no_threshold` | Billing 预算周期状态推送（无 `alertThresholdExceeded` / `forecastThresholdExceeded`），按设计不发卡（`SkipAlert`） | INFO |
| `self_referential` | 告警指向本函数自身，阻断回环 | WARNING |
| `duplicate` | dedup_key 命中去重缓存 | INFO |
| `severity_filtered` | 低于 MIN_SEVERITY | WARNING |
| `console_url_rejected` | `console_url` 不在白名单前缀内，已回落到默认控制台链接（卡片仍会发） | WARNING |
| `render_failed` | 卡片渲染失败：飞书 `jinja2.TemplateError`（含 `StrictUndefined` 的 `UndefinedError`）/ `TypeError` / `ValueError`，日志文案 `Card template rendering failed`；企业微信 / 钉钉为 `WeCom card rendering failed` / `DingTalk card rendering failed` | ERROR |
| `transient_send_failure` | 可重试的发送失败（5xx / 429 / 超时 / 200 但响应体非 JSON 对象 / 企微 45009、-1 / 钉钉 130101、-1 / 未知错误码） | ERROR |
| `permanent_send_failure` | 不可重试的发送失败（签名错、机器人被移出群、webhook 无效，见 [2.7](#27-三渠道错误码速查)）；配置了 `OPS_EMAIL` 时由自监控策略发邮件 | ERROR |
| `rate_exceeds_platform_limit` | 启动时 `MAX_SENDS_PER_MINUTE` 超过所选平台单机器人限额（100 / 20 / 20），不拒绝启动 | WARNING |

**webhook 凭据在日志中一律脱敏**：飞书 `/open-apis/bot/v2/hook/****`、企业微信 `?key=****`、
钉钉 `?access_token=****` 与 `&sign=****`（含异常堆栈里 requests 打出的 URL）——
token 等同于凭据，任何有 logging.viewer 的人都能看到日志。
