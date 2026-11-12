import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:link_and_bring/inbox_poller.dart';
import 'package:link_and_bring/messaging.dart';

InboxPage _page(String cursor, {bool hasMore = false}) => (
  cursor: cursor,
  hasMore: hasMore,
  events: [],
  unreadChat: 0,
  unreadHiring: 0,
);

void main() {
  testWidgets('drains consecutive pages and ignores paused requests', (
    tester,
  ) async {
    final requests = <({String? after, Completer<InboxPage> response})>[];
    final received = <String>[];
    final poller = InboxPoller(
      fetch: (_, {after}) {
        final response = Completer<InboxPage>();
        requests.add((after: after, response: response));
        return response.future;
      },
      onPage: (page, _, _) => received.add(page.cursor),
      isChatOpen: () => true,
    );
    addTearDown(poller.pause);

    poller.start('viewer');
    requests[0].response.complete(_page('0'));
    await tester.pump();
    unawaited(poller.poll());
    requests[1].response.complete(_page('50', hasMore: true));
    await tester.pump();
    expect(requests[2].after, '50');
    requests[2].response.complete(_page('51'));
    await tester.pump();
    expect(received, ['0', '50', '51']);

    unawaited(poller.poll());
    poller.pause();
    poller.start('viewer');
    requests[3].response.complete(_page('52'));
    await tester.pump();
    expect(received, ['0', '50', '51']);
    expect(requests[4].after, '51');
    requests[4].response.complete(_page('52'));
    await tester.pump();
    expect(received.last, '52');
    poller.pause();
  });
}
