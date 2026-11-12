import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

const _pageSize = 50;
const _maxBodyBytes = 16 * 1024;
const _maxMessageLength = 2000;
final _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  caseSensitive: false,
);
final _decimalId = RegExp(r'^(?:0|[1-9][0-9]{0,18})$');

Handler createMessagingApi(Pool<void> pool) {
  final store = _MessagingStore(pool);
  final router = Router()
    ..get('/api/chats', (Request request) {
      return _handle(request, (viewer) async {
        return _json(200, {'chats': await store.chats(viewer)});
      });
    })
    ..get('/api/chats/<contactId>', (Request request, String contactId) {
      return _handle(request, (viewer) async {
        final before = request.url.queryParameters['before'];
        final page = await store.messages(
          viewer,
          _requireUuid(contactId, 'contactId'),
          before == null ? null : _parseId(before, 'before'),
        );
        return _json(200, page);
      });
    })
    ..post('/api/chats/<contactId>', (Request request, String contactId) {
      return _handle(request, (viewer) async {
        final payload = await _readJson(request);
        final message = await store.send(
          viewer,
          _requireUuid(contactId, 'contactId'),
          _requireUuid(payload['clientId'], 'clientId'),
          _parseMessage(payload['body']),
        );
        return _json(201, message);
      });
    })
    ..post('/api/chats/<contactId>/read', (Request request, String contactId) {
      return _handle(request, (viewer) async {
        final payload = await _readJson(request);
        await store.readChat(
          viewer,
          _requireUuid(contactId, 'contactId'),
          _parseId(payload['throughId'], 'throughId'),
        );
        return _noContent();
      });
    })
    ..get('/api/notifications', (Request request) {
      return _handle(request, (viewer) async {
        final after = request.url.queryParameters['after'];
        return _json(
          200,
          await store.notifications(
            viewer,
            after == null ? null : _parseId(after, 'after', allowZero: true),
          ),
        );
      });
    })
    ..post('/api/notifications/device', (Request request) {
      return _handle(request, (viewer) async {
        final token = (await _readJson(request))['token'];
        if (token is! String ||
            !RegExp(r'^[A-Za-z0-9_:-]{1,512}$').hasMatch(token)) {
          throw const _RequestFailure(400, 'Invalid device token');
        }
        await store.registerDevice(viewer, token);
        return _noContent();
      });
    })
    ..post('/api/notifications/read', (Request request) {
      return _handle(request, (viewer) async {
        final payload = await _readJson(request);
        if (payload['kind'] != 'hiring') {
          throw const _RequestFailure(400, 'kind must be hiring');
        }
        final subjectId = payload['subjectId'];
        await store.readHiring(
          viewer,
          subjectId == null ? null : _requireUuid(subjectId, 'subjectId'),
        );
        return _noContent();
      });
    });
  return router.call;
}

class _MessagingStore {
  const _MessagingStore(this._pool);

  final Pool<void> _pool;

  Future<void> registerDevice(String viewer, String token) async {
    await _pool.runTx((tx) async {
      final profile = await tx.execute(
        Sql.named('SELECT id FROM profiles WHERE id = @viewer FOR KEY SHARE'),
        parameters: {'viewer': viewer},
      );
      if (profile.isEmpty)
        throw const _RequestFailure(404, 'Profile not found');
      await tx.execute(
        Sql.named('SELECT pg_advisory_xact_lock(hashtextextended(@token, 2))'),
        parameters: {'token': token},
        ignoreRows: true,
      );
      await tx.execute(
        Sql.named(
          'DELETE FROM push_devices WHERE token = @token AND profile_id <> @viewer',
        ),
        parameters: {'viewer': viewer, 'token': token},
      );
      await tx.execute(
        Sql.named('''
          INSERT INTO push_devices (profile_id, token, registered_at)
          VALUES (@viewer, @token, clock_timestamp())
          ON CONFLICT (profile_id) DO UPDATE
          SET token = EXCLUDED.token, registered_at = EXCLUDED.registered_at
          WHERE push_devices.token <> EXCLUDED.token
        '''),
        parameters: {'viewer': viewer, 'token': token},
      );
    });
  }

  Future<List<Map<String, Object?>>> chats(String viewer) async {
    final rows = await _pool.execute(
      Sql.named('''
        WITH related AS (
          SELECT recipient_id AS peer_id, id, body, sent_at, false AS unread
          FROM chat_messages WHERE sender_id = @viewer
          UNION ALL
          SELECT sender_id, id, body, sent_at, read_at IS NULL
          FROM chat_messages WHERE recipient_id = @viewer
        ), ranked AS (
          SELECT *,
                 row_number() OVER (PARTITION BY peer_id ORDER BY id DESC) AS latest,
                 count(*) FILTER (WHERE unread) OVER (PARTITION BY peer_id) AS unread_count
          FROM related
        )
        SELECT profiles.public_id, profiles.display_name, profiles.occupation,
               ranked.body, ranked.sent_at, ranked.unread_count, profiles.photo_version
        FROM ranked JOIN profiles ON profiles.id = ranked.peer_id
        WHERE ranked.latest = 1
        ORDER BY ranked.id DESC
      '''),
      parameters: {'viewer': viewer},
    );
    return rows
        .map(
          (row) => <String, Object?>{
            'contactId': row[0],
            'displayName': row[1],
            'occupation': row[2],
            'lastMessage': row[3],
            'lastAt': _isoTime(row[4]),
            'unread': row[5],
            'photoVersion': row[6],
          },
        )
        .toList(growable: false);
  }

  Future<Map<String, Object?>> messages(
    String viewer,
    String contactId,
    int? before,
  ) async {
    final peer = await _conversation(_pool, viewer, contactId);
    final rows = await _pool.execute(
      Sql.named('''
        SELECT id, body, sent_at, sender_id = @viewer
        FROM chat_messages
        WHERE ((sender_id = @viewer AND recipient_id = @peer)
            OR (sender_id = @peer AND recipient_id = @viewer))
          AND (@before::bigint IS NULL OR id < @before)
        ORDER BY id DESC
        LIMIT ${_pageSize + 1}
      '''),
      parameters: {'viewer': viewer, 'peer': peer.id, 'before': before},
    );
    return {
      'messages': rows
          .take(_pageSize)
          .map(_messageJson)
          .toList()
          .reversed
          .toList(),
      'hasMore': rows.length > _pageSize,
    };
  }

  Future<Map<String, Object?>> send(
    String viewer,
    String contactId,
    String clientId,
    String body,
  ) => _pool.runTx((tx) async {
    final participants = await tx.execute(
      Sql.named('''
        SELECT id, public_id, display_name FROM profiles
        WHERE id = @viewer OR public_id = @contact
        ORDER BY id FOR KEY SHARE
      '''),
      parameters: {'viewer': viewer, 'contact': contactId},
    );
    if (participants.length != 2 ||
        !participants.any((row) => row[0] == viewer)) {
      throw const _RequestFailure(404, 'Chat not found');
    }
    final sender = participants.singleWhere((row) => row[0] == viewer);
    final peer =
        participants.singleWhere((row) => row[0] != viewer)[0] as String;
    final (first, second) = viewer.compareTo(peer) < 0
        ? (viewer, peer)
        : (peer, viewer);

    // Both directions share a lock, so a smaller message ID cannot commit
    // after a larger ID that a participant has already read.
    await tx.execute(
      Sql.named('SELECT pg_advisory_xact_lock(hashtextextended(@pair, 1))'),
      parameters: {'pair': '$first:$second'},
      ignoreRows: true,
    );
    final existing = await tx.execute(
      Sql.named('''
        SELECT id, body, sent_at, true, recipient_id
        FROM chat_messages WHERE sender_id = @viewer AND client_id = @client
      '''),
      parameters: {'viewer': viewer, 'client': clientId},
    );
    if (existing.isNotEmpty) return _retryMessage(existing.single, peer, body);

    final conversation = await _conversation(tx, viewer, contactId);
    if (!conversation.connected) {
      throw const _RequestFailure(403, 'This chat is read-only');
    }
    final inserted = await tx.execute(
      Sql.named('''
        INSERT INTO chat_messages (sender_id, recipient_id, client_id, body)
        VALUES (@viewer, @peer, @client, @body)
        ON CONFLICT (sender_id, client_id) DO NOTHING
        RETURNING id, body, sent_at, true
      '''),
      parameters: {
        'viewer': viewer,
        'peer': peer,
        'client': clientId,
        'body': body,
      },
    );
    if (inserted.isEmpty) {
      // The same client ID may race in another conversation.
      throw const _RequestFailure(409, 'clientId already used');
    }
    final message = inserted.single;

    // Hiring shares this per-recipient lock, keeping each inbox in commit order.
    await tx.execute(
      Sql.named(
        'SELECT pg_advisory_xact_lock(hashtextextended(@recipient, 0))',
      ),
      parameters: {'recipient': peer},
      ignoreRows: true,
    );
    await tx.execute(
      Sql.named('''
        INSERT INTO inbox_events (recipient_id, kind, subject_id, title, body, message_id)
        VALUES (@recipient, 'message', @sender, @title, @preview, @message)
      '''),
      parameters: {
        'recipient': peer,
        'sender': sender[1],
        'title': sender[2],
        'preview': String.fromCharCodes(body.runes.take(160)),
        'message': message[0],
      },
    );
    return _messageJson(message);
  });

  Future<void> readChat(String viewer, String contactId, int throughId) async {
    final peer = await _conversation(_pool, viewer, contactId);
    final rows = await _pool.execute(
      Sql.named('''
        WITH boundary AS (
          SELECT id FROM chat_messages WHERE id = @through
            AND ((sender_id = @viewer AND recipient_id = @peer)
              OR (sender_id = @peer AND recipient_id = @viewer))
        ), marked AS (
          UPDATE chat_messages SET read_at = now()
          WHERE sender_id = @peer AND recipient_id = @viewer
            AND read_at IS NULL AND id <= (SELECT id FROM boundary)
          RETURNING id
        ), marked_events AS (
          UPDATE inbox_events SET read_at = now()
          FROM marked WHERE message_id = marked.id
            AND recipient_id = @viewer AND read_at IS NULL
        )
        SELECT id FROM boundary
      '''),
      parameters: {'viewer': viewer, 'peer': peer.id, 'through': throughId},
    );
    if (rows.isEmpty) throw const _RequestFailure(404, 'Message not found');
  }

  Future<Map<String, Object?>> notifications(String viewer, int? after) async {
    final rows = await _pool.execute(
      Sql.named('''
        WITH stats AS (
          SELECT count(*) FILTER (WHERE kind = 'message') AS unread_chat,
                 count(*) FILTER (WHERE kind = 'hiring') AS unread_hiring
          FROM inbox_events WHERE recipient_id = @viewer AND read_at IS NULL
        ), page AS (
          SELECT id, kind, subject_id, title, body, created_at, read_at IS NOT NULL AS is_read
          FROM inbox_events WHERE recipient_id = @viewer AND id > @after
          ORDER BY id LIMIT ${_pageSize + 1}
        )
        SELECT page.*,
               coalesce(@after::bigint, (
                 SELECT id FROM inbox_events
                 WHERE recipient_id = @viewer ORDER BY id DESC LIMIT 1
               ), 0) AS latest,
               stats.unread_chat, stats.unread_hiring
        FROM stats LEFT JOIN page ON true ORDER BY page.id
      '''),
      parameters: {'viewer': viewer, 'after': after},
    );
    final summary = rows.first;
    final events = [
      for (final row in rows.take(_pageSize))
        if (row[0] != null)
          {
            'id': row[0].toString(),
            'kind': row[1],
            'subjectId': row[2],
            'title': row[3],
            'body': row[4],
            'createdAt': _isoTime(row[5]),
            'read': row[6],
          },
    ];
    return {
      'events': events,
      'cursor': events.isEmpty
          ? (after ?? summary[7]).toString()
          : events.last['id'],
      'unreadChat': summary[8],
      'unreadHiring': summary[9],
      'hasMore': rows.length > _pageSize,
    };
  }

  Future<void> readHiring(String viewer, String? subjectId) async {
    await _pool.execute(
      Sql.named('''
        UPDATE inbox_events SET read_at = now()
        WHERE recipient_id = @viewer AND kind = 'hiring' AND read_at IS NULL
          AND (@subject::uuid IS NULL OR subject_id = @subject)
      '''),
      parameters: {'viewer': viewer, 'subject': subjectId},
    );
  }

  Future<({String id, bool connected})> _conversation(
    Session db,
    String viewer,
    String publicContact,
  ) async {
    final rows = await db.execute(
      Sql.named('''
        SELECT peer.id,
               EXISTS (SELECT 1 FROM link_bring_network(own.id) AS network
                 WHERE network.member_id = peer.id AND network.distance BETWEEN 1 AND 2),
               EXISTS (SELECT 1 FROM chat_messages
                 WHERE (sender_id = own.id AND recipient_id = peer.id)
                    OR (sender_id = peer.id AND recipient_id = own.id))
        FROM profiles AS own
        JOIN profiles AS peer ON peer.public_id = @publicContact AND peer.id <> own.id
        WHERE own.id = @viewer
      '''),
      parameters: {'viewer': viewer, 'publicContact': publicContact},
    );
    if (rows.isEmpty || (rows.single[1] != true && rows.single[2] != true)) {
      throw const _RequestFailure(404, 'Chat not found');
    }
    final row = rows.single;
    return (id: row[0] as String, connected: row[1] as bool);
  }
}

Map<String, Object?> _retryMessage(ResultRow row, String peer, String body) {
  if (row[4] != peer || row[1] != body) {
    throw const _RequestFailure(409, 'clientId already used');
  }
  return _messageJson(row);
}

Map<String, Object?> _messageJson(ResultRow row) => {
  'id': row[0].toString(),
  'body': row[1],
  'sentAt': _isoTime(row[2]),
  'isMine': row[3],
};

String _isoTime(Object? value) => (value as DateTime).toUtc().toIso8601String();

String _requireUuid(Object? value, String field) {
  if (value is! String || !_uuid.hasMatch(value)) {
    throw _RequestFailure(400, '$field must be a UUID v4');
  }
  return value.toLowerCase();
}

int _parseId(Object? value, String field, {bool allowZero = false}) {
  final parsed = value is String && _decimalId.hasMatch(value)
      ? int.tryParse(value)
      : null;
  if (parsed == null || (!allowZero && parsed == 0)) {
    throw _RequestFailure(400, '$field must be a decimal ID');
  }
  return parsed;
}

String _parseMessage(Object? value) {
  final body = value is String ? value.trim() : '';
  if (body.isEmpty ||
      body.runes.length > _maxMessageLength ||
      body.contains('\x00')) {
    throw const _RequestFailure(400, 'Message must contain 1–2000 characters');
  }
  return body;
}

Future<Map<String, Object?>> _readJson(Request request) async {
  final mime = request.headers['content-type']
      ?.split(';')
      .first
      .trim()
      .toLowerCase();
  if (mime != 'application/json') {
    throw const _RequestFailure(415, 'Expected application/json');
  }
  final body = BytesBuilder(copy: false);
  await for (final chunk in request.read()) {
    if (body.length + chunk.length > _maxBodyBytes) {
      throw const _RequestFailure(413, 'Request is too large');
    }
    body.add(chunk);
  }
  final decoded = jsonDecode(utf8.decode(body.takeBytes()));
  if (decoded is! Map<String, Object?>) {
    throw const _RequestFailure(400, 'Expected a JSON object');
  }
  return decoded;
}

Future<Response> _handle(
  Request request,
  Future<Response> Function(String) action,
) async {
  try {
    final viewer = _requireUuid(
      request.headers['x-profile-id'],
      'X-Profile-Id',
    );
    return await action(viewer);
  } on _RequestFailure catch (error) {
    return _json(error.status, {'error': error.message});
  } on FormatException {
    return _json(400, {'error': 'Malformed request'});
  } catch (error) {
    stderr.writeln('Messaging ${request.method} failed: ${error.runtimeType}');
    return _json(500, {'error': 'Unable to process messaging request'});
  }
}

Response _json(int status, Map<String, Object?> payload) => Response(
  status,
  body: jsonEncode(payload),
  headers: {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
  },
);

Response _noContent() => Response(204, headers: {'cache-control': 'no-store'});

class _RequestFailure implements Exception {
  const _RequestFailure(this.status, this.message);

  final int status;
  final String message;
}
