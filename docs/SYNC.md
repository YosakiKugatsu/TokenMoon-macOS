# TokenMoon WebDAV v1

这份规范用于 TokenMoon 多设备同步，也供其他客户端直接读取。格式和路径独立于 Magpie。规范文件：[JSON Schema](schema/tokenmoon-v1.schema.json) · [脱敏示例](schema/tokenmoon-v1.example.json)。

## 目录、身份与请求

在每台设备填写同一个已存在、可读写的 WebDAV 目录地址，例如 `https://dav.example.com/remote.php/dav/files/user/AI/`。TokenMoon 在这个目录内创建 `tokenmoon-v1/`，不修改目录中的其他应用数据。

```text
AI/
└── tokenmoon-v1/
    ├── 11111111-1111-4111-8111-111111111111--2026-10.json
    ├── 11111111-1111-4111-8111-111111111111--2026-11.json
    └── 22222222-2222-4222-8222-222222222222--2026-11.json
```

- 设备 ID 是首次运行生成并保存在本机的 UUID，文件名和 JSON 都使用小写标准形式。设备改名不改变 ID。同一物理设备继续原有记录时可保留 ID；同时运行的两台设备应使用不同的 ID。
- 文件名为 `<deviceID>--<YYYY-MM>.json`。每个文件承载同一设备、同一 **UTC 月份**的请求。文件名和文件内的设备、月份必须匹配；月份按写入文件的 `timestamp` 决定，与界面使用的时区无关。
- 请求主键是 `(deviceID, id)`；`id` 来自稳定的客户端事件 ID 或由稳定源字段推导。导入、重扫与重试必须复用相同主键。会话分组键是 `(deviceID, agent, sessionID)`，同一会话可跨月份；归并请求后再算会话统计。
- 设备只写自己的分片，读取所有设备分片。没有全局清单、共享计数文件或单独的会话汇总。删除分片不是受支持的跨设备删除操作；在线设备下次同步仍可能从本地数据恢复它。
- TokenMoon 限制单个分片和一次目录响应为 48 MiB。超过上限时报告错误并保留原数据。需要更细的分片时应另行定义兼容的新版本。
- CPA 发布器以独立设备 ID 记录本网关的请求，`agent` 为 `cpa`。`cpaKeyID` 是不透明标识，`cpaKeyLabel` 是 CPA 入站 Key 的显示标签；上游 `account` 只能是已核实的 OAuth 邮箱或脱敏 API Key。两者不能互相替代。
- `quotaObservations` 可随分片同步官方客户端实际观测到的额度。观测月份按 UTC 的 `observedAt` 划分，可独立成片；同一设备内以客户端、账号、窗口标识和观测时间去重。观测包括已验证的账号、窗口标识与名称、已用百分比、可用的重置时刻、窗口时长和计划名称，不包括凭据、猜测值或本机预测历史。

## HTTP 读写流程

1. 向 `tokenmoon-v1/` 发起 [WebDAV PROPFIND](https://www.rfc-editor.org/rfc/rfc4918#section-9.1)，`Depth: 1`，读取 `207 Multi-Status` 中直属的 `DAV:response/DAV:href` 和成功返回的 `DAV:getetag` 属性。若目录不存在，`MKCOL` 后重试。忽略不符合分片命名规则的文件；不跟随重定向或访问清单中指向其他源的链接。
2. `GET` 分片并验证版本、文件名、设备归属、月份与请求主键。经过验证的分片缓存绑定 WebDAV 地址和用户名，有强 ETag 时可用 `If-None-Match` 复用 `304` 对应的数据。只读设备分片的强 `DAV:getetag` 与缓存相同也可跳过 GET。一个分片读取失败时报告部分同步，保留该分片的上一次有效缓存（若有），继续读取和同步其他分片；无法读取的本机分片不写入。目录清单无法读取时停止整轮，清单中不存在或 GET 返回 `404` 的分片不再保留旧缓存。
3. 按主键归并远端本设备分片与本机记录。保留仅远端存在的请求；采集器确认旧标识已由同一请求的正式标识替代时，可以在设备自己的分片中移除该确切旧标识。本机重新观测到同一请求时可修正已知字段；客户端、会话、模型与四类 Token 均一致时，保留本机记录缺失的远端计时和等级等已有证据。其他设备的分片只读。读者遇到跨分片重复主键时使用月份较新的一条；正确的写入方应始终将主键保存在请求时间所在的月份。设备名按该设备 `updatedAt` 最新的分片展示，同一更新时间使用较新月份。
4. 新文件用 `PUT` 和 `If-None-Match: *`；已有文件用 `PUT` 和上一次 `GET` 返回的强 `ETag` 作为 `If-Match`。服务器返回 `409` 或 `412` 时重新读取、合并并重试，最多 4 次尝试。强 ETag 缺失时不覆盖。记录与设备名不变时不发 PUT。同步允许某月上传成功后另一月出错；后续重试会继续归并，不增加重复请求。
5. 数据目录需支持 `PROPFIND`、`GET`、`PUT` 和条件请求；首次建目录还需 `MKCOL`。标准 HTTPS，支持 HTTP Basic 认证；明文 HTTP 仅用于本机回环测试。TokenMoon 将密码放在 macOS 钥匙串，以 WebDAV 地址和用户名索引。读取方只需目录读权限，不需要设置密码写入文件。

桌面端通常通过「设置 → 同步」配置。若通过脚本部署，可在目标用户的图形登录会话中运行已安装的 `TokenMoon.app/Contents/MacOS/TokenMoon --provision-webdav HTTPS_DIRECTORY USERNAME`。仅通过标准输入提供 UTF-8 密码（不带换行）。命令只在写入并成功读回钥匙串后返回成功；随后在应用设置中使用同一个地址和用户名启用同步。钥匙串暂时不可读时，自动同步会重试并保留原凭据。

## JSON 文件

UTF-8 JSON，媒体类型 `application/json`。时间采用 RFC 3339 形式的 UTC 时间，写入使用 `YYYY-MM-DDTHH:mm:ss.SSSZ`。读者应同时接受无小数秒的形式。JSON 字段名区分大小写；数字不用字符串表示。可选项未知时省略（读者也应接受 `null`）。字符串标识保留原始大小写，除非下文指定。

| 顶层字段 | 类型 | 说明 |
| --- | --- | --- |
| `schemaVersion` | 整数 | 固定为 `1`。 |
| `deviceID` | 字符串 | 与文件名、所有请求的设备 ID 一致。 |
| `deviceName` | 非空字符串 | 用户可读设备名。 |
| `month` | 字符串 | UTC 月，格式 `YYYY-MM`。 |
| `updatedAt` | 时间字符串 | 分片最后一次实际写入时的 UTC 时间，仅用于设备名展示等；不影响统计。 |
| `requests` | 数组 | 原始请求元数据；允许空数组。写入方按 `timestamp`、`id` 升序写出。 |

`requests[]` 的字段：

| 字段 | 类型 | 含义 |
| --- | --- | --- |
| `id`、`sessionID`、`deviceID` | 非空字符串 | 请求、会话和设备标识，详见主键规则。 |
| `agent` | 枚举 | `codex`、`claude-desktop`、`claude-code`、`antigravity`。 |
| `timestamp` | 时间字符串 | 采集器定位到该请求用量的事件时间。用于时间筛选和分片；消费端不通过相邻记录的 `timestamp` 推算耗时。 |
| `requestedModel` | 非空字符串 | 请求的模型；未知用 `unknown`。 |
| `sentModel` | 可选字符串 | 发送或执行侧观察到的模型。 |
| `provider`、`providerID` | 可选字符串 | 供应商显示标识、日志中供应商标识。 |
| `account`、`loginMethod` | 可选字符串 | 原始记录或关联遥测提供的账号、登录方式；证据缺失时留空。 |
| `loginMethodEvidence` | 可选枚举 | `turnTrace` 表示来自同线程同轮次的明确认证日志；`conflicting` 表示该轮认证证据不一致或不足，`loginMethod` 留空。 |
| `sessionCreatorAccountID` | 可选 UUID 字符串 | Codex 会话创建时的账号 ID。用于辨认会话归属，可能与恢复会话时实际发起请求的账号不同。 |
| `sessionCreatorAccountEmail` | 可选字符串 | 与官方账户接口返回的创建者及工作区精确关联的邮箱。界面注明这是会话创建账号，不覆盖实际请求账号。 |
| `accountEvidence` | 可选字符串 | `user_confirmed` 表示用户确认的原生 Codex 或 Claude Code 历史请求账号。只与有效的 `account` 一起使用，不推断登录方式，也不覆盖后续观测的请求账号。 |
| `cpaKeyID`、`cpaKeyLabel` | 可选字符串 | CPA 入站 Key 的稳定不透明 ID 与独立显示标签，不包含原始密钥。 |
| `sentServiceTier`、`ttftMS` | 可选 | 实际发送的请求档位、首字元延迟（毫秒）。两者都不代替实际返回档位或完整耗时。 |
| `channel` | 可选字符串 | 来源已知的渠道。缺失时展示方可按模型/供应商分类。 |
| `reasoningEffort` | 可选字符串 | 日志中可见的推理强度。 |
| `serviceTier`、`requestedServiceTier` | 可选字符串 | 实际等级、请求等级各自记录，保留 `fast`、`ultrafast` 或源端其它值。只有请求等级时不写成已确认的实际等级。 |
| `actualServiceTierEvidence` | 可选枚举 | `conflicting` 表示同一个响应的实际速度证据互相矛盾；此时 `serviceTier` 不提供，合并时也不从旧记录恢复。等效计价仍可按明确的请求档位估算。 |
| `status` | 非空字符串 | 请求结果。建议用 `success`、`failed`、`cancelled` 或 `unknown`；可保留来源的具体状态。 |
| `durationMS` | 可选正数 | 单个完整请求的端到端耗时，毫秒。允许小数。不得使用会话耗时、相邻消息间隔或仅首 token 耗时填充。 |
| `timingSource` | 可选字符串 | 完整请求耗时的证据来源。只有 `durationMS` 和 `timingSource` 均有效时才参与完整请求 TPS。 |
| `estimatedDurationMS` | 可选正数 | 从会话日志事件边界估算的耗时，单位为毫秒，有限且小于 7,200,000。估算值不写入 `durationMS`。 |
| `estimatedTimingSource` | 可选非空字符串 | 估算依据，例如 `codex-session-log` 或 `claude-session-log`。与 `estimatedDurationMS` 同时有值或同时缺失。 |
| `inputTokens`、`outputTokens` | 非负整数 | 未缓存输入、全部输出；均不重复记入其他桶。 |
| `cacheReadTokens`、`cacheWriteTokens` | 非负整数 | 缓存读取和创建量，独立于 `inputTokens`。 |
| `reasoningTokens` | 可选非负整数 | 输出中属于推理的部分；不能大于输出，不额外加到 Token 总数。 |
| `cacheWrite5mTokens`、`cacheWrite1hTokens` | 可选非负整数 | 仅来源提供 TTL 明细时记录。都是 `cacheWriteTokens` 的子项，不另加到总数。 |
| `source` | 可选字符串 | 采集来源，便于解释或排查。 |

所有 Token 数字段单项上限 `1_000_000_000_000`，避免异常值和跨语言整数问题。写入方使用相互独立的未缓存输入、缓存读、缓存写、输出桶。对包含缓存读的输入总数，应先减去缓存读（及已包含的缓存写）再写 `inputTokens`。

## 使用文件重建面板

- 请求数为归并后的请求记录数。Token 数 = 未缓存输入 + 缓存读 + 缓存写 + 输出。按时间、会话或其它维度筛选都在请求层操作。
- 缓存命中率 = Σ缓存读 ÷ (Σ未缓存输入 + Σ缓存读 + Σ缓存写)，分母为零时缺失，不做逐条百分比平均。
- 完整请求 TPS = `outputTokens * 1000 / durationMS`。只接受具备完整耗时证据、输出大于零且未明确失败的请求；聚合值为这些样本的算术平均，同时保留样本数。
- 估算 TPS 明细只接受缺少完整耗时证据、未明确失败、输出为正、估算间隔大于零且小于 2 小时、速率不超过 10,000 tok/s 的请求，用 `estimatedDurationMS` 作分母。汇总继续只纳入输出至少 1,000 Token、估算间隔至少 1 秒的样本，计算「合计输出 Token ÷ 合计估算秒数」。两处均标为 `≥`。有完整耗时证据的请求只参与完整请求 TPS；两套样本不混合。
- 等效 API 费用从输入、输出、缓存读、缓存写的模型费率和服务等级倍率推导。费率、倍率、汇总、缓存率和 TPS 都不写入文件；消费端需要使用相同版本的费率和倍率设置才能重现相同金额。模型、长上下文和费率匹配规则见[指标口径说明](METRICS.md)。
- 请求的模型、账号、设备名等元数据会随分片同步。同步文件不含提示词、回复、工具参数、工具结果、会话标题、凭据或 WebDAV 配置。文件在服务器上为可读 JSON，可用于第三方面板。
- v1 读者忽略未知字段和旧版 `sessionTitle`；写入方只序列化本规范列出的用量字段，避免转存正文或来源不明的扩展。本机同步时会在 ETag 保护下清理所属旧分片的未列出字段，其他设备仍只读。估算耗时字段是 v1 的可选扩展，旧分片不必迁移。降级后的写入方可能从**自身**分片移除不认识的估算字段；升级后可用仍在的原始日志重新采集。修改现有字段含义或添加必须跨降级保留的字段时，升级协议目录和版本。

## 手动导出与外部采集器

应用的「导出用量」生成独立的 `{"schemaVersion":1,"requests":[...],"deviceNames":{...}}` 文件，包含当前已读取的设备历史，使用同一请求结构，不需要月份。应用也能直接导入单个 WebDAV 分片。外部采集器如为已有请求补充耗时，应从导出的记录中保留原 `deviceID`、`id`、`sessionID`、客户端、模型与 Token 桶；完整请求计时写入 `durationMS` 与 `timingSource`，日志估算单独写入 `estimatedDurationMS` 与 `estimatedTimingSource`。来自当前设备 ID 的导入记录可以随本机同步；其他设备的导入保留在本机视图，不由本机代发。

## 本地互操作验证

在项目根目录运行 `python3 scripts/verify-webdav.py`。测试通过临时回环 WebDAV 服务检查多设备多月归并、ETag 冲突重试、弱 ETag 保护、部分同步、条件读取、本设备旧标识修正，以及不转写正文或旧标题。测试不访问配置中的 WebDAV 服务。
