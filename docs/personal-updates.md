# BaoCode 个人更新渠道

个人主线 `personal/main` 的 macOS 和 Windows 打包工具默认使用 `personal`。也可以显式传入 `--dart-define=BAOCODE_UPDATE_CHANNEL=personal`。`BAOCODE_UPDATE_URL` 只用于显式选择 `official` 的构建测试，个人构建忽略该运行时环境变量。打包工具的 `--official-updates` 选择官方渠道。`BAOCODE_CHANNEL` 仍控制原有的产品版本。

个人构建从 `https://github.com/payAgain/baocode/releases/latest/download/latest.json` 检查更新。下载链接必须来自该仓库对应版本的 Release，只有 GitHub 为该 Release 附件返回的 CDN 重定向才允许跟随。客户端用内置的个人公钥检查 Ed25519 签名，下载后和重用缓存时还会检查大小及 SHA-256。下载、解包和安装日志在数据目录的 `updates-personal/`，跳过版本、上次检查和安装记录也按渠道保存。更新说明和手动下载入口均指向 fork 的 Releases。首发前 GitHub 返回 HTTP 404 时，界面显示「个人渠道尚未发布版本」。

## 日常开发（不走 PR）

- `personal/main` 是个人开发和发版的主线，跟踪 `origin/personal/main`。保留本地 `main` 跟踪 `upstream/main`；要引入上游改动时，单独同步，不把个人改动推到 `main`。
- 小改动可以直接在 `personal/main` 上提交。需要隔离验证的改动，从最新的 `personal/main` 开一个短期 `feature/*` 或 `fix/*` 分支。提交前检查改动、格式化 Dart 文件并跑相关测试，再把已验证的分支合回 `personal/main`，无需开 PR。能快进时优先快进；已有分叉时用普通合并，保留提交历史。
- 主线推送成功后就清理已合并的短期分支。先 `git fetch --prune origin`，再用 `git branch --merged origin/personal/main` 和 `git branch -r --merged origin/personal/main` 分别核对本地和远端。只删除已确认合入的工作分支：本地用 `git branch -d <分支>`，已推送的用 `git push origin --delete <分支>`。保留 `main` 和 `personal/main`，不强删未合入的分支。临时打包或恢复分支可能有独立提交，不适用这条清理规则。

## 构建与准备发布

1. 个人版的 `x.y.z` 跟随已合入的上游正式发布。合并前从 `upstream` 获取该版本的正式标签，例如 `git fetch upstream tag v2.0.8`。合并标签时在 `pubspec.yaml` 和 `lib/update/version.dart` 中保留原有个人版本，提交合并后执行 `dart run tool/bump_version.dart --personal v2.0.8`。工具确认该上游标签对应的提交已经合入，再把两个文件同步为 `2.0.8+0`。
2. 每次个人出包执行 `dart run tool/bump_version.dart --personal`，只把当前版本的 build 加一。例如个人改动使 `2.0.7+46` 变成 `2.0.7+47`，上游版本合入后从 `2.0.8+0` 起算，首个个人发布为 `2.0.8+1`。同一个 `x.y.z` 内按顺序分配 build，已分配的编号不复用。更新器先比较 `x.y.z`，相同才比较 build。如果某个 `x.y.z` 已经发过更高 build，出包前须确认新 build 高于那些版本。
3. 提交版本变更，从该提交构建所有平台。清单默认读取 `pubspec.yaml`。提交、安装包、清单和 GitHub Release 标签对应同一个完整版本 `v<版本号>+<构建号>`，个人渠道以签名工具输出的标签为准。macOS 从仓库根目录运行 `dart run tool/build_macos.dart` 构建并生成 `.zip`（应用内更新）和 `.dmg`（手动安装）。直接编译的参数是 `flutter build macos --release --dart-define=BAOCODE_UPDATE_CHANNEL=personal`。使用刚构建的个人版产物签名。对于使用 Developer ID 的安装，后续 macOS 安装包还需要来自同一个 Apple 签名团队。
4. 个人签名 seed 存放在 `~/.local/share/baocode-personal-signing/update-signing.key`。目录权限为 `0700`，文件权限为 `0600`。只备份在受保护的位置。客户端只内置公钥。以下命令在本地签名并生成 `build/personal-release/latest.json`，同时输出个人 Release 的附件下载链接：

   ```bash
   # 将版本号替换成刚刚构建的 pubspec.yaml 营销版本
   version='<版本号>'
   BAOCODE_UPDATE_SIGNING_KEY="$HOME/.local/share/baocode-personal-signing/update-signing.key" \
     dart run tool/release_manifest.dart --personal \
     --macos-arm64 "build/installers/BaoCode-${version}-mac-arm64.zip" \
     --dmg-arm64 "build/installers/BaoCode-${version}-arm64.dmg" \
     --notes-zh '填写本次更新说明'
   ```

   Intel Mac 可以额外提供 `--macos-x64` 和 `--dmg-x64`。各平台参数见 `dart run tool/release_manifest.dart --help`。同一完整版本分批生成时，可复用同一清单路径。工具会重新验证已有的自动更新签名，并保留该版本的个人下载链接。
5. 发布时在 `payAgain/baocode` 建立同名标签的 GitHub Release。先把各平台的安装附件及 `latest.json` 上传到草稿 Release，随后发布为正式的 Latest Release。附件名需与清单完全一致。发布后回读上述固定清单 URL，核对版本、标签和下载链接。已有的官方签名版本需先手动切换为个人构建一次，之后才会走个人更新渠道。
