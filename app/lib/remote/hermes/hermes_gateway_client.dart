// Purpose: Hermes TUI Gateway JSON-RPC client with a verified SSH tunnel.
// 创建时间：2026-11-18 Hermes
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../link_status.dart';
import '../ssh/local_forward.dart';
import '../ssh/ssh_host_config.dart';
import '../ssh/ssh_link.dart';
import '../ssh/ssh_transport.dart';

/// Ticketed attach information returned by `hermes gateway attach --json`.
class HermesGatewayAttach {
  const HermesGatewayAttach({
    required this.url,
    required this.protocols,
    required this.profileId,
    required this.instanceId,
  });

  final Uri url;
  final List<String> protocols;
  final String profileId;
  final String instanceId;

  factory HermesGatewayAttach.fromJson(Object? raw) {
    if (raw is! Map) throw const FormatException('Attach output is not a JSON object.');
    final endpoint = raw['endpoint'];
    final urlText = raw['url'];
    final protocols = raw['protocols'];
    if (endpoint is! Map || urlText is! String || protocols is! List) {
      throw const FormatException('Attach output is missing url, protocols, or endpoint.');
    }
    final profileId = endpoint['profile_id'];
    final instanceId = endpoint['instance_id'];
    final uri = Uri.tryParse(urlText);
    if (uri == null || uri.scheme != 'ws' || uri.host.isEmpty || uri.port <= 0 || uri.path != '/api/ws') {
      throw const FormatException('Attach output contains an unsupported WebSocket endpoint.');
    }
    if (profileId is! String || instanceId is! String || protocols.any((p) => p is! String)) {
      throw const FormatException('Attach output contains invalid identity or subprotocol fields.');
    }
    final offeredProtocols = protocols.cast<String>();
    if (!offeredProtocols.contains('hermes-gateway-v1') ||
        !offeredProtocols.any((p) => p.startsWith('hermes-gateway-ticket.'))) {
      throw const FormatException(
        'Attach output is missing the Hermes Gateway version or single-use ticket subprotocol.',
      );
    }
    // Attach grants are loopback-only; SSH carries the connection to that endpoint.
    if (!{'127.0.0.1', 'localhost', '::1'}.contains(uri.host)) {
      throw const FormatException('Hermes attach did not return a loopback endpoint.');
    }
    return HermesGatewayAttach(
      url: uri,
      protocols: protocols.cast<String>(),
      profileId: profileId,
      instanceId: instanceId,
    );
  }
}

class HermesGatewayEvent {
  const HermesGatewayEvent({required this.type, required this.payload, this.sessionId, this.sequence});

  final String type;
  final Map<String, Object?> payload;
  final String? sessionId;
  final int? sequence;

  factory HermesGatewayEvent.fromParams(Object? raw) {
    if (raw is! Map || raw['type'] is! String) throw const FormatException('Invalid gateway event.');
    final payload = raw['payload'];
    return HermesGatewayEvent(
      type: raw['type'] as String,
      payload: payload is Map ? Map<String, Object?>.from(payload) : const {},
      sessionId: raw['session_id'] is String ? raw['session_id'] as String : null,
      sequence: raw['seq'] is int ? raw['seq'] as int : null,
    );
  }
}

/// Extracts user-visible failures from the Gateway's terminal/session error events.
String? hermesGatewayEventError(HermesGatewayEvent event) {
  final error = event.type == 'error'
      ? event.payload['message']
      : event.type == 'message.complete' && event.payload['status'] == 'error'
      ? event.payload['error'] ?? event.payload['failure_reason']
      : null;
  return error is String && error.trim().isNotEmpty ? error : null;
}

class HermesGatewayRequest {
  const HermesGatewayRequest({required this.id, required this.method, required this.params, this.replayed = false});

  final String id;
  final String method;
  final Map<String, Object?> params;
  final bool replayed;
}

/// JSON-RPC client for the official Hermes TUI Gateway WebSocket.
///
/// It deliberately owns only transport/protocol concerns; session UI state remains separate from
/// the DSH model-provider and chat backends.
class HermesGatewayClient {
  HermesGatewayClient(this._socket) {
    _subscription = _socket.listen(_onMessage, onError: _onSocketError, onDone: _onSocketDone, cancelOnError: true);
  }

  final WebSocket _socket;
  final _events = StreamController<HermesGatewayEvent>.broadcast(sync: true);
  final _requests = StreamController<HermesGatewayRequest>.broadcast(sync: true);
  final _connectionErrors = StreamController<Object>.broadcast(sync: true);
  final Map<String, Completer<Object?>> _pending = {};
  late final StreamSubscription<dynamic> _subscription;
  final Completer<void> _ready = Completer<void>();
  int _nextId = 0;
  bool _closed = false;
  bool _disposed = false;

  Stream<HermesGatewayEvent> get events => _events.stream;
  Stream<HermesGatewayRequest> get serverRequests => _requests.stream;
  Stream<Object> get connectionErrors => _connectionErrors.stream;
  Future<void> get ready => _ready.future;

  Future<Object?> request(String method, [Map<String, Object?> params = const {}]) {
    if (_closed || _socket.readyState != WebSocket.open) {
      return Future<Object?>.error(StateError('Hermes Gateway is not connected.'));
    }
    final id = 'dsh-${++_nextId}';
    final completer = Completer<Object?>();
    _pending[id] = completer;
    try {
      _socket.add('${jsonEncode({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params})}\n');
    } catch (error, stack) {
      _pending.remove(id);
      completer.completeError(error, stack);
    }
    return completer.future.timeout(
      const Duration(seconds: 120),
      onTimeout: () {
        _pending.remove(id);
        throw TimeoutException('Hermes Gateway request timed out: $method');
      },
    );
  }

  void restoreOpenRequests(Object? raw) {
    if (raw is! List) return;
    for (final entry in raw) {
      if (entry is! Map || entry['id'] is! String || entry['method'] is! String) continue;
      _deliverServerRequest(
        entry['id'] as String,
        entry['method'] as String,
        entry['params'] is Map ? Map<String, Object?>.from(entry['params'] as Map) : const {},
        replayed: true,
      );
    }
  }

  void respond(String id, Map<String, Object?> result) {
    if (_closed || _socket.readyState != WebSocket.open) return;
    _socket.add('${jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result})}\n');
  }

  void failRequest(String id, int code, String message) {
    if (_closed || _socket.readyState != WebSocket.open) return;
    _socket.add(
      '${jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'error': {'code': code, 'message': message},
      })}\n',
    );
  }

  void _onMessage(dynamic raw) {
    final text = switch (raw) {
      String value => value,
      List<int> bytes => utf8.decode(bytes, allowMalformed: true),
      _ => '',
    };
    for (final line in text.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      Object? decoded;
      try {
        decoded = jsonDecode(trimmed);
      } catch (_) {
        continue;
      }
      if (decoded is! Map) continue;
      final frame = Map<String, Object?>.from(decoded);
      final id = frame['id'];
      final method = frame['method'];
      if (id != null && method is String && method != 'event') {
        _deliverServerRequest(
          id.toString(),
          method,
          frame['params'] is Map ? Map<String, Object?>.from(frame['params'] as Map) : const {},
        );
        continue;
      }
      if (id != null) {
        final pending = _pending.remove(id.toString());
        if (pending == null || pending.isCompleted) continue;
        final error = frame['error'];
        if (error is Map) {
          pending.completeError(
            StateError(
              error['message'] is String
                  ? error['message'] as String
                  : 'Hermes Gateway RPC failed (${error['code'] ?? 'unknown'}).',
            ),
          );
        } else {
          pending.complete(frame['result']);
        }
        continue;
      }
      if (method == 'event') {
        try {
          final event = HermesGatewayEvent.fromParams(frame['params']);
          if (event.type == 'gateway.ready') {
            if (!_ready.isCompleted) _ready.complete();
            unawaited(request('client.capabilities', const {'server_requests': true}).catchError((_) => null));
          }
          _events.add(event);
        } catch (_) {}
      }
    }
  }

  void _deliverServerRequest(String id, String method, Map<String, Object?> params, {bool replayed = false}) {
    if (method == 'approval' || method == 'clarify') {
      _requests.add(HermesGatewayRequest(id: id, method: method, params: params, replayed: replayed));
    } else {
      // The protocol requires an explicit fast failure for requests this UI does not implement.
      failRequest(id, -32601, 'Unsupported server request: $method');
    }
  }

  void _onSocketError(Object error, StackTrace stack) => _finish(StateError('Hermes Gateway WebSocket failed.'));
  void _onSocketDone() => _finish(StateError('Hermes Gateway WebSocket closed.'));

  void _finish(Object error) {
    if (_closed) return;
    _closed = true;
    _connectionErrors.add(error);
    for (final pending in _pending.values) {
      if (!pending.isCompleted) pending.completeError(error);
    }
    _pending.clear();
    if (!_ready.isCompleted) _ready.completeError(error);
  }

  Future<void> close() async {
    if (_disposed) return;
    _disposed = true;
    _closed = true;
    for (final pending in _pending.values) {
      if (!pending.isCompleted) pending.completeError(StateError('Hermes Gateway client closed.'));
    }
    _pending.clear();
    await _subscription.cancel();
    try {
      await _socket.close(WebSocketStatus.normalClosure);
    } catch (_) {}
    await _events.close();
    await _requests.close();
    await _connectionErrors.close();
  }
}

abstract interface class HermesGatewayLink {
  HermesGatewayClient get client;

  Future<void> close({String? sessionId, String? subscriptionId});
}

/// Owns the verified SSH transport, loopback forward, and Hermes Gateway socket.
class HermesGatewaySshLink implements HermesGatewayLink {
  HermesGatewaySshLink._({
    required this.transport,
    required this.forwarder,
    required this.client,
    required this.attach,
  });

  final SshTransport transport;
  final LocalForwarder forwarder;
  @override
  final HermesGatewayClient client;
  final HermesGatewayAttach attach;
  bool _closed = false;

  static Future<HermesGatewaySshLink> connect({
    required SshHostConfig config,
    required SshSecrets secrets,
    required SshTransportFactory transportFactory,
    Duration attachTimeout = const Duration(seconds: 90),
  }) async {
    SshTransport? transport;
    LocalForwarder? forwarder;
    WebSocket? socket;
    try {
      transport = await transportFactory(SshConnectParams.of(config, secrets), (key) async {
        switch (checkHostKey(config, key)) {
          case HostKeyVerdict.trusted:
            return true;
          case HostKeyVerdict.unknown:
            throw HostLinkError(
              HostLinkErrorKind.hostKeyUnverified,
              'SSH host key is not pinned. Verify and pin it from Remote Hosts first.',
            );
          case HostKeyVerdict.mismatch:
            throw hostKeyMismatchError(config, key);
        }
      });
      final result = await transport.run('hermes gateway attach --json --start', timeout: attachTimeout);
      if (!result.ok) {
        final details = (result.stderr.trim().isNotEmpty ? result.stderr : result.stdout).trim();
        throw StateError(
          details.isEmpty
              ? 'Remote `hermes gateway attach --json --start` failed (exit ${result.exitCode}).'
              : 'Remote Hermes attach failed: ${_safeAttachError(details)}',
        );
      }
      final attach = HermesGatewayAttach.fromJson(_jsonObjectFromOutput(result.stdout));
      forwarder = await LocalForwarder.bind(() => transport!.openTunnel(attach.url.host, attach.url.port));
      final localUrl = attach.url.replace(host: '127.0.0.1', port: forwarder.port);
      socket = await WebSocket.connect(
        localUrl.toString(),
        protocols: attach.protocols,
        compression: CompressionOptions.compressionOff,
      );
      final client = HermesGatewayClient(socket);
      await client.ready.timeout(const Duration(seconds: 20));
      return HermesGatewaySshLink._(transport: transport, forwarder: forwarder, client: client, attach: attach);
    } catch (_) {
      try {
        await socket?.close();
      } catch (_) {}
      try {
        await forwarder?.close();
      } catch (_) {}
      try {
        transport?.close();
      } catch (_) {}
      rethrow;
    }
  }

  @override
  Future<void> close({String? sessionId, String? subscriptionId}) async {
    if (_closed) return;
    _closed = true;
    if (sessionId != null && subscriptionId != null) {
      try {
        await client.request('session.detach', {'session_id': sessionId, 'subscription_id': subscriptionId});
      } catch (_) {}
    }
    await client.close();
    await forwarder.close();
    transport.close();
  }
}

Object? _jsonObjectFromOutput(String output) {
  for (final line in output.split('\n').reversed) {
    final candidate = line.trim();
    if (!candidate.startsWith('{')) continue;
    try {
      final value = jsonDecode(candidate);
      if (value is Map) return value;
    } catch (_) {}
  }
  throw const FormatException('Hermes attach did not return a JSON object on stdout.');
}

String _safeAttachError(String text) {
  final withoutTicket = text.replaceAll(
    RegExp(r'hermes-gateway-ticket\.[^\s"\\]+'),
    'hermes-gateway-ticket.[redacted]',
  );
  final withoutQuery = withoutTicket.replaceAll(RegExp(r'(https?://[^\s?]+)\?[^\s]+'), r'\1?[redacted]');
  return withoutQuery.length > 1200 ? '${withoutQuery.substring(0, 1200)}…' : withoutQuery;
}

/// Creates a UUID-shaped request identity for canonical `session.create` / `prompt.submit`.
String hermesGatewayIdempotencyKey() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

/// Builds the canonical `session.create` payload with its retry-stable request identity.
Map<String, Object?> hermesGatewaySessionCreateParams() => {
  'source': 'tui',
  'idempotency_key': hermesGatewayIdempotencyKey(),
};

/// Builds the canonical `prompt.submit` payload with a deduplication identity.
Map<String, Object?> hermesGatewayPromptSubmitParams(String sessionId, String text) => {
  'session_id': sessionId,
  'submission_id': hermesGatewayIdempotencyKey(),
  'text': text,
};

/// Converts the renderer's clarify answers to the Gateway's `dict[str, str | None]` wire shape.
/// The clarify tool reads a multi-select answer from its JSON-array string representation.
Map<String, Object?> hermesGatewayClarifyAnswers(Map<String, Object?> answers) => {
  for (final entry in answers.entries)
    entry.key: switch (entry.value) {
      String value => value,
      List value => jsonEncode(value.whereType<String>().toList()),
      _ => null,
    },
};

/// Extracts the gateway-issued subscription token used by `session.detach`.
String? hermesGatewaySubscriptionId(Object? raw) {
  if (raw is! Map) return null;
  final response = Map<String, Object?>.from(raw);
  final nestedRaw = response['snapshot'];
  final snapshot = nestedRaw is Map ? Map<String, Object?>.from(nestedRaw) : response;
  final value = response['subscription_id'] ?? snapshot['subscription_id'];
  return value is String && value.isNotEmpty ? value : null;
}

/// Builds the canonical detach payload, including its subscription token when known.
Map<String, Object?> hermesGatewayDetachParams(String sessionId, String subscriptionId) => {
  'session_id': sessionId,
  'subscription_id': subscriptionId,
};
