# note ![Swift](https://img.shields.io/badge/Swift-5.9+-F05138) ![Platforms](https://img.shields.io/badge/platforms-macOS%20%7C%20Linux-lightgrey)

[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

[English](README.md) | **简体中文**

一个纯 Swift 编写的 Apple Notes 管理 CLI。在 macOS 上通过 AppleScript 直接读写
Apple Notes；在 Linux 上则操作一个与 Cloudflare D1 后端保持同步的本地 SQLite
存储。笔记正文在离开你的设备前就已端到端加密。

`note` 是 [`event`](https://github.com/FradSer/event)（Apple 提醒事项与日历）的
笔记对应版本——同样的架构，独立的后端，可两者并用。

## 功能特性

- 创建、读取、编辑、移动、删除和搜索笔记
- 将笔记归类到文件夹中
- Markdown 正文（Apple Notes 的 HTML 会在读写时与 Markdown 互转）
- 端到端加密的正文——Cloudflare 永远只能看到密文
- 支持 Markdown（默认）和 JSON 输出
- 通过 `note sync` 基于 Cloudflare D1 实现跨设备云同步
- 同时支持 macOS（AppleScript）和 Linux（本地 SQLite + 同步）

## 环境要求

- Swift 5.9 或更高版本
- **macOS** 14.0 或更高版本——通过 AppleScript 直接读写 Apple Notes
- **Linux**——没有 Apple Notes，因此 `note` 操作的是位于
  `~/.local/share/note-sync/local.db` 的本地 SQLite 数据库。先运行 `note sync`
  从 Cloudflare D1 拉取数据，之后所有命令的使用方式完全一致。

## 安装

```bash
git clone https://github.com/FradSer/note.git
cd note
swift build -c release
cp .build/release/note /usr/local/bin/
```

### 首次运行——授权（macOS）

首次运行时工具会请求对 Notes 的自动化访问权限。如果提示未出现，请手动开启：

- 系统设置 > 隐私与安全性 > 自动化 > 你的终端 > Notes

## 使用方式

### 笔记

```bash
# 列出笔记（可限定在某个文件夹内）
note notes list
note notes list --folder "Ideas"

# 查看单条笔记及其正文
note notes show --id <NOTE_ID>

# 创建笔记（正文为 Markdown；标题会成为正文的第一行）
note notes create --title "Shopping" --body $'- milk\n- eggs' --folder "Ideas"
note notes create --title "Meeting" --body-file ./notes.md

# 编辑笔记的标题和/或正文（--body 会替换整段正文）
note notes edit --id <NOTE_ID> --title "New title"
note notes edit --id <NOTE_ID> --body-file ./updated.md

# 将笔记移动到其他文件夹（文件夹不存在则自动创建）
note notes move --id <NOTE_ID> --folder "Archive"

# 按关键词搜索笔记（标题 + 正文）
note notes search --keyword "invoice"

# 删除笔记
note notes delete --id <NOTE_ID>
```

> 提示：如果 Markdown 正文以 `-`（项目符号）开头，必须写成 `--body=- milk` 或
> 通过 `--body-file` 传入，因为参数解析器会把开头的 `-` 当作选项。

### 文件夹

```bash
note folders list
note folders create --name "Work"
note folders delete --name "Work"     # 同时删除该文件夹中的笔记
```

### 同步（Cloudflare D1）

`note sync` 通过一个由 D1 支撑的 Cloudflare Worker 在多设备间同步笔记和文件夹。
笔记正文用一个仅保存在你各台设备上的密钥加密。

#### 1. 部署 Worker（一次性）

Worker 源码是 canonical [apple-sync-kit/worker](https://github.com/FradSer/apple-sync-kit/tree/main/worker)
的快照，已为 note 预配置（`ENTITIES="notes,note_folders"`）。

```bash
cd skills/apple-notes/references/worker
pnpm install
pnpm exec wrangler login
pnpm exec wrangler d1 create note-sync      # 把 database_id 填进 wrangler.toml
pnpm run db:migrate:remote                  # 创建 D1 数据表
openssl rand -hex 32 | pnpm exec wrangler secret put API_TOKEN   # 设置共享 API 令牌
pnpm run deploy                             # 会输出 https://<worker>.workers.dev
```

#### 2. 配置每台设备

```bash
export NOTE_SYNC_API_URL=https://<your-worker>.workers.dev
export NOTE_SYNC_API_TOKEN=<step 1 中的 API_TOKEN>
# NOTE_SYNC_DEVICE_ID 可选；默认为主机名

# 只需生成一次加密密钥，然后在每台设备上设置同一个值：
openssl rand -base64 32
export NOTE_ENCRYPTION_KEY=<该 base64 值>

note sync status        # 校验配置（会显示密钥是否已设置）
```

环境变量优先。若未设置，`note` 会回退到由
`note sync config --api-url <URL> --api-token <TOKEN>` 写入的配置文件
（`--device-id` 可选）。位于 `~/.config/note-sync/config.json` 的配置文件以
`0o600` 权限存储 API 令牌。**加密密钥不会被 `note` 写入磁盘——它只存在于
`NOTE_ENCRYPTION_KEY` 中。** 一旦丢失，加密的正文将无法恢复。

#### 3. 同步

```bash
note sync                       # 完整双向同步（先拉取，再推送）
note sync push                  # 单向
note sync pull
note sync --type folders        # 限定某一类实体
```

冲突按“最后写入胜出”解决：拉取时不会覆盖比服务器版本更新过的本地副本，该副本会
在下一次同步时推送上去。

#### 直接访问 D1（进阶）

无需本地存储即可读写云端副本（例如在一台临时设备上）：

```bash
note sync notes list
note sync notes show --id <ID>
note sync folders list
```

## Agent Skill

[`apple-notes`](skills/apple-notes/) skill 可让 AI agent 通过 `note` 直接管理你的 Apple Notes。

1. 确保 `note` CLI 已安装并在系统 PATH 中。
2. 安装 skill：
   ```bash
   npx skills add https://github.com/FradSer/note --skill apple-notes
   ```

## 架构

```
NoteModels  ─ 领域模型、格式化器、同步模型、HTML<->Markdown 转换器
NoteSync    ─ D1 HTTP 客户端、AES-GCM 加密、SQLite 存储、Linux 同步
NoteCommands─ 共享的同步子命令
note        ─ CLI：基于 AppleScript 的 NotesService/FolderService、macOS SyncService
skills/apple-notes/ ─ 开箱即用的 agent skill（SKILL.md），内含 Worker
```

完整的架构、同步算法和已知限制见 [CLAUDE.md](CLAUDE.md)。

## 相关项目

- [apple-sync-kit](https://github.com/FradSer/apple-sync-kit) — 共享的同步库和
  canonical D1 Worker（`worker/`），驱动 `note sync`
- [event](https://github.com/FradSer/event) — Apple 提醒事项与日历的配套 CLI；
  同样的架构，独立的后端

## 许可证

MIT
