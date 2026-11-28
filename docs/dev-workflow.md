# 开发与分支协作流程（个人 Fork 归档）

本文档记录 **BaoCode** 个人 fork（`payAgain/baocode`，跟踪上游 `baocode-dev/baocode`）的分支使用约定、日常开发闭环、上游同步与个人渠道发版核对清单。个人自动更新机制与详细签名参数另见 [personal-updates.md](personal-updates.md)。

## 1. 远端与分支拓扑

- **`origin`**：`https://github.com/payAgain/baocode.git`（个人开发备份与个人渠道发布）。
- **`upstream`**：`https://github.com/baocode-dev/baocode.git`（官方上游，只读同步，严禁向其推送）。

| 分支类型 | 命名示例 | 职责与来源 | 合入目标 | 清理策略 |
| --- | --- | --- | --- | --- |
| 个人发布主线 | `personal/main` | 个人开发与正式发版主线，跟踪 `origin/personal/main` | — | **永久保留** |
| UI 长期维护线 | `personal/ui` | 长期桌面端 UI 优化与视觉重构分支，跟踪 `origin/personal/ui` | 按需合入 `personal/main` | **永久保留** |
| 上游跟踪线 | `main` | 仅用于同步 `upstream/main`（不直接堆个人提交） | 按需合入 `personal/main` / `personal/ui` | **永久保留** |
| 短期工作分支 | `feat/*`, `fix/*`, `work/*` | 从最新目标主线切出的隔离开发或验证分支 | 验证通过后合回来源主线 | 推送主线后**核对删除** |
| 打包 / 恢复快照 | `personal/package-*`, `personal/build-*`, `recovery/*` | 特定版本出包或事故恢复现场，常含独立构建提交 | 按需归档保留 | **禁止按常规规则自动清理** |

## 2. 日常开发闭环

1. **确认现场**：动手前先运行 `git branch` 与 `git status`，确认当前分支、目标合入线及工作区状态；UI 专项改动默认基于 `personal/ui`（或从其拉出短期分支）。
2. **隔离开发**：小改动可直接在目标线提交；需隔离验证的功能从最新目标线拉取 `feat/<name>` 或 `fix/<name>`。
3. **编码与多语言**：遵循 [AGENTS.md](../AGENTS.md) 与 [ui-design-guidelines.md](ui-design-guidelines.md)；若新增或修改界面文案，同步更新 `lib/l10n/app_en.arb` 与 `lib/l10n/app_zh.arb` 并执行 `flutter pub get`。
4. **提交前验证**：
   ```sh
   dart format <changed_files>
   dart analyze <changed_paths>
   flutter analyze --fatal-infos
   flutter test test/<subdir_or_file>
   ```
   > 仅运行与改动相关的针对性测试，避免无必要地触发耗时且占资源的完整 `flutter test`。
5. **提交与合并**：提交信息遵循 `type(scope): summary`（如 `fix(ide): ...`、`feat(bots): ...`）。合回目标线时能快进优先 `--ff-only` / 快进合并；存在分叉时采用普通合并保留清晰历史。
6. **主线推送后清理已合入短期分支**（仅清理确认合入的 `feat/*`、`fix/*`、`work/*`）：
   ```sh
   git fetch --prune origin
   git branch --merged origin/personal/main
   git branch -r --merged origin/personal/main
   git branch -d <merged-branch>
   git push origin --delete <merged-branch>
   ```
   绝不删除 `main`、`personal/main`、`personal/ui` 及带独立构建/恢复历史的快照分支。

## 3. 同步官方上游版本

1. 获取上游指定正式标签：
   ```sh
   git fetch upstream tag v<x.y.z>
   ```
2. 合入标签：合并时若 `pubspec.yaml` 与 `lib/update/version.dart` 产生冲突，**先保留原有个人版本**，完成普通合并并提交。
3. 同步个人版本号基线（确认标签已合入后执行，重置为 `<x.y.z>+0`）：
   ```sh
   dart run tool/bump_version.dart --personal v<x.y.z>
   ```
4. 执行静态分析与核心改动模块测试，确认无回归后再继续开发或发版。

## 4. 个人渠道发版简明 Checklist

> ⚠️ 未经用户明确指令，严禁主动递增版本号、执行 `git push` 或触发发布。

- [ ] **前置确认**：明确目标发布平台（如仅 macOS，还是同时含 Windows），核对目标分支与干净工作树，确认静态检查及重点测试通过。
- [ ] **递增 build 号**：执行 `dart run tool/bump_version.dart --personal` 并提交版本变更（确保 `pubspec.yaml`、`lib/update/version.dart`、Git Tag 三者版本一致）。
- [ ] **本地编译打包**：
  - macOS：`dart run tool/build_macos.dart`（产出 `build/installers/BaoCode-<ver>-mac-*.zip` 与 `.dmg`）
  - Windows：`dart run tool/build_windows.dart`（需本机安装 Inno Setup）
- [ ] **签名并生成更新清单**：
  ```sh
  BAOCODE_UPDATE_SIGNING_KEY="$HOME/.local/share/baocode-personal-signing/update-signing.key" \
    dart run tool/release_manifest.dart --personal \
    --macos-arm64 "build/installers/BaoCode-<ver>-mac-arm64.zip" \
    --dmg-arm64 "build/installers/BaoCode-<ver>-mac-arm64.dmg" \
    --notes-zh '<更新说明>'
  ```
- [ ] **发布与回读校验**：推送 `v<ver>` 标签并在 `payAgain/baocode` 创建 Release，上传所有清单指向的安装包与 `build/personal-release/latest.json`，发布后回读清单 URL 验证版本号与下载地址有效。
