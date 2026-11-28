# AGENTS.md

本文件为 AI 编程助手提供 **BaoCode**（个人 fork：`payAgain/baocode`，跟踪上游 `baocode-dev/baocode`）的仓库概览、构建测试命令、分支协作、编码与 UI 规范以及流程/Skill 索引。

## 1. 基本协作约定

- **自然语言**：始终使用用户当前对话的自然语言回复（继承自 `CLAUDE.md`）。
- **按需测试**：修改代码后仅运行与改动相关的针对性测试，不要随意执行全量 `flutter test`（全量测试耗时且占资源）。
- **Git 与发布边界**：未经用户明确指示，严禁主动执行 `git push`、合并主线、修改版本号或触发发布流程；任何情况下都不得向 `upstream`（`baocode-dev/baocode`）推送改动。

## 2. 项目概览与仓库结构

BaoCode 是基于 Flutter 桌面端（Dart SDK `^3.13.4`）的 Claude Code 开源控制平面与内置 IDE，采用 Dart Workspace 管理主应用与 11 个内部子包。

| 目录 / 文件 | 说明 |
| --- | --- |
| `lib/main.dart`, `lib/workbench.dart` | 桌面端应用入口与主工作台窗口 |
| `lib/ide/` | VS Code 风格 IDE（服务容器、注册表、编辑器、终端、Git、LSP），架构见 `docs/workbench-architecture.md` |
| `lib/chat/` | 对话主界面、消息流、富文本 Composer 与小地图 |
| `lib/bots/` | 本地 Bot、群聊协作、记忆管理及 Hermes 记忆导入 |
| `lib/link/` | 手机端与配对桌面互联、远程工作区及远程 Bot/群聊管理 |
| `lib/kernel/`, `lib/models/` | Agent 内核接入（Claude Code / 内置 `bao_agent` / Codex / Antigravity）与多模型协议适配代理 |
| `lib/remote/`, `lib/browser/` | SSH 远程开发主机接入与 Chrome/Edge/Arc 浏览器扩展控制 |
| `lib/settings/`, `lib/sidebar/`, `lib/customize/`, `lib/theme/`, `lib/update/`, `lib/usage/`, `lib/l10n/` | 设置页、侧边栏、插件/技能定制、主题适配、自动更新、用量统计与多语言资源 |
| `packages/` | 内部子包：`bao_agent`、`bao_editor`（MIT）、`bao_xterm`（MIT）、`bao_pty`（MIT）、`bao_conpty`、`bao_remote`、`bao_link`、`bao_iroh`、`bao_markdown`、`bao_sampler`、`bao_websearch`（应用本体为 GPL-3.0-only） |
| `tool/` | 构建打包、版本更新与工具脚本（`build_macos.dart`、`build_windows.dart`、`package_linux_deb.sh`、`build_remote_server.dart`、`bump_version.dart`、`release_manifest.dart` 等） |
| `docs/` | 流程与设计文档（详见第 7 节索引） |
| `.claude/skills/`, `.agents/skills.json` | 项目级可复用 Skill（同时服务 Claude Code / BaoCode 与 Antigravity） |
| `test/` | 主应用测试（按模块分目录，含 `flutter_test_config.dart` 与跳过的集成测试 tag 配置） |

## 3. 常用命令

- **安装依赖与生成多语言代码**（按 `l10n.yaml` 从 `app_*.arb` 生成 `app_localizations*.dart`）：
  ```sh
  flutter pub get
  ```
- **本地运行**：
  ```sh
  flutter run -d macos      # 或 flutter run -d windows
  ```
- **格式化与静态分析**（对齐 `.github/workflows/checks.yml`）：
  ```sh
  dart format <changed_files>
  dart analyze <changed_paths>
  flutter analyze --fatal-infos
  ```
- **针对性测试**：
  ```sh
  flutter test test/<subdir_or_file>
  # 例：flutter test test/bots/ test/link/desktop_remote_people_test.dart
  # 子包测试：
  (cd packages/bao_link && flutter test)
  ```
- **按需运行的跳过集成测试标签**（见 `dart_test.yaml`）：`e2e`、`lsp-smoke`、`exthost`、`ssh-e2e`、`wsl-e2e`，需显式执行：
  ```sh
  flutter test --run-skipped -t <tag>
  ```
- **代码搜索**：本机环境未安装 `rg` 时，优先使用 `git grep`。

## 4. 分支使用与个人 Fork 协作规范

完整流程与上游同步 / 清理步骤见 [docs/dev-workflow.md](docs/dev-workflow.md) 与 [docs/personal-updates.md](docs/personal-updates.md)：

- **远程仓库**：`origin` 指向 `payAgain/baocode`（个人备份与个人渠道发版）；`upstream` 指向 `baocode-dev/baocode`（官方上游只读同步）。
- **分支职责约定**：
  | 分支 | 用途与规则 |
  | --- | --- |
  | `personal/main` | 个人开发与正式发版主线（跟踪 `origin/personal/main`） |
  | `personal/ui` | 长期桌面端 UI 维护与优化分支（跟踪 `origin/personal/ui`），未受命不合并主线 |
  | `main` | 仅用于跟踪同步 `upstream/main`，不在其上直接堆积个人提交 |
  | `feat/*`, `fix/*`, `work/*` | 从最新目标线切出的短期隔离分支；验证合回并推送主线后核对清理 |
  | `personal/package-*`, `personal/build-*`, `recovery/*` | 出包/恢复历史快照，可能含独立提交，不按短期分支规则删除 |
- **操作原则**：动手前先执行 `git branch` 与 `git status` 确认当前分支与工作区现场；合回主线能快进优先快进，已有分叉使用普通合并保留清晰历史。
- **个人出包与签名安全**：常用 `tool/bump_version.dart --personal`、`tool/build_macos.dart`、`tool/build_windows.dart`、`tool/release_manifest.dart --personal`。签名私钥仅存于 `~/.local/share/baocode-personal-signing/update-signing.key`，严禁将密钥内容写入代码、日志或提交到仓库。

## 5. 架构与代码开发规范

- **改动粒度与接口维护**：一次变更聚焦一个明确主题，避免夹带无关重构；改完代码必须通过 `dart format` 与 `flutter analyze --fatal-infos`；若为服务类/接口新增方法或 getter，需同步补全测试替身（例如 `test/link/desktop_host_page_test.dart` 中的 `_Chats` mock）。
- **IDE 工作台架构**：采用显式构造函数依赖注入（无反射），通过 `ChangeNotifier` / `ValueListenable` 配合局部 `ListenableBuilder` 驱动刷新，窗口级服务通过 `WorkbenchScope.of(context)` 获取（见 [docs/workbench-architecture.md](docs/workbench-architecture.md)）。
- **UI 与多主题要点**（完整细则见 [docs/ui-design-guidelines.md](docs/ui-design-guidelines.md)）：
  - 必须兼容 **Bao Dark**、**Dark Modern**、**Light**、**High Contrast**，优先使用 `SettingsColors`、`AppColors`、`themeColors`、`IdeSwitch`、`BotEditorLayout`、`BotModernDialog`、`RemoteActionDialog` 等自有组件。
  - 禁用默认 Material 3 `colorScheme.primary`（在 Dark Modern 下会出现高饱和青色），弹窗设置 `surfaceTintColor: Colors.transparent`。
  - 切勿向 `ButtonStyle.textStyle` 或 `DropdownButton.style` 传入裸 `const TextStyle(...)`（会剥离 `fontFamilyFallback`），应通过 `Theme.of(context).textTheme.*?.copyWith(...)` 派生。
  - 切勿将 `ListTile` / `CheckboxListTile` / `ExpansionTile` 直接放入带底色的 `DecoratedBox`，必须包在 `Material(color: ..., shape: ..., clipBehavior: Clip.antiAlias)` 内。
  - 横向 `Row`（头部、徽章、`PopupMenuItem`）合理使用 `Expanded` / `Flexible`，避免窄分栏溢出。
- **本地化与许可证**：新增或修改界面文案时，同步更新 `lib/l10n/app_en.arb` 与 `lib/l10n/app_zh.arb` 并重新生成本地化类；提交代码需沿用对应目录许可证（主应用 `GPL-3.0-only`，`bao_editor` / `bao_xterm` / `bao_pty` 为 `MIT`）。
- **提交信息**：遵循 `type(scope): summary`（如 `fix(ide): ...`、`feat(bots): ...`，参考 `CONTRIBUTING.md`）。

## 6. 测试与视觉验证提示

- 调整 UI 时保留既有测试依赖的 `ValueKey`、`tooltip` 文案（如 `Icons.arrow_upward`、单一 `Retry` 按钮文本）及核心控件类型（`ListTile`、`Badge`、`AlertDialog`、`CheckboxListTile`、`FilledButton`、`TextButton`、`ComposerPastedTextChip` 等）。
- 涉及重要界面改版时，使用无头截图测试（参考 `test/bots/desktop_bot_settings_preview_test.dart`）在 **Bao Dark** 与 **Dark Modern** 双主题下检查对比度、截断与布局平衡。

## 7. 流程文档与项目 Skill 索引

- **流程与架构归档（`docs/`）**：
  - [docs/dev-workflow.md](docs/dev-workflow.md) — 分支使用拓扑、日常开发闭环、上游标签同步与个人发布核对表
  - [docs/ui-design-guidelines.md](docs/ui-design-guidelines.md) — 桌面端现代设计规范、Token 选型表与 Flutter 避坑清单
  - [docs/personal-updates.md](docs/personal-updates.md) — 个人更新渠道机制、Ed25519 清单签名与发布说明
  - [docs/workbench-architecture.md](docs/workbench-architecture.md) — IDE 工作台服务容器与状态刷新架构
- **项目内置 Skill**（真源位于 `.claude/skills/`，并通过 [.agents/skills.json](.agents/skills.json) 自动同步至 Antigravity）：
  - `baocode-desktop-ui` — 桌面端 UI 设计、主题适配、避坑核对与双主题预览验证流程
  - `baocode-git-workflow` — 分支选择与切换、开发合并、上游同步与合并后分支清理 SOP
  - `baocode-personal-release` — 个人版 build 号递增、本地出包、清单签名与 Release 发布流程
