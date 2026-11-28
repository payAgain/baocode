---
name: baocode-desktop-ui
description: >-
  Use when designing, building, refactoring, or debugging BaoCode Flutter desktop UI
  (Bot Hub, chats, groups, remote workspace sidebars/dialogs, settings) to apply BaoCode's
  modern design tokens, multi-theme compatibility, Flutter pitfalls checklist, and
  Bao Dark + Dark Modern preview verification.
---

# BaoCode Desktop UI Development

Use this skill whenever modifying desktop UI widgets or styles in BaoCode (`lib/bots/`, `lib/link/`, `lib/settings/`, `lib/chat/`, `lib/sidebar/`, `lib/ide/`). Detailed rationale and full token tables live in [../../docs/ui-design-guidelines.md](../../docs/ui-design-guidelines.md).

## Workflow

### 1. Inspect Test Contracts Before Editing
Before changing any widget tree, grep affected test files for structural finders (`git grep`):
- Preserve required `ValueKey`s, `tooltip`s, icon constants (e.g., `Icons.arrow_upward`), and interactive widget types (`ListTile`, `Badge`, `AlertDialog`, `CheckboxListTile`, `FilledButton`, `TextButton`, `ComposerPastedTextChip`).
- Keep action icons mounted and hit-testable at rest (never wrap interactive icons with `IgnorePointer`).
- Check if a mock/fake in tests implements a service interface (e.g., `_Chats implements DesktopHostChats` in `test/link/desktop_host_page_test.dart`) and add stub overrides if new getters/methods are read by UI.

### 2. Apply BaoCode Modern Design System
- **Tokens & Containers**: Use `SettingsColors` (`card`, `stroke`, `divider`, `hover`, `textPrimary/Secondary/Quaternary`), `AppColors` (`conversationSurface`, `bubbleFill`, `bubbleBorder()`, `code`), and `themeColors['button.background']` / `['button.foreground']`.
- **BaoCode Widgets**: Prefer `IdeSwitch`, `BotEditorLayout`, `BotEditorSection`, `BotEditorInsetField`, `BotEditorNavTile`, `BotModernDialog`, `RemoteActionDialog`, `BotAvatarBadge`, `BotMetaPill`, `BotEmptyState`, `BotEditorNotice`, `ScrollEdgeFade`.
- **Chat Feeds & Headers**:
  - Place sender names and timestamps outside and above message bubbles.
  - Group consecutive same-sender turns within 5 minutes via `shouldGroupBotMessage`, hiding repeated avatars/timestamps and tightening gap spacing.
  - Keep local private messages containing `textWithAttachments` inside `UserMessageBubble` with `DesktopBotMessageRow(bare: true)` so attachment/paste chips stay functional without double borders.
  - Use centered max-width reading columns (`600–780px`) on list hubs and `Flexible`/`Expanded` (or two-line headers) so narrow split drawers (< 450px) never overflow.

### 3. Avoid Mandatory Flutter Pitfalls
Verify your changes against every rule below before running tests:
1. **No raw M3 `colorScheme.primary`**: Dark Modern generates high-saturation cyan primary/outline colors. Always apply `botEditorButtonStyle`, `botEditorOutlinedButtonStyle`, `botEditorTonalButtonStyle`, `botEditorGhostButtonStyle`, `botToolbarIconButtonStyle`, or `remoteDialog*ButtonStyle`.
2. **Transparent dialog tint**: Set `surfaceTintColor: Colors.transparent` on any raw `AlertDialog`.
3. **Preserve font fallback**: NEVER pass bare `const TextStyle(...)` to `ButtonStyle.textStyle` or `DropdownButton.style` (strips `fontFamilyFallback` and breaks CJK glyphs). Derive via `Theme.of(context).textTheme.*?.copyWith(...)`.
4. **Proper `ListTile` Material ancestor**: NEVER put `ListTile`, `CheckboxListTile`, or `ExpansionTile` inside a colored `DecoratedBox` — always wrap in `Material(color: ..., shape: ..., clipBehavior: Clip.antiAlias)`.
5. **Menu row overflow**: Wrap text inside horizontal `PopupMenuItem` rows with `Expanded` / `Flexible`.

### 4. Verify Analysis, Targeted Tests & Dual-Theme Visuals
1. Format and analyze changed paths cleanly (`dart format`, `dart analyze`, `flutter analyze --fatal-infos`).
2. Run only the targeted tests for touched modules (e.g., `flutter test test/bots/ test/link/desktop_remote_people_test.dart`) — never run the full `flutter test` suite casually.
3. For significant layout or style changes, render headless PNG previews under **Bao Dark** (`themes/theme-bao/themes/bao-dark-color-theme.json`) and **Dark Modern** (`packages/bao_editor/assets/textmate/themes/theme-defaults/themes/dark_modern.json`, see [../../test/bots/desktop_bot_settings_preview_test.dart](../../test/bots/desktop_bot_settings_preview_test.dart)) and inspect screenshots visually for cyan leaks, clipping, truncation, and contrast. Remove any temporary preview test before finishing.
