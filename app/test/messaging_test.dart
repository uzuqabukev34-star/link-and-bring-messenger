import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:link_and_bring/messaging.dart';

void main() {
  test(
    'rejects an invalid inbox response as a recoverable format error',
    () async {
      final repository = MessagingRepository(
        MockClient(
          (_) async => http.Response(
            '{"events":[],"cursor":7,"unreadChat":0,"unreadHiring":0}',
            200,
          ),
        ),
        Uri.http('localhost'),
      );
      await expectLater(
        repository.inbox('viewer'),
        throwsA(isA<FormatException>()),
      );
    },
  );

  testWidgets(
    'retry after reopening preserves message ID and received messages are marked read',
    (tester) async {
      final changes = ValueNotifier(0);
      final attempts = <String>[];
      final read = <String>[];
      final sent = {
        'id': '1',
        'body': 'Hello',
        'sentAt': '2026-11-11T10:00:00Z',
        'isMine': true,
      };
      final reply = {
        'id': '2',
        'body': 'Hi!',
        'sentAt': '2026-11-11T10:00:01Z',
        'isMine': false,
      };
      var hasReply = false;
      final repository = MessagingRepository(
        MockClient((request) async {
          if (request.method == 'GET') {
            return http.Response(
              jsonEncode({
                'messages': [
                  if (hasReply) ...[sent, reply],
                ],
                'hasMore': false,
              }),
              200,
            );
          }
          final payload = jsonDecode(request.body) as Map<String, dynamic>;
          if (request.url.path.endsWith('/read')) {
            read.add(payload['throughId'] as String);
            return http.Response('', 204);
          }
          attempts.add(payload['clientId'] as String);
          return attempts.length == 1
              ? http.Response('', 503)
              : http.Response(jsonEncode(sent), 201);
        }),
        Uri.http('localhost'),
      );

      Future<void> openChat() => tester.pumpWidget(
        MaterialApp(
          home: ConversationPage(
            repository: repository,
            viewer: 'viewer',
            peer: const ChatPeer('peer', 'Jamie'),
            changes: changes,
            onRead: () {},
          ),
        ),
      );
      await openChat();
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Hello');
      await tester.pump();
      await tester.tap(find.byTooltip('Send'));
      await tester.pumpAndSettle();
      expect(find.text('Couldn’t send. Tap Send to retry.'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await openChat();
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Hello');
      await tester.pump();
      await tester.tap(find.byTooltip('Send'));
      await tester.pumpAndSettle();
      expect(attempts, hasLength(2));
      expect(attempts.first, attempts.last);
      expect(find.text('Hello'), findsOneWidget);

      hasReply = true;
      changes.value++;
      await tester.pumpAndSettle();
      expect(find.text('Hi!'), findsOneWidget);
      expect(read, contains('2'));
      await tester.pumpWidget(const SizedBox());
      changes.dispose();
    },
  );

  testWidgets('queues an earlier page during a foreground refresh', (
    tester,
  ) async {
    final changes = ValueNotifier(0);
    final refresh = Completer<http.Response>();
    final history = <String?>[];
    var latestRequests = 0;

    http.Response page(String id, String body, {required bool hasMore}) =>
        http.Response(
          jsonEncode({
            'messages': [
              {
                'id': id,
                'body': body,
                'sentAt': '2026-11-11T10:00:00Z',
                'isMine': true,
              },
            ],
            'hasMore': hasMore,
          }),
          200,
        );

    final repository = MessagingRepository(
      MockClient((request) async {
        if (request.method == 'POST') return http.Response('', 204);
        final before = request.url.queryParameters['before'];
        history.add(before);
        if (before != null) return page('1', 'Earlier', hasMore: false);
        if (++latestRequests == 2) return refresh.future;
        return page('2', 'Latest', hasMore: true);
      }),
      Uri.http('localhost'),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: ConversationPage(
          repository: repository,
          viewer: 'viewer',
          peer: const ChatPeer('peer', 'Jamie'),
          changes: changes,
          onRead: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    changes.value++;
    await tester.pump();
    await tester.tap(find.text('Load earlier messages'));
    await tester.pump();
    expect(history, [null, null]);
    refresh.complete(page('2', 'Latest', hasMore: true));
    await tester.pumpAndSettle();
    expect(history, [null, null, '2']);
    expect(find.text('Earlier'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    changes.dispose();
  });
}
