# TokenMoon

**在 Mac 上看清 AI 工具用了多少 Token、哪些请求花得多，以及订阅额度还剩多少。**

TokenMoon 是一个原生 macOS 用量看板。它读取本机已有的客户端日志，把用量整理成可筛选的图表和请求明细。无需运行独立服务；想汇总多台设备时，可以连到自己的 WebDAV。

[版本发布](https://github.com/YosakiKugatsu/TokenMoon-macOS/releases) · [数据源](docs/collectors.zh-CN.md) · [WebDAV 规范](docs/SYNC.md) · [GPL v3](LICENSE)

## 项目特点

- **本机采集**：支持 Codex、Claude Code、Claude Desktop 和 Antigravity。支持的字段取决于客户端版本和日志中实际记录的内容。
- **按请求追溯**：按时间、模型、设备、账号、工具和状态筛选，查看 Token、缓存命中、估算 TPS、等效费用和会话分布。
- **订阅额度**：从支持的本机官方客户端读取额度和重置时间。读不到新数据时，旧读数会标明时间；有足够观测值才显示预测。
- **菜单栏常驻**：看近 24 小时用量或订阅额度，也可以设置为登录 macOS 后静默启动。
- **可选的多设备同步**：用自己的 HTTPS WebDAV 同步用量，或用 TokenMoon JSON 手动导入、导出。

## 构建与上手

需要 **macOS 26 或更新版本**、**Xcode 26 或更新版本**（Swift 6.2+）。v0.0.1 提供源码，构建脚本生成当前 Mac 架构的应用。

```sh
git clone https://github.com/YosakiKugatsu/TokenMoon-macOS.git
cd TokenMoon-macOS
git checkout v0.0.1
bash scripts/build-app.sh
open dist/TokenMoon.app
```

脚本默认使用本地临时签名，不需要开发者证书。应用构建完成后，可把 `dist/TokenMoon.app` 移到「应用程序」再打开；如果使用登录项，建议先把应用放到固定位置。

1. 打开应用，等首次扫描完成。到「设置 → 数据源」查看扫描路径和已读数量，也可以手动指定目录。
2. 在观测台按需筛选，或点击菜单栏读数打开用量浮窗。
3. 到「设置 → 外观 → 通用」开启「登录时启动 TokenMoon」；若 macOS 要求批准，按提示到系统设置允许。
4. 需要多设备同步时，在「设置 → 同步」填写已有的 HTTPS WebDAV 目录并手动同步一次，再按需开启自动同步。服务端需要支持条件请求和强 ETag；详见[同步规范](docs/SYNC.md)。

## 数据、隐私和统计口径

- 默认在本机采集与保存；不会向项目维护者上传用量。应用通过已登录的官方客户端读取额度，也可以按需刷新 [models.dev](https://models.dev/) 的公开模型目录和价目。
- 本地数据位于 `~/Library/Application Support/TokenMoon Community/`，WebDAV 密码存入 macOS 钥匙串。同步和导出会包含记录中的账号、设备名、模型、时间与 Token 等用量元数据；**不要把真实导出或同步文件贴到公开 Issue**。
- 不把原始日志、提示词、回复正文、附件、工具参数或会话标题写入同步分片或导出文件。已保存的会话标题只用于本机显示。
- 等效费用是按公开价目或导入价目计算的参考值，**不是账单或订阅扣减金额**。未知价格会单独标记。日志估算 TPS 不等于模型生成速度；见[指标口径](docs/METRICS.md)和[额度预测说明](docs/QUOTA-FORECAST.md)。

## 开发与贡献

```sh
swift test
python3 scripts/verify-webdav.py
```

第二条命令用本机回环 WebDAV 测试条件写入、同步冲突和缓存恢复，不使用真实账号。欢迎提交 Issue 或 PR，先阅读[贡献指南](CONTRIBUTING.md)。安全问题请使用[安全报告说明](SECURITY.md)。

此仓库发布 **macOS 客户端**，包含对同步格式的读取和写入。服务端、网关插件和 Web 看板不包含在本仓库中。

## 许可证

本项目自有代码采用 [GNU GPL v3（GPL-3.0-only）](LICENSE)。随附的 models.dev 数据采用其上游 MIT 许可，见[第三方声明](THIRD_PARTY_NOTICES.md)。
