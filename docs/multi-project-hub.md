# 多项目汇聚（Hub 模式）

Hub 模式允许在中心项目（Hub）部署一套转发器，集中收集多个源项目的告警与通知，并统一发送到同一个 IM 群（飞书、企业微信或钉钉）。
每张卡片都会带一个「项目」字段标明来源项目。PSH 只给项目编号（`resource_container`），函数按 `HUB_SOURCE_PROJECTS` / `source_projects` 换成项目 ID；未登记的编号（如范围模式下新加入的项目）保留编号原样。
针对跨项目的 PSH 事件去重，卡片会加注「影响范围以 Service Health 控制台为准」。

## 适用场景
- **集中管理**：团队拥有多个 GCP 项目，不希望在每个项目中重复部署函数和配置 webhook。
- **跨项目洞察**：将所有源项目的指标告警、服务健康（PSH）、审计日志告警，以及已绑定的客户自建策略统一路由。
- **配置一致性**：在 Hub 统一配置频率限制（如 40/8/8）和过滤脱敏规则。

## 源项目前置条件
源项目必须启用 `pubsub.googleapis.com` API，否则数据源的通知通道无法正常向 Hub 的 Topic 发送消息。gcloud 部署脚本会在关联时尝试自动启用它（连同 `monitoring`, `logging`, `servicehealth`），但调用者必须拥有 `serviceusage.services.enable` 权限。

## 架构与资源创建

Hub 模式支持按**明确清单（清单模式，`HUB_SOURCE_PROJECTS`）**或同时提供**文件夹/组织节点（范围模式，`HUB_SCOPE`）**汇入源项目。

对于**每一个接入的源项目**，将自动创建或配置以下资源：
1. **API 启用**：启用 `monitoring.googleapis.com`、`logging.googleapis.com`、`servicehealth.googleapis.com` 及 `pubsub.googleapis.com`。
2. **Monitoring 通知渠道**：在源项目创建名为 `GCP Alerts Hub → <HUB_PROJECT_ID>` 的 Pub/Sub 通知渠道。
3. **IAM 授权**：向该源项目的 Monitoring 服务代理赋予 Hub topic 的 `roles/pubsub.publisher`（无 `--condition`）。
4. **Metrics Scope**：将源项目作为 monitored project 加入 Hub 的 Metrics Scope 中。这样 Hub 的默认指标类告警就能自动覆盖这些源项目。
5. **日志 Sink**：新建名为 `gcp-alerts-hub-to-<HUB_PROJECT_ID>` 的日志 sink（目标指向 Hub），拦截 PSH 事件及指定审计事件，并通过 unique writer identity 对 Hub 赋予 `roles/logging.logWriter`。

### 范围模式（Scope Mode）下的特殊处理
如果你通过 `HUB_SCOPE` / `source_scope` 配置了范围（例如 `folders/12345` 或 `organizations/67890`），系统会自动在该文件夹或组织节点建一个**聚合 sink** 统收范围内的日志。
同时，**在范围之内的源项目不再重复建立单独的项目级 sink**，而**不在该范围内的其它源项目仍将保留单项目 sink**。
**注意**：哪怕使用了聚合 sink，源项目依然需在源项目列表里声明，才能为其创建 Metrics Scope 与通知渠道。范围下新加项目后，需要重跑添加流程。

### 审计日志回灌与路由设计（Routed Audit Logs）
日志型告警只评估 `_Default` 桶。源项目的审计日志（如高危 IAM 操作）路由进 Hub 后，会被 Hub 的 `_Default` sink 按 `LOG_ID` 排除，进不了 `_Default` 桶。
为此，部署时在 Hub 侧自动创建了一个 `gcp-alerts-hub-routed-audit` 回灌 sink，将汇入的非 Hub 项目审计日志送回 Hub 的 `_Default` 存储桶，以使基于日志的告警策略能正常捕捉。
⚠️ **注意**：因此，Hub 侧所有关联日志的告警策略必须使用 `LOG_ID("cloudaudit.googleapis.com/...")` 进行过滤，严禁硬编码 `logName` 路径。

## 权限要求

除 Hub 的权限外，部署者还需要在源项目或组织节点拥有：
- 源项目（部署前用 `testIamPermissions` 只读预检）：`monitoring.notificationChannels.create`、`logging.sinks.create`、`serviceusage.services.enable`、`monitoring.alertPolicies.update`（绑定策略用）、`resourcemanager.projects.get`。
- 文件夹/组织（范围模式）：`logging.sinks.create/get/update/delete`，缺失时脚本提示让节点管理员授予 `roles/logging.configWriter`。
- Hub 侧：除常规部署权限外，还需能把源项目加入 Metrics Scope，并修改 Hub topic 的 IAM。

## 如何接入与修改配置

### 交互式接入（gcloud 路径）
运行 `./scripts/configure.sh`，在主菜单选择 **⑧ 多项目汇聚**，即可进入向导：
- `[a] 添加源项目`：可多选项目编号加入（格式自动处理并注入 env `HUB_SOURCE_PROJECTS="id=number;..."`）。
- `[r] 移除源项目`：见下文「断开源项目」。
- `[s] 设置/清空范围`：指定文件夹或组织节点 ID（如 `folders/123`），开启或关闭范围模式。
- `[b] 绑定告警策略`：列出源项目已有的所有监控策略，**选择绑定会实际修改客户原有的策略**，追加 Hub 的渠道；解绑则移除渠道引用。这是唯一的修改客户自有资源的例外动作。
- `[v] 状态体检`：验证源项目的各个资源和绑定数是否正常，如发现 sink 身份未成功传播会给出提示。

或者在部署前通过环境变量指定：
```bash
export HUB_SOURCE_PROJECTS="project-a;project-b"
export HUB_SCOPE="folders/12345678"
./deploy-gcloud.sh
```
（`deploy-gcloud.sh` 会自动将传入的纯 ID 转换为内部使用的 `id=number;id=number` 格式）

## 断开源项目
当你通过向导 `[r] 移除源项目` 删除项目时，系统会自动执行清理：
1. 先从该源项目已绑定的客户自有策略中移除对 Hub 渠道的引用。
2. 摘除由 Hub 自动在源项目创建的通知渠道与日志 sink。
3. 移除该源项目在 Hub topic 上的 `pubsub.publisher` IAM 授权。
4. 将该源项目从 Hub 的 Metrics Scope 中解除关联。

## 性能与延迟（Latency）

- **PSH 事件**：从策略命中到转发至 IM 的端到端延迟通常在 **30 秒** 左右。但须注意，新建项目启用 Service Health API 后，Google 后台需约 1.5 - 2 小时完成日志流式传输的准备工作，在这之前 PSH 日志可能不会产出。
- **回灌审计日志（Routed Audit Logs）**：因日志被 sink 转发和回灌需要落盘和二次处理，端到端延迟（从发生到告警）大约为 **4 分钟**。

## 常见问题

**Q：源项目的结算账号和配额归属于谁？**
日志 Sink 转发、监控查询会消耗少量的 GCP 资源，计费与配额按各个源项目计算；而 Hub 的接收 Topic、函数执行、DLQ 等费用则计入 Hub 项目。

**Q：配置了范围模式，范围内的新项目会自动发送告警吗？**
不会完全自动。即使配置了 `HUB_SCOPE`，范围下的新项目只是被聚合 Sink 收纳了日志。必须将新项目加进 `HUB_SOURCE_PROJECTS` 或 `source_projects` 里并运行部署，才能为其配置 Metrics Scope 关联并授予 Pub/Sub Topic 权限。

**Q：源项目里的告警策略会自动转发到 Hub 吗？**
不会。Hub 会为其建立默认的几项告警策略，但客户原有的告警策略需要你主动把它们的通知通道绑定到新建立的 Hub 渠道上（可通过 `configure.sh` ⑧ 的 `b` 选项操作）。
