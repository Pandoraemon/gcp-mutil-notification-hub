# GCP 告警一键转发到飞书 / 企业微信 / 钉钉

## 开始之前

本教程会在你的 GCP 项目里部署一条告警转发链路，约 10 分钟。

请先准备好：

- 一个 GCP 项目，你的账号需要 **Editor** + **Project IAM Admin** 权限；
- 目标群的 **机器人 Webhook 地址**（飞书 / 钉钉如开启了签名，还需要签名密钥）。还没有机器人？参考仓库里的 `docs/bot-setup.md`。

点击 **开始** 继续。

## 部署

在下方终端运行（点击代码块右上角的按钮可直接复制到终端）：

```bash
cd ~/cloudshell_open/gcp-mutil-notification-hub && ./deploy-gcloud.sh
```

按提示依次回答：

1. **选择项目**：输入列表中的编号；
2. **选择通知渠道**：`1` 飞书/Lark、`2` 企业微信、`3` 钉钉；
3. **粘贴 Webhook URL**；
4. **签名密钥**：开启了签名 / 加签就填密钥，**没开填 `NONE`**（企业微信不需要）；
5. **其余选项**：服务故障告警建议 `Y`；推荐默认告警包按需 `y`；SCC / Billing 预算不需要就直接回车；
6. **运维通知邮箱**：建议填一个邮箱（推送链路自身出故障时发邮件提醒），也可留空。

## 确认结果

- 屏幕最后出现 **✅ 部署完成**，且群里收到 **🟢 连通性自检成功** 卡片：部署成功。
- 出现 **⚠️ 本次部署【不完整】**：按屏幕给出的补救命令补齐权限，再运行一次部署命令即可（可重复执行）。
- 群里没有卡片：先检查签名密钥是否填对，再参考 `docs/troubleshooting.md`。

## 接入更多告警

在 Cloud Monitoring 新建或编辑告警策略时，通知渠道选择 **`Feishu Alert Hub`**（历史名称，企业微信 / 钉钉同样使用），该策略的告警就会推送到群里。

## 日常操作

```bash
./scripts/configure.sh              # 修改配置：换群、换平台、告警级别、开关数据源
./scripts/emergency-disable.sh      # 紧急停止推送（加 --pause 为暂停，恢复后补发）
./scripts/emergency-enable.sh       # 恢复推送
./scripts/teardown-gcloud.sh        # 卸载
```

## 完成

<walkthrough-conclusion-trophy></walkthrough-conclusion-trophy>

部署完成！以后再次打开 Cloud Shell，项目目录在 `~/cloudshell_open/gcp-mutil-notification-hub`。
完整说明见仓库 `README.md` 与 `docs/full-guide.md`。
