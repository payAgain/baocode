# 桌面端 UI 设计与开发规范（归档）

本文档沉淀 **BaoCode** 桌面端 UI 重构与主题适配的设计标准、组件选型和 Flutter 常见陷阱，适用于聊天界面、Bot 与群聊、远程工作区侧栏/对话及各类弹窗面板。

## 1. 设计定位与多主题约束

- **视觉调性**：现代、克制、信息层次清晰的桌面原生工具体验（对齐 Cursor / Linear / macOS Sequoia），拒绝传统表单堆砌、裸 Material 3 胶囊按钮与无边界大面积留白。
- **四主题强制兼容**：所有界面与组件必须同时兼容 **Bao Dark**、**Dark Modern**、**Light** 与 **High Contrast**，严禁写死仅在单一深色主题下可读的颜色值。

## 2. 核心色彩 Token 与自有组件选型

| 用途 | 推荐组件 / Token | 说明与出处 |
| --- | --- | --- |
| 主画布与次级表面 | `AppColors.conversationSurface`, `AppColors.surface`, `AppColors.surfaceRaised` | `lib/theme/app_theme.dart` |
| 卡片、描边与分割线 | `SettingsColors.card`, `SettingsColors.stroke`, `SettingsColors.divider`, `SettingsColors.hover` | `lib/settings/pages/settings_widgets.dart` |
| 内凹输入框与引用底色 | `AppColors.code`, `botInputFillColor` | 引用条配左侧强调竖条；避免强边框割裂 |
| 用户消息气泡 | `AppColors.bubbleFill` + `AppColors.bubbleBorder()` | `14px` 常规圆角配尾部 `4px` 收角 |
| 开关与原生风格编辑器 | `IdeSwitch`, `BotEditorLayout`, `BotEditorSection`, `BotEditorInsetField`, `BotEditorNavTile` | `lib/ide/ide_switch.dart`, `lib/bots/desktop_bot_editor_ui.dart` |
| Bot 徽章、胶囊与空态 | `BotAvatarBadge`, `BotMetaPill`, `BotEmptyState`, `BotEditorNotice` | 渐变微透圆角方块徽章与统一提示条 |
| 现代化桌面弹窗 | `BotModernDialog`（Bot/记忆场景）, `RemoteActionDialog`（远程工作区操作） | `lib/bots/desktop_bot_editor_ui.dart`, `lib/link/desktop_remote_dialog.dart` |
| 按钮样式体系 | `botEditorButtonStyle`, `botEditorOutlinedButtonStyle`, `botEditorTonalButtonStyle`, `botEditorGhostButtonStyle`, `botToolbarIconButtonStyle`, `remoteDialog*ButtonStyle` | 主按钮显式读取 `themeColors['button.background']` / `button.foreground` |

## 3. 桌面布局与对话流规范

1. **居中阅读宽度与卡片分组**：宽屏列表页（如 Bot Hub、群聊列表、设置页面）应限制阅读容器宽度（通常 `maxWidth: 600–780`）；同组列表放入同一圆角描边 `Material` 卡片，条目间使用带左侧缩进的 `1px` `SettingsColors.divider`。
2. **Bot / 群聊消息流**：
   - 将发送者名称与时间戳**移出气泡**，置于气泡/消息卡外侧上方。
   - 使用 `shouldGroupBotMessage` 聚合同一发送者 5 分钟内的连续消息：跟随消息隐藏重复头像、名称与时间，并将上间距收敛至 `2px`（新轮次 `10px`）。
   - 长消息流外部包裹 `ScrollEdgeFade`，顶部与底部自然渐隐过渡。
   - 本地 Bot 私聊中携带附件或粘贴文本芯片（`textWithAttachments != null`）的消息，继续使用 `UserMessageBubble` 渲染，并在外层传 `DesktopBotMessageRow(bare: true)` 避免双层气泡框。
3. **窄屏与分栏溢出防护**：
   - 当右侧设置抽屉打开导致聊天区变窄（< 450px）时，头部标题与 `BotMetaPill` 需合理拆分双行或使用 `Flexible` / `Expanded`，避免 `RenderFlex` 溢出。
   - `PopupMenuItem` 内的横向 `Row` 文本必须使用 `Expanded` / `Flexible` 包裹并设置 `TextOverflow.ellipsis`。

## 4. Flutter 桌面端高频避坑清单

- **禁用默认 Material 3 `colorScheme.primary`**：在 **Dark Modern** 主题下，Flutter 从主题生成的高饱和青色会导致 `OutlinedButton`、`TextButton`、`AlertDialog` 边框或按钮严重突兀。按钮必须通过项目样式显式指定前景色与背景色。
- **消除弹窗默认着色层**：所有直接使用或封装 `AlertDialog` 的弹窗必须显式设置 `surfaceTintColor: Colors.transparent`。
- **禁止破坏按钮与下拉字体继承**：切勿给 `ButtonStyle.textStyle` 或 `DropdownButton.style` 传入裸 `const TextStyle(...)`（会剥离 `ThemeData` 注入的 `fontFamily` 与 `fontFamilyFallback`，导致中文或测试环境渲染为方块）；必须从 `Theme.of(context).textTheme.*?.copyWith(...)` 派生。
- **严禁 `ListTile` / `CheckboxListTile` 祖先材质错配**：不可将其直接放入带 `color` 的 `DecoratedBox` 中，必须使用 `Material(color: ..., shape: ..., clipBehavior: Clip.antiAlias)` 包裹，否则会触发 `Ink` 断言或水波纹渲染穿透错误。
- **谨慎指定无头测试未加载的字体族**：非代码等宽文本不要硬编码 `fontFamily: AppFonts.mono`，避免未注册 Menlo 的无头截图测试退化为 tofu 方块。

## 5. 测试契约与双主题视觉走查

- **保护既有测试契约**：修改 UI 时务必检查关联测试依赖的控件契约，例如：`ValueKey`、`tooltip` 文案、图标常量（如群聊发送按钮的 `Icons.arrow_upward`）、单一语义文本（如仅保留一个 `Retry` 按钮文案），以及 `ListTile`、`Badge`、`AlertDialog`、`CheckboxListTile`、`FilledButton`、`TextButton`、`ComposerPastedTextChip` 等控件类型。
- **悬停控件可点击性**：对需要测试定位的静默图标（如远程群聊消息的引用回复按钮），可用 `AnimatedOpacity` 做视觉淡化，但**不要包裹 `IgnorePointer`**，确保 `hitTestable()` 始终可用。
- **双主题视觉验收**：重要界面调整完成后，推荐在 **Bao Dark** 与 **Dark Modern** 两个主题下生成无头 PNG 截图（参考 [desktop_bot_settings_preview_test.dart](../test/bots/desktop_bot_settings_preview_test.dart)），直接核查对比度、按钮色彩、文本截断与窄宽布局。
