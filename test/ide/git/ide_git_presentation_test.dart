import 'package:baocode/ide/git/ide_git_presentation.dart';
import 'package:baocode/ide/ide_button.dart';
import 'package:baocode/l10n/l10n.dart';
import 'package:baocode/theme/codicons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('narrow Git commit actions are both visible and tappable', (
    tester,
  ) async {
    final actions = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 110,
              child: IdeGitCommitActions(
                onCommit: () => actions.add('commit'),
                onPush: () => actions.add('push'),
              ),
            ),
          ),
        ),
      ),
    );

    final row = tester.getRect(find.byType(IdeGitCommitActions));
    for (final icon in [Codicons.gitCommit, Codicons.cloudUpload]) {
      final button = find.byWidgetPredicate(
        (widget) => widget is IdeButton && widget.icon == icon,
      );
      expect(button.hitTestable(), findsOneWidget);
      expect(tester.getRect(button).right, lessThanOrEqualTo(row.right));
      await tester.tap(button);
    }
    expect(actions, ['commit', 'push']);
  });
}
