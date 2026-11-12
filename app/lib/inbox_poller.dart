import 'dart:async';

import 'package:flutter/foundation.dart';

import 'messaging.dart';

class InboxPoller {
  InboxPoller({
    required this.fetch,
    required this.onPage,
    required this.isChatOpen,
  });

  final Future<InboxPage> Function(String viewer, {String? after}) fetch;
  final void Function(InboxPage page, String? after, bool refresh) onPage;
  final bool Function() isChatOpen;

  String? _viewer;
  String? _cursor;
  Timer? _timer;
  int _generation = 0;
  int _idlePolls = 0;
  int _failures = 0;
  bool _running = false;
  bool _refreshPending = false;

  void start(String viewer) {
    _viewer = viewer;
    unawaited(poll(refresh: true));
  }

  void pause() {
    _viewer = null;
    _generation++;
    _refreshPending = false;
    _timer?.cancel();
    _timer = null;
  }

  void reset() {
    pause();
    _cursor = null;
    _idlePolls = 0;
    _failures = 0;
  }

  Future<void> poll({bool refresh = false}) async {
    final viewer = _viewer;
    if (viewer == null) return;
    if (_running) {
      if (refresh) _refreshPending = true;
      return;
    }

    _timer?.cancel();
    _running = true;
    final generation = _generation;
    var hasMore = false;
    try {
      final after = _cursor;
      final page = await fetch(viewer, after: after);
      if (generation != _generation) return;
      if (page.hasMore &&
          after != null &&
          BigInt.parse(page.cursor) <= BigInt.parse(after)) {
        throw const FormatException('Inbox cursor did not advance');
      }
      _cursor = page.cursor;
      _failures = 0;
      _idlePolls = refresh || page.events.isNotEmpty ? 0 : _idlePolls + 1;
      hasMore = page.hasMore;
      onPage(page, after, refresh);
    } on Exception catch (error) {
      if (generation == _generation) {
        if (_failures == 0) {
          debugPrint('Inbox refresh failed: ${error.runtimeType}');
        }
        _failures++;
      }
    } finally {
      _running = false;
      if (_viewer != null) {
        if (_refreshPending || (hasMore && generation == _generation)) {
          final pending = _refreshPending;
          _refreshPending = false;
          unawaited(poll(refresh: pending));
        } else {
          final seconds = switch ((_failures, _idlePolls)) {
            (>= 3, _) => 30,
            (2, _) => 15,
            (1, _) => 6,
            (_, >= 6) when !isChatOpen() => 15,
            (_, >= 3) when !isChatOpen() => 6,
            _ => 3,
          };
          _timer = Timer(Duration(seconds: seconds), () => unawaited(poll()));
        }
      }
    }
  }
}
