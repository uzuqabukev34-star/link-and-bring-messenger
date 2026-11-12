import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'haptics.dart';
import 'profile.dart';

class ChatPeer {
  const ChatPeer(
    this.contactId,
    this.displayName, {
    this.occupation = '',
    this.photoVersion,
  });

  final String contactId;
  final String displayName;
  final String occupation;
  final String? photoVersion;
}

class ChatSummary {
  const ChatSummary(this.peer, this.lastMessage, this.lastAt, this.unread);

  factory ChatSummary.fromJson(Map<String, dynamic> data) => ChatSummary(
    ChatPeer(
      _field<String>(data, 'contactId'),
      _field<String>(data, 'displayName'),
      occupation: _field<String>(data, 'occupation'),
      photoVersion: _field<String?>(data, 'photoVersion'),
    ),
    _field<String>(data, 'lastMessage'),
    DateTime.parse(_field<String>(data, 'lastAt')),
    _field<int>(data, 'unread'),
  );

  final ChatPeer peer;
  final String lastMessage;
  final DateTime lastAt;
  final int unread;
}

class ChatMessage {
  const ChatMessage(this.id, this.body, this.sentAt, this.isMine);

  factory ChatMessage.fromJson(Map<String, dynamic> data) => ChatMessage(
    _cursor(data, 'id'),
    _field<String>(data, 'body'),
    DateTime.parse(_field<String>(data, 'sentAt')),
    _field<bool>(data, 'isMine'),
  );

  final String id;
  final String body;
  final DateTime sentAt;
  final bool isMine;
}

typedef MessagePage = ({List<ChatMessage> messages, bool hasMore});

class InboxEvent {
  const InboxEvent(
    this.kind,
    this.subjectId,
    this.title,
    this.body,
    this.read, {
    this.id,
  });

  factory InboxEvent.fromJson(Map<String, dynamic> data) => InboxEvent(
    _field<String>(data, 'kind'),
    _field<String>(data, 'subjectId'),
    _field<String>(data, 'title'),
    _field<String>(data, 'body'),
    data['read'] == true,
    id: data['id'] == null ? null : _cursor(data, 'id'),
  );

  final String kind;
  final String subjectId;
  final String title;
  final String body;
  final bool read;
  final String? id;
}

typedef InboxPage = ({
  List<InboxEvent> events,
  String cursor,
  int unreadChat,
  int unreadHiring,
  bool hasMore,
});

T _field<T>(Map<String, dynamic> data, String key) {
  final value = data[key];
  if (value is T) return value;
  throw FormatException('Invalid messaging field: $key');
}

final _decimalId = RegExp(r'^(0|[1-9][0-9]{0,18})$');

String _cursor(Map<String, dynamic> data, String key) {
  final value = _field<String>(data, key);
  if (_decimalId.hasMatch(value)) return value;
  throw FormatException('Invalid messaging cursor: $key');
}

class _PendingSend {
  final id = createUuidV4();
  Future<ChatMessage>? request;
}

class MessagingRepository {
  MessagingRepository(this._client, this._baseUrl);

  final http.Client _client;
  final Uri _baseUrl;
  final _pendingSends = <(String, String, String), _PendingSend>{};
  Uri get baseUrl => _baseUrl;

  ImageProvider? peerPhoto(String viewer, ChatPeer peer) =>
      contactPhoto(_baseUrl, viewer, peer.contactId, peer.photoVersion);
  static const _timeout = Duration(seconds: 8);

  Future<List<ChatSummary>> chats(String viewer) async {
    final data = await _get(viewer, '/api/chats');
    return _items(data, 'chats').map(ChatSummary.fromJson).toList();
  }

  Future<MessagePage> messages(
    String viewer,
    String contactId, {
    String? before,
  }) async {
    final data = await _get(
      viewer,
      '/api/chats/$contactId',
      query: {'before': ?before},
    );
    return (
      messages: _items(data, 'messages').map(ChatMessage.fromJson).toList(),
      hasMore: data['hasMore'] == true,
    );
  }

  Future<ChatMessage> send(String viewer, String contactId, String body) async {
    final key = (viewer, contactId, body);
    final pending = _pendingSends.putIfAbsent(key, _PendingSend.new);
    return pending.request ??= _sendPending(key, pending);
  }

  Future<ChatMessage> _sendPending(
    (String, String, String) key,
    _PendingSend pending,
  ) async {
    final (viewer, contactId, body) = key;
    try {
      final response = await _post(viewer, '/api/chats/$contactId', {
        'body': body,
        'clientId': pending.id,
      });
      if (const {400, 403, 404, 409}.contains(response.statusCode)) {
        if (identical(_pendingSends[key], pending)) _pendingSends.remove(key);
      }
      final message = ChatMessage.fromJson(_json(response, 201));
      if (identical(_pendingSends[key], pending)) _pendingSends.remove(key);
      return message;
    } finally {
      pending.request = null;
    }
  }

  void clearPendingSends(String viewer) {
    _pendingSends.removeWhere((key, _) => key.$1 == viewer);
  }

  Future<void> readChat(
    String viewer,
    String contactId,
    String throughId,
  ) async {
    final response = await _post(viewer, '/api/chats/$contactId/read', {
      'throughId': throughId,
    });
    _expect(response, 204);
  }

  Future<void> registerPushDevice(String viewer, String token) async {
    final response = await _post(viewer, '/api/notifications/device', {
      'token': token,
    });
    _expect(response, 204);
  }

  Future<void> readHiring(String viewer) async {
    final response = await _post(viewer, '/api/notifications/read', {
      'kind': 'hiring',
    });
    _expect(response, 204);
  }

  Future<InboxPage> inbox(String viewer, {String? after}) async {
    final data = await _get(
      viewer,
      '/api/notifications',
      query: {'after': ?after},
    );
    return (
      events: _items(data, 'events').map(InboxEvent.fromJson).toList(),
      cursor: _cursor(data, 'cursor'),
      unreadChat: _field<int>(data, 'unreadChat'),
      unreadHiring: _field<int>(data, 'unreadHiring'),
      hasMore: _field<bool?>(data, 'hasMore') ?? false,
    );
  }

  Future<Map<String, dynamic>> _get(
    String viewer,
    String path, {
    Map<String, String>? query,
  }) async {
    final url = _baseUrl.resolve(path).replace(queryParameters: query);
    final response = await _client
        .get(url, headers: {'X-Profile-Id': viewer})
        .timeout(_timeout);
    return _json(response, 200);
  }

  Future<http.Response> _post(
    String viewer,
    String path,
    Map<String, String> data,
  ) => _client
      .post(
        _baseUrl.resolve(path),
        headers: {
          'X-Profile-Id': viewer,
          'Content-Type': 'application/json; charset=utf-8',
        },
        body: jsonEncode(data),
      )
      .timeout(_timeout);

  Map<String, dynamic> _json(http.Response response, int expected) {
    _expect(response, expected);
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is Map<String, dynamic>) return decoded;
    throw const FormatException('Invalid response');
  }

  List<Map<String, dynamic>> _items(Map<String, dynamic> data, String key) {
    final items = data[key];
    if (items is List && items.every((item) => item is Map<String, dynamic>)) {
      return items.cast<Map<String, dynamic>>();
    }
    throw const FormatException('Invalid response list');
  }

  void _expect(http.Response response, int status) {
    if (response.statusCode != status) {
      throw FormatException(
        'Messaging request failed (${response.statusCode})',
      );
    }
  }
}

class ChatListPage extends StatefulWidget {
  const ChatListPage({
    super.key,
    required this.repository,
    required this.viewer,
    required this.changes,
    required this.onOpen,
  });

  final MessagingRepository repository;
  final String viewer;
  final ValueNotifier<int> changes;
  final ValueChanged<ChatPeer> onOpen;

  @override
  State<ChatListPage> createState() => _ChatListPageState();
}

class _ChatListPageState extends State<ChatListPage> {
  List<ChatSummary>? _chats;
  bool _unavailable = false;
  bool _loading = false;
  bool _pending = false;

  @override
  void initState() {
    super.initState();
    widget.changes.addListener(_refresh);
    unawaited(_load());
  }

  @override
  void dispose() {
    widget.changes.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() => unawaited(_load());

  Future<void> _load() async {
    if (_loading) {
      _pending = true;
      return;
    }
    _loading = true;
    try {
      final chats = await widget.repository.chats(widget.viewer);
      if (mounted) {
        setState(() {
          _chats = chats;
          _unavailable = false;
        });
      }
    } on Exception {
      if (mounted) setState(() => _unavailable = true);
    } finally {
      _loading = false;
      if (_pending && mounted) {
        _pending = false;
        unawaited(_load());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final chats = _chats;
    if (chats == null && !_unavailable) {
      return const Center(child: CircularProgressIndicator());
    }
    return RefreshIndicator.adaptive(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
        children: [
          if (_unavailable)
            TextButton(
              onPressed: _load,
              child: const Text('Couldn’t load chats. Try again.'),
            ),
          if (chats?.isEmpty == true)
            Padding(
              padding: const EdgeInsets.only(top: 44),
              child: Text(
                'Open a contact to start a chat.',
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ),
          for (final chat in chats ?? const <ChatSummary>[]) ...[
            ListTile(
              contentPadding: const EdgeInsets.symmetric(vertical: 3),
              leading: _ChatAvatar(
                chat.peer.displayName,
                photo: widget.repository.peerPhoto(widget.viewer, chat.peer),
                radius: 25,
              ),
              title: Text(
                chat.peer.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              isThreeLine: true,
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    chat.peer.occupation,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    chat.lastMessage,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
              trailing: chat.unread == 0
                  ? null
                  : Badge.count(
                      count: chat.unread,
                      backgroundColor: scheme.primary,
                      textColor: scheme.onPrimary,
                    ),
              onTap: () => widget.onOpen(chat.peer),
            ),
            const Divider(height: 1),
          ],
        ],
      ),
    );
  }
}

class ConversationPage extends StatefulWidget {
  const ConversationPage({
    super.key,
    required this.repository,
    required this.viewer,
    required this.peer,
    required this.changes,
    required this.onRead,
    this.onSent,
  });

  final MessagingRepository repository;
  final String viewer;
  final ChatPeer peer;
  final ValueNotifier<int> changes;
  final VoidCallback onRead;
  final VoidCallback? onSent;

  @override
  State<ConversationPage> createState() => _ConversationPageState();
}

class _ConversationPageState extends State<ConversationPage> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  List<ChatMessage>? _messages;
  String? _error;
  String? _readThrough;
  bool _hasMore = false;
  bool _loading = false;
  bool _pending = false;
  bool _earlierPending = false;
  bool _sending = false;
  bool _reading = false;

  String get _peer => widget.peer.contactId;

  @override
  void initState() {
    super.initState();
    widget.changes.addListener(_refresh);
    _scroll.addListener(_markVisibleRead);
    unawaited(_load());
  }

  @override
  void dispose() {
    widget.changes.removeListener(_refresh);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _refresh() => unawaited(_load());

  Future<void> _load({bool earlier = false}) async {
    if (_loading) {
      if (earlier) {
        _earlierPending = true;
      } else {
        _pending = true;
      }
      return;
    }
    _loading = true;
    try {
      final current = _messages ?? const <ChatMessage>[];
      final batch = await widget.repository.messages(
        widget.viewer,
        _peer,
        before: earlier && current.isNotEmpty ? current.first.id : null,
      );
      if (!mounted) return;
      final overlap =
          current.isEmpty ||
          batch.messages.isEmpty ||
          BigInt.parse(batch.messages.first.id) <=
              BigInt.parse(current.last.id);
      setState(() {
        if (earlier ||
            !overlap ||
            current.isEmpty ||
            current.first.id == batch.messages.firstOrNull?.id) {
          _hasMore = batch.hasMore;
        }
        _messages = _merge(
          earlier || overlap ? _messages : null,
          batch.messages,
        );
        _error = null;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => _markVisibleRead());
    } on Exception {
      if (mounted) {
        setState(() => _error = 'Couldn’t load messages. Try again.');
      }
    } finally {
      _loading = false;
      final loadEarlier = _earlierPending && _hasMore;
      _earlierPending = false;
      if (mounted && loadEarlier) {
        unawaited(_load(earlier: true));
      } else if (_pending && mounted) {
        _pending = false;
        unawaited(_load());
      }
    }
  }

  List<ChatMessage> _merge(
    List<ChatMessage>? current,
    List<ChatMessage> incoming,
  ) {
    final byId = {
      for (final item in current ?? const <ChatMessage>[]) item.id: item,
      for (final item in incoming) item.id: item,
    };
    return byId.values.toList()
      ..sort((a, b) => BigInt.parse(a.id).compareTo(BigInt.parse(b.id)));
  }

  void _markVisibleRead() {
    if (!mounted ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.paused ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.hidden ||
        _reading ||
        !_scroll.hasClients ||
        _scroll.offset > 36 ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    final latest = _messages?.lastOrNull;
    if (latest == null || latest.id == _readThrough) return;
    unawaited(_read(latest.id));
  }

  Future<void> _read(String through) async {
    _reading = true;
    try {
      await widget.repository.readChat(widget.viewer, _peer, through);
      if (!mounted) return;
      _readThrough = through;
      widget.onRead();
    } on Exception {
      return;
    } finally {
      _reading = false;
    }
    _markVisibleRead();
  }

  Future<void> _send() async {
    final body = _input.text.trim();
    if (_sending || body.isEmpty) return;
    if (body.runes.length > 2000) {
      setState(() => _error = 'Use up to 2,000 characters.');
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final message = await widget.repository.send(widget.viewer, _peer, body);
      if (!mounted) return;
      if (_input.text.trim() == body) _input.clear();
      setState(() => _messages = _merge(_messages, [message]));
      widget.onSent?.call();
      unawaited(AppHaptics.selectionClick());
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients) _scroll.jumpTo(0);
      });
    } on Exception {
      if (mounted) setState(() => _error = 'Couldn’t send. Tap Send to retry.');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final messages = _messages;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.peer.displayName),
        centerTitle: true,
        titleTextStyle: theme.textTheme.titleMedium,
      ),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 540),
            child: Column(
              children: [
                Expanded(
                  child: messages == null && _error == null
                      ? const Center(child: CircularProgressIndicator())
                      : ListView.builder(
                          controller: _scroll,
                          reverse: true,
                          padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
                          itemCount:
                              (messages?.length ?? 0) + (_hasMore ? 1 : 0),
                          itemBuilder: (context, index) {
                            if (index == messages!.length) {
                              return Center(
                                child: TextButton(
                                  onPressed: () => _load(earlier: true),
                                  child: const Text('Load earlier messages'),
                                ),
                              );
                            }
                            return _bubble(
                              messages[messages.length - index - 1],
                            );
                          },
                        ),
                ),
                if (_error case final String error)
                  Semantics(
                    liveRegion: true,
                    child: TextButton(onPressed: _refresh, child: Text(error)),
                  ),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 3, 8, 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _input,
                          minLines: 1,
                          maxLines: 4,
                          onChanged: (_) => setState(() {}),
                          textCapitalization: TextCapitalization.sentences,
                          decoration: const InputDecoration(
                            hintText: 'Message',
                            border: InputBorder.none,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Send',
                        color: theme.colorScheme.primary,
                        onPressed:
                            _sending ||
                                _input.text.trim().isEmpty ||
                                messages == null
                            ? null
                            : _send,
                        icon: _sending
                            ? const SizedBox.square(
                                dimension: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.send_outlined),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _bubble(ChatMessage message) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (background, foreground) = switch ((
      message.isMine,
      scheme.brightness,
    )) {
      (true, _) => (scheme.surfaceContainerLow, scheme.onSurface),
      (false, Brightness.light) => (scheme.primary, scheme.onPrimary),
      (false, Brightness.dark) => (
        scheme.primaryContainer,
        scheme.onPrimaryContainer,
      ),
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        mainAxisAlignment: message.isMine
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!message.isMine) ...[
            _ChatAvatar(
              widget.peer.displayName,
              photo: widget.repository.peerPhoto(widget.viewer, widget.peer),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
              decoration: BoxDecoration(
                color: background,
                border: message.isMine
                    ? Border.all(color: theme.dividerColor)
                    : null,
                borderRadius: BorderRadius.circular(16),
              ),
              child: SelectableText(
                message.body,
                style: TextStyle(color: foreground),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ChatAvatar extends StatelessWidget {
  const _ChatAvatar(this.name, {this.photo, this.radius = 16});

  final String name;
  final ImageProvider? photo;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return CircleAvatar(
      radius: radius,
      backgroundColor: scheme.surfaceContainerHighest,
      foregroundColor: scheme.primary,
      foregroundImage: photo,
      onForegroundImageError: photo == null ? null : (_, _) {},
      child: Text(name.trim().characters.firstOrNull?.toUpperCase() ?? '?'),
    );
  }
}
