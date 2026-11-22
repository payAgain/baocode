# BaoCode 个人更新渠道

`custom/personal-updates` 的 release 构建默认使用 `personal`。也可以显式传入 `--dart-define=BAOCODE_UPDATE_CHANNEL=personal`。`BAOCODE_UPDATE_URL` 只用于显式选择 `official` 的构建测试，个人构建忽略该运行时环境变量。打包工具的 `--official-updates` 选择官方渠道。`BAOCODE_CHANNEL` 仍控制原有的产品版本。

个人构建从 `https://github.com/payAgain/baocode/releases/latest/download/latest.json` 检查更新。下载链接必须来自该仓库对应版本的 Release，只有 GitHub 为该 Release 附件返回的 CDN 重定向才允许跟随。客户端用内置的个人公钥检查 Ed25519 签名，下载后和重用缓存时还会检查大小及 SHA-256。下载、解包和安装日志在数据目录的 `updates-personal/`，跳过版本、上次检查和安装记录也按渠道保存。更新说明和手动下载入口均指向 fork 的 Releases。首发前 GitHub 返回 HTTP 404 时，界面显示「个人渠道尚未发布版本」。

## 构建与准备发布

1. 每次发布时通过 `dart run tool/bump_version.dart <版本号>` 同步 `pubspec.yaml` 和 `lib/update/version.dart`。清单默认读取 `pubspec.yaml`。更新检查按完整 `AppVersion` 比较，同一个营销版本可以通过更高的构建号更新。GitHub Release 标签使用完整版本 `v<版本号>+<构建号>`，每次发布用一个新标签。`bump_version.dart` 末尾打印的是官方标签命令，个人渠道使用签名工具输出的完整版本标签。
2. macOS 从仓库根目录运行 `dart run tool/build_macos.dart` 构建并生成 `.zip`（应用内更新）和 `.dmg`（手动安装）。直接编译的参数是 `flutter build macos --release --dart-define=BAOCODE_UPDATE_CHANNEL=personal`。使用刚构建的个人版产物签名。对于使用 Developer ID 的安装，后续 macOS 安装包还需要来自同一个 Apple 签名团队。
3. 个人签名 seed 存放在 `~/.local/share/baocode-personal-signing/update-signing.key`。目录权限为 `0700`，文件权限为 `0600`。只备份在受保护的位置。客户端只内置公钥。以下命令在本地签名并生成 `build/personal-release/latest.json`，同时输出个人 Release 的附件下载链接：

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
4. 发布时在 `payAgain/baocode` 建立同名标签的 GitHub Release。先把各平台的安装附件及 `latest.json` 上传到草稿 Release，随后发布为正式的 Latest Release。附件名需与清单完全一致。发布后回读上述固定清单 URL，核对版本、标签和下载链接。已有的官方签名版本需先手动切换为个人构建一次，之后才会走个人更新渠道。
