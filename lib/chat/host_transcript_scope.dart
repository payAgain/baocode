import 'package:flutter/widgets.dart';

/// The shared history is displaying content from another machine. Its file,
/// session, and media integrations must stay independent of the local app.
class HostTranscriptScope extends InheritedWidget {
  const HostTranscriptScope({super.key, required super.child});

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<HostTranscriptScope>() != null;

  static bool read(BuildContext context) =>
      context.getInheritedWidgetOfExactType<HostTranscriptScope>() != null;

  @override
  bool updateShouldNotify(HostTranscriptScope oldWidget) => false;
}
