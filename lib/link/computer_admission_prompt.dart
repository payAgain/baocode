import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'computer_admission_review.dart';
import 'link_host.dart';

final _reviewsByHost = Expando<_ReviewPresentation>();
final _deferred = Expando<bool>();

_ReviewPresentation _reviewsFor(LinkHost host) =>
    _reviewsByHost[host] ??= _ReviewPresentation();

class _ReviewPresentation extends ChangeNotifier {
  int _inlineViews = 0;
  bool promptOpen = false;

  bool get manualOpen => _inlineViews > 0;

  void openManual() {
    if (++_inlineViews == 1) notifyListeners();
  }

  void closeManual() {
    if (--_inlineViews == 0) notifyListeners();
  }

  void releasePrompt() {
    promptOpen = false;
    notifyListeners();
  }
}

/// The visible sidebar owns the inline review until it is hidden or removed.
VoidCallback ownInlineComputerReview(LinkHost host) {
  final reviews = _reviewsFor(host);
  reviews.openManual();
  return reviews.closeManual;
}

/// Shows an incoming admission in the main workbench's root navigator.
class ComputerAdmissionPrompt {
  ComputerAdmissionPrompt(this.host, this._context)
    : _reviews = _reviewsFor(host) {
    host.addListener(_schedule);
    _reviews.addListener(_schedule);
    _schedule();
  }

  final LinkHost host;
  final BuildContext Function() _context;
  final _ReviewPresentation _reviews;
  ({ComputerGroupApproval request, DialogRoute<void> route})? _shown;
  bool _scheduled = false;
  bool _disposed = false;

  ComputerGroupApproval? get _pending =>
      host.groupConnectionsAvailable ? host.pendingGroupApproval : null;

  bool _canShow(ComputerGroupApproval request) =>
      !_reviews.manualOpen &&
      !_reviews.promptOpen &&
      _deferred[request] != true;

  void _schedule() {
    if (_disposed) return;
    final request = _pending;
    if (request != null && _reviews.manualOpen) {
      // Closing an inline review leaves it pending without opening a second UI.
      _deferred[request] = true;
    }
    final shown = _shown;
    final changed = shown != null
        ? request != shown.request || _reviews.manualOpen
        : request != null && _canShow(request);
    if (!changed || _scheduled) return;
    _scheduled = true;
    final binding = WidgetsBinding.instance;
    binding.addPostFrameCallback((_) {
      _scheduled = false;
      if (!_disposed) _reconcile();
    });
    binding.ensureVisualUpdate();
  }

  void _reconcile() {
    final request = _pending;
    if (_shown?.request == request && !_reviews.manualOpen) return;
    _removeRoute();
    if (request == null || !_canShow(request)) return;
    final context = _context();
    final navigator = Navigator.maybeOf(context, rootNavigator: true);
    if (navigator == null) return;
    final route = DialogRoute<void>(
      context: context,
      themes: InheritedTheme.capture(from: context, to: navigator.context),
      animationStyle: AnimationStyle.noAnimation,
      builder: (context) => Dialog(
        backgroundColor: AppColors.surface,
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: AppColors.partBorder),
        ),
        child: SizedBox(
          width: 500,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ComputerApprovalPanel(host: host, request: request),
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: TextButton(
                    onPressed: () {
                      if (_shown?.request != request) return;
                      _deferred[request] = true;
                      _removeRoute();
                    },
                    child: Text(
                      Localizations.localeOf(context).languageCode == 'zh'
                          ? '稍后处理'
                          : 'Later',
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    _shown = (request: request, route: route);
    _reviews.promptOpen = true;
    unawaited(
      navigator.push(route).then((_) {
        if (_shown?.route != route) return;
        // Barrier, Escape, or Navigator dismissal defers this exact request.
        _deferred[request] = true;
        _shown = null;
        _reviews.releasePrompt();
      }),
    );
  }

  void _removeRoute() {
    final shown = _shown;
    if (shown == null) return;
    _shown = null;
    final route = shown.route;
    final navigator = route.navigator;
    if (navigator != null && navigator.mounted && route.isActive) {
      // Settings or another modal can be above this prompt.
      navigator.removeRoute(route);
    }
    _reviews.releasePrompt();
  }

  void dispose() {
    _disposed = true;
    host.removeListener(_schedule);
    _reviews.removeListener(_schedule);
    if (_shown == null) return;
    final binding = WidgetsBinding.instance;
    binding.addPostFrameCallback((_) => _removeRoute());
    binding.ensureVisualUpdate();
  }
}
