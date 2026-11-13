# 本机采集与请求计时

TokenMoon 只读已有文件，重新扫描不要求退出客户端，也不会改代理、账号或客户端设置。首次读取大历史需要时间；打开 App 期间，未修改的文件复用解析缓存。换机先让每台 Mac 采集各自本机的日志，再配置同一份 WebDAV；把同一批原始客户端日志复制到另一台 Mac 重新导入会被视为另一设备上的用量。

| 客户端 | 默认来源 | 已知边界 |
| --- | --- | --- |
| Codex | `$CODEX_HOME/sessions`、`$CODEX_HOME/archived_sessions`，默认 `~/.codex` | 用 `token_usage_record` 的响应 ID、显式压缩请求和兼容 `token_count` 快照。输入扣除缓存读写。请求档位取该请求或轮次明确记录的值，也可由同线程在该轮生效的设置补齐。子代理的用量仍归入父会话，档位读取子代理自己的线程设置。实际档位只保留响应侧提供的值。常见 `task_complete.duration_ms` 是整轮而非单次模型请求。 |
| Claude Code | `$CLAUDE_CONFIG_DIR/projects`，默认 `~/.claude/projects` | 按请求 ID 合并同一响应的内容块；旧版仅有消息 ID 时用消息 ID。输入已经是未缓存部分。请求档位来自明确的请求字段或按 ID 匹配的客户端 OTLP `speed`；`usage.speed` 是响应速度，`usage.service_tier` 是容量档位，两者都不能补写请求档位。 |
| Claude Desktop | `~/Library/Application Support/{Claude,Claude-3p}/{local-agent-mode-sessions,claude-code-sessions}` 中可读的项目 transcript | 支持使用 Claude Code 本地运行器并保存 transcript 的桌面会话。普通 Claude.ai 聊天、只在云端或隔离 VM 中且没有暴露 transcript 的会话，无法从本机读取逐请求用量。 |
| Antigravity | `~/.gemini/{antigravity,antigravity-insiders,antigravity-cli}/conversations/*.db`，CLI 也可用 `antigravity-cli/brain/*/.system_generated/logs/transcript_full.jsonl` | SQLite 只读访问 `steps.metadata` 和 `gen_metadata.data`；不查询正文或会话标题。对同一响应的多个步骤只计一次。CLI transcript 中可能缺失模型名称，保留为未知；不会拿当前配置反推旧请求。 |

只采集源中实际存在的账号、推理强度、服务等级等用量元数据；空值保持未知。不保存提示词、回复正文、工具参数与结果。会话列表只读 Codex 和 Claude Code 原生记录的本机标题元数据，缺失时显示会话 ID，不从提示词或回复生成标题。标题只用于本机界面，不写入请求、用量文件、导出或 WebDAV；仅有同步记录的远端会话没有可显示的本机标题。

历史日志里有 `request_duration_ms` 或明确的单次请求起止时可读取；整轮耗时、首字等待、生成阶段耗时和相邻事件时间差不能用作**完整请求 TPS** 的分母。没有可靠耗时的请求仍参与 Token、缓存、请求数和定价统计。

缺少完整计时的 Codex、Claude Code 和 Claude Desktop 请求，如果原始会话日志有可以关联的输入、工具返回或前一响应边界，则可以按响应附近的日志事件估算间隔。采集器保存估算间隔和来源标签；桌面界面只展示 **估算 TPS（≥）**，已采集的完整计时仍保留用于同步和兼容统计。没有关联边界的行保持未知；只导入已有请求清单不会凭相邻时间戳生成估算。估算样本的筛选与汇总规则见[指标口径](METRICS.md)。

## Claude Code 可选：记录完整请求耗时

Claude Code 的 [OpenTelemetry 文档](https://code.claude.com/docs/en/monitoring-usage#api-request-event) 定义了 `api_request` 的 `duration_ms` 和 `request_id`。如果已有本机 OpenTelemetry Collector，可把其 [file exporter](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/exporter/fileexporter) 的 OTLP JSON 日志输出到：

```
~/Library/Application Support/TokenMoon Community/Telemetry/claude-code.otlp.jsonl
```

TokenMoon 在刷新时读取 `resourceLogs[].scopeLogs[].logRecords[]` 中的 `api_request` / `api_error`。按客户端、`session.id`、`request_id` 精确匹配 transcript；计时由 telemetry 补齐，其他计数仍以已匹配的 transcript 为准。只在明确有会话与请求标识时才计数。旧日志若只有消息 ID，不能和单独导出的 OTLP 做精确去重；建议仅从支持请求 ID 的新版会话开始导出。若改了默认采集根目录，也要把遥测目录加入该客户端的自定义根目录。

示例配置（供本机已有的 OpenTelemetry Collector Contrib 使用，将路径改成绝对路径）：

```yaml
receivers:
  otlp:
    protocols:
      http:
        endpoint: 127.0.0.1:4318
processors:
  filter/tokenmoon:
    error_mode: ignore
    logs:
      log_record:
        - 'attributes["event.name"] != "api_request" and attributes["event.name"] != "api_error"'
exporters:
  file/tokenmoon:
    path: "/absolute/path/to/TokenMoon Community/Telemetry/claude-code.otlp.jsonl"
    format: json
service:
  pipelines:
    logs:
      receivers: [otlp]
      processors: [filter/tokenmoon]
      exporters: [file/tokenmoon]
```

在启动需要采集的 Claude Code 进程时指定以下环境变量，保留会话保存：

```sh
CLAUDE_CODE_ENABLE_TELEMETRY=1 \
OTEL_LOGS_EXPORTER=otlp \
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf \
OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:4318 \
OTEL_LOG_USER_PROMPTS=0 \
claude
```

应用不会自动开启 telemetry。其他客户端需要逐请求计时来源才能补齐 TPS；外部采集器可按同步规范生成明确的 `durationMS` 和 `timingSource` 后导入。Antigravity 的本机库字段参考 [Magpie 上游真实库样本](https://github.com/yetone/magpie/issues/2190) 和 [读取实现](https://github.com/yetone/magpie/blob/main/internal/sessions/antigravity_app.go)，该格式没有稳定的厂商接口承诺。
