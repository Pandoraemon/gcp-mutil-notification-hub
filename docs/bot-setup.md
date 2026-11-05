# 创建 IM 群机器人（飞书 / 企业微信 / 钉钉）

部署前需要在**所选平台**的告警群里创建一个群机器人，拿到 Webhook（钉钉还要加签密钥）。
三个平台任选其一，部署时三选一（见 [README · 选择通知渠道](../README.md#选择通知渠道三选一)）。

> [!IMPORTANT]
> **Webhook 本身就是凭据**：拿到 URL 的任何人都能往群里发消息。只把它交给部署脚本（脚本会存进 Secret Manager），
> 不要贴进代码、工单、聊天记录或截图。泄露后到机器人设置里**重置 Webhook / 删除重建**即可作废旧地址。

> [!NOTE]
> 下面的菜单名称以 2026 年电脑端为准，各平台改版后文案可能略有不同（例如企业微信的「群机器人」在部分版本叫「消息推送」，
> 钉钉的「机器人」在部分版本位于「智能群助手」下）。如果找不到入口，多半是企业管理员关闭了该功能，见各节「常见问题」。

| | 飞书 / Lark | 企业微信 | 钉钉 |
|---|---|---|---|
| 机器人类型 | 自定义机器人 | 群机器人（消息推送） | 自定义机器人 |
| 需要交给部署脚本 | Webhook + 签名密钥（没开签名填 `NONE`） | 只有 Webhook | Webhook + 加签密钥（没开加签填 `NONE`） |
| Webhook 形如 | `https://open.feishu.cn/open-apis/bot/v2/hook/xxxx` | `https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=xxxx` | `https://oapi.dingtalk.com/robot/send?access_token=xxxx` |
| 群类型限制 | 无特殊限制 | **仅内部群**（含外部联系人的群不能加） | 无特殊限制 |
| 平台限流 | 100 条/分钟 | 20 条/分钟 | 20 条/分钟，超限**封禁 10 分钟** |
| 推荐安全设置 | 开启「签名校验」 | 无可选项（保管好 key） | **「加签」** |

---

## 1. 飞书 / Lark

1. 用**飞书电脑版**打开告警群 → 右上角 **「…」→「设置」**。
2. **「群机器人」→「添加机器人」**，选择 **「自定义机器人」**。
3. 填写机器人名称（如 `GCP 告警`）和描述，点「添加」。
4. 复制页面上的 **Webhook 地址**。
5. 安全设置（推荐）：勾选 **「签名校验」**，复制生成的密钥；也可以不开，部署时签名密钥填 `NONE`。
   - 不建议开「自定义关键词」或「IP 白名单」：卡片标题不固定、Cloud Functions 出口 IP 不固定。
6. 点「完成」。

部署脚本选 `1) 飞书/Lark`，或非交互：

```bash
export NOTIFY_CHANNEL=feishu
export FEISHU_WEBHOOK='https://open.feishu.cn/open-apis/bot/v2/hook/xxxx'
export FEISHU_SECRET='签名密钥或 NONE'   # 不能留空：空串会让所有卡片被拒且 HTTP 仍返回 200
```

Lark 国际版地址为 `https://open.larksuite.com/open-apis/bot/v2/hook/...`，同样支持。

---

## 2. 企业微信

**前提**：告警群必须是**企业内部群**（群里全是本企业成员）。含微信用户或其他企业成员的**外部群不支持**群机器人。

1. 用**企业微信电脑版**打开告警群 → 右上角 **「…」**（聊天信息）。
2. 点 **「群机器人」**（部分版本叫 **「消息推送」**）→ **「添加」**。
3. 选择 **「新创建一个机器人」**，设置头像和名称（如 `GCP 告警`），点「添加」/「完成」。
4. 创建成功后页面会显示 **Webhook 地址**，点「复制地址」。
   - 之后也可以在群聊信息 → 群机器人 → 点开该机器人 → 查看 / 复制 Webhook。

企业微信群机器人**没有签名机制**，URL 里的 `key` 就是全部凭据，务必只存进 Secret Manager。

> [!WARNING]
> **不要和「智能机器人」混淆**：企业微信管理后台 → 工作台 →「智能机器人」（API 模式）给出的是 **BotID + Secret**，
> 走 WebSocket 长连接、主动推送还需要目标群的 `chatid`，且同一机器人同时只允许一个连接 —— 本项目**不支持**这种凭据。
> 这里需要的是群聊里添加的「群机器人 / 消息推送」，凭据是形如 `https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=xxxx` 的 Webhook。

部署脚本选 `2) 企业微信`，或非交互：

```bash
export NOTIFY_CHANNEL=wecom
export WECOM_WEBHOOK='https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=xxxx'
```

**常见问题**

- **群设置里没有「群机器人」**：
  - 群是外部群 → 换一个内部群；
  - 你不是群主 / 管理员且群开启了「仅群主可管理」 → 请群主添加；
  - 企业管理员在管理后台关闭了群机器人功能 → 联系企业微信管理员开启。
- **报 `errcode=93000`**：Webhook 无效或机器人已被移出群 → 重新复制地址，用 `./scripts/configure.sh --section=channel` 更新。
- **报 `errcode=45009`**：超过 20 条/分钟。本项目默认每实例 8 条/分钟（2 实例共 16），一般不会触发；
  如果自己调大过 `MAX_SENDS_PER_MINUTE`，请恢复默认。

---

## 3. 钉钉

1. 用**钉钉电脑版**打开告警群 → 右上角 **「群设置」**（齿轮图标）。
2. 点 **「机器人」**（部分版本在 **「智能群助手」** 里）→ **「添加机器人」**。
3. 在机器人列表中选择 **「自定义」**（通过 Webhook 接入自定义服务）→ 「添加」。
4. 填写机器人名称（如 `GCP 告警`）。
5. **安全设置**（钉钉要求至少选一项）：
   | 选项 | 是否推荐 | 说明 |
   |---|---|---|
   | **加签** | ✅ **推荐** | 勾选后复制以 `SEC` 开头的密钥，部署时填入 `DINGTALK_SECRET`。本项目自动计算签名 |
   | 自定义关键词 | 可用 | 关键词**必须填 `GCP告警`**（本项目每张卡片标题都以它开头）；部署时 `DINGTALK_SECRET=NONE` |
   | IP 地址（段） | ❌ 不建议单独使用 | Cloud Functions 出口 IP 不固定，会间歇性被拒（`errcode=310000`） |

   加签与关键词可以同时勾选，两者都满足才会放行。
6. 勾选同意《自定义机器人服务及免责条款》→ **「完成」**。
7. 复制页面上的 **Webhook 地址**（之后可在群设置 → 机器人 → 点开该机器人查看）。

部署脚本选 `3) 钉钉`，或非交互：

```bash
export NOTIFY_CHANNEL=dingtalk
export DINGTALK_WEBHOOK='https://oapi.dingtalk.com/robot/send?access_token=xxxx'
export DINGTALK_SECRET='SECxxxx'   # 加签密钥；只用关键词时填 NONE（不能留空）
```

> [!WARNING]
> **Webhook 只填控制台复制出来的原始地址**，不要自己在后面拼 `&timestamp=...&sign=...`——签名由函数在每次发送时计算。
> 拼上去的固定签名一小时后就会过期，报 `errcode=310000`。

**常见问题**

- **群设置里找不到「添加机器人」/ 没有「自定义」**：企业管理员可能禁止了自定义机器人，或只允许群主添加 → 请群主或钉钉管理员操作。
- **报 `errcode=310000`**：三种原因，见 [troubleshooting · 钉钉 310000](troubleshooting.md#26-钉钉-errcode310000安全设置校验失败)：
  加签密钥填错（或 webhook 里自己拼了签名）、关键词不是 `GCP告警`、开了 IP 白名单。
- **报 `errcode=130101`**：超过 20 条/分钟，钉钉会**封禁约 10 分钟**。本项目默认每实例 8 条/分钟；
  被封期间的告警会进入死信队列，解封后用 `./scripts/replay-dlq.sh` 重放。

---

## 4. 验证机器人可用

**推荐方式**：直接部署。两条部署脚本最后都会自动发一张「连通性自检成功」卡片并确认送达，失败时会打印平台返回的错误码与排查建议。

如果想在部署前先单独确认 Webhook 有效，可以手工发一条测试消息。为避免 Webhook 留在 shell 历史里，先用 `read -s` 读入变量：

```bash
# 飞书（未开签名校验时可直接测；开了签名请直接用部署自检）
read -rsp 'Feishu webhook: ' WEBHOOK; echo
curl -sS -H 'Content-Type: application/json' -d '{"msg_type":"text","content":{"text":"GCP告警 测试"}}' "$WEBHOOK"; echo
# 期望返回 {"code":0,...}

# 企业微信
read -rsp 'WeCom webhook: ' WEBHOOK; echo
curl -sS -H 'Content-Type: application/json' -d '{"msgtype":"text","text":{"content":"GCP告警 测试"}}' "$WEBHOOK"; echo
# 期望返回 {"errcode":0,"errmsg":"ok"}

# 钉钉（支持加签；只用关键词时密钥直接回车留空）
read -rsp 'DingTalk webhook: ' WEBHOOK; echo
read -rsp 'DingTalk secret (SEC..., 可留空): ' SECRET; echo
URL=$(WEBHOOK="$WEBHOOK" SECRET="$SECRET" python3 - <<'PY'
import base64, hashlib, hmac, os, time, urllib.parse
url, secret = os.environ['WEBHOOK'], os.environ['SECRET']
if secret:
    ts = str(round(time.time() * 1000))
    sig = base64.b64encode(hmac.new(secret.encode(), f'{ts}\n{secret}'.encode(), hashlib.sha256).digest()).decode()
    url += f'&timestamp={ts}&sign={urllib.parse.quote_plus(sig)}'
print(url)
PY
)
curl -sS -H 'Content-Type: application/json' -d '{"msgtype":"text","text":{"content":"GCP告警 测试"}}' "$URL"; echo
# 期望返回 {"errcode":0,"errmsg":"ok"}
unset WEBHOOK SECRET URL
```

测试消息里都带了 `GCP告警`，所以钉钉关键词模式也能通过。

---

## 5. 之后要换机器人 / 换平台

- **同平台换 Webhook 或密钥**：`./scripts/configure.sh --section=channel` → 选择「输入新凭据」。会写入新 Secret 版本并强制函数重启，立即生效。
- **换平台**（如飞书 → 钉钉）：同样用 `configure.sh --section=channel` 选新渠道并输入新凭据。旧渠道的 Secret 会保留（不再挂载），
  需要回收时执行 `./scripts/teardown-gcloud.sh --delete-secrets` 或按 `terraform output next_steps` 提示手工删除。

相关文档：[完整指南 · 选择通知渠道](full-guide.md#选择通知渠道三选一) ·
[故障排查 · 三渠道错误码速查](troubleshooting.md#27-三渠道错误码速查) · [修改配置（configure.sh）](full-guide.md#修改配置configuresh)
