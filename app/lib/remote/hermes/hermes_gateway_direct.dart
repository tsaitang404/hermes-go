import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'hermes_gateway_client.dart';

sealed class HermesGatewaySignIn {
  const HermesGatewaySignIn();
}

final class HermesGatewaySessionToken extends HermesGatewaySignIn {
  const HermesGatewaySessionToken(this.value);

  final String value;
}

final class HermesGatewayPassword extends HermesGatewaySignIn {
  const HermesGatewayPassword(this.username, this.password);

  final String username;
  final String password;
}

enum HermesGatewayDirectFailure {
  invalidUrl,
  httpsRequired,
  credentialsRequired,
  passwordUnavailable,
  rejected,
  rateLimited,
  endpointUnavailable,
  invalidResponse,
  connectionFailed,
}

/// Does not include URLs, HTTP bodies, headers, tickets or other credentials.
final class HermesGatewayDirectException implements Exception {
  const HermesGatewayDirectException(this.reason);

  final HermesGatewayDirectFailure reason;

  @override
  String toString() => 'Hermes Gateway: ${reason.name}';
}

/// A Hermes HTTP origin, optionally mounted under a reverse-proxy path prefix.
/// Permit cleartext only for a gateway on this device, never over LAN/the internet.
Uri hermesGatewayDirectBase(String input) {
  final uri = Uri.tryParse(input.trim());
  if (uri == null ||
      !{'https', 'http', 'wss', 'ws'}.contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      (uri.hasPort && (uri.port < 1 || uri.port > 65535))) {
    throw const HermesGatewayDirectException(HermesGatewayDirectFailure.invalidUrl);
  }
  final secure = uri.scheme == 'https' || uri.scheme == 'wss';
  if (!secure && !{'127.0.0.1', 'localhost', '::1'}.contains(uri.host)) {
    throw const HermesGatewayDirectException(HermesGatewayDirectFailure.httpsRequired);
  }
  var path = uri.path.replaceFirst(RegExp(r'/+$'), '');
  if (path.endsWith('/api/ws')) path = path.substring(0, path.length - '/api/ws'.length);
  return uri.replace(scheme: secure ? 'https' : 'http', path: path);
}

/// Connects to the same remote Hermes JSON-RPC endpoint as Hermes Desktop.
/// Refuses redirects, uses system TLS trust, and keeps sign-in state in memory.
class HermesGatewayDirectLink implements HermesGatewayLink {
  HermesGatewayDirectLink._(this.client, this.base);

  @override
  final HermesGatewayClient client;
  final Uri base;
  bool _closed = false;

  static const _timeout = Duration(seconds: 20);

  static Future<HermesGatewayDirectLink> connect({required String address, required HermesGatewaySignIn signIn}) async {
    final base = hermesGatewayDirectBase(address);
    final http = HttpClient()..connectionTimeout = _timeout;
    WebSocket? socket;
    HermesGatewayClient? client;
    try {
      final ticketUri = _route(base, '/api/auth/ws-ticket');
      final headers = <String, String>{};
      var cookies = <Cookie>[];
      String? deploymentToken;
      switch (signIn) {
        case HermesGatewaySessionToken(:final value):
          final token = value.trim();
          if (token.isEmpty || RegExp(r'\s').hasMatch(token)) {
            throw const HermesGatewayDirectException(HermesGatewayDirectFailure.credentialsRequired);
          }
          deploymentToken = token;
          headers['X-Hermes-Session-Token'] = token;
        case HermesGatewayPassword(:final username, :final password):
          if (username.trim().isEmpty || password.isEmpty) {
            throw const HermesGatewayDirectException(HermesGatewayDirectFailure.credentialsRequired);
          }
          final providers = await _json(http, base, 'GET', _route(base, '/api/auth/providers'));
          final rows = providers.body['providers'];
          if (rows is! List) {
            throw const HermesGatewayDirectException(HermesGatewayDirectFailure.invalidResponse);
          }
          final names = rows
              .whereType<Map>()
              .where((p) => p['supports_password'] == true)
              .map((p) => p['name'])
              .whereType<String>()
              .where((s) => s.isNotEmpty)
              .toList();
          final provider = names.contains('basic')
              ? 'basic'
              : names.length == 1
              ? names.single
              : null;
          if (provider == null) {
            throw const HermesGatewayDirectException(HermesGatewayDirectFailure.passwordUnavailable);
          }
          final loginUri = _route(base, '/auth/password-login');
          final login = await _json(
            http,
            base,
            'POST',
            loginUri,
            body: {'provider': provider, 'username': username.trim(), 'password': password, 'next': '${base.path}/'},
          );
          if (login.body['ok'] != true) {
            throw const HermesGatewayDirectException(HermesGatewayDirectFailure.invalidResponse);
          }
          cookies = login.cookies.where((c) => _useCookie(c, loginUri, ticketUri)).toList();
      }
      final grant = await _json(
        http,
        base,
        'POST',
        ticketUri,
        headers: headers,
        cookies: cookies,
        allowMissing: deploymentToken != null,
      );
      final ticket = grant.body['ticket'];
      final Map<String, String> credential;
      if (ticket is String && RegExp(r'^[A-Za-z0-9_-]{1,256}$').hasMatch(ticket)) {
        credential = {'ticket': ticket};
      } else if (grant.missing && deploymentToken != null) {
        // Legacy token-mode gateway: this is the official Desktop URL form.
        // Never fall back after a 401/403 or an invalid ticket response.
        credential = {'token': deploymentToken};
      } else {
        throw const HermesGatewayDirectException(HermesGatewayDirectFailure.invalidResponse);
      }
      final wsUri = _route(
        base,
        '/api/ws',
      ).replace(scheme: base.scheme == 'https' ? 'wss' : 'ws', port: base.port, queryParameters: credential);
      socket = await WebSocket.connect(
        wsUri.toString(),
        headers: {'Origin': base.origin},
        customClient: _DirectWebSocketHttpClient(http),
        compression: CompressionOptions.compressionOff,
      ).timeout(_timeout);
      client = HermesGatewayClient(socket);
      await client.ready.timeout(_timeout);
      return HermesGatewayDirectLink._(client, base);
    } catch (error) {
      if (client != null) {
        await client.close();
      } else {
        await socket?.close();
      }
      if (error is HermesGatewayDirectException) rethrow;
      if (error is WebSocketException && (error.httpStatusCode == 401 || error.httpStatusCode == 403)) {
        throw const HermesGatewayDirectException(HermesGatewayDirectFailure.rejected);
      }
      // WebSocketException includes the entire URL (including a ticket/token).
      throw const HermesGatewayDirectException(HermesGatewayDirectFailure.connectionFailed);
    } finally {
      http.close(force: true);
    }
  }

  static Uri _route(Uri base, String path) => base.replace(path: '${base.path}$path');

  static bool _useCookie(Cookie cookie, Uri issuedAt, Uri target) {
    final domain = cookie.domain?.toLowerCase().replaceFirst(RegExp(r'^\.'), '');
    final host = issuedAt.host.toLowerCase();
    if (domain != null && domain != host && !host.endsWith('.$domain')) return false;
    if (cookie.secure && target.scheme != 'https') return false;
    if ((cookie.maxAge ?? 1) <= 0 || (cookie.expires?.isBefore(DateTime.now()) ?? false)) return false;
    final requestedPath = issuedAt.path;
    final defaultPath = requestedPath.substring(0, requestedPath.lastIndexOf('/'));
    final path = cookie.path?.startsWith('/') == true ? cookie.path! : defaultPath;
    return target.path == path || target.path.startsWith(path.endsWith('/') ? path : '$path/');
  }

  static Future<({Map<String, Object?> body, List<Cookie> cookies, bool missing})> _json(
    HttpClient http,
    Uri base,
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
    List<Cookie> cookies = const [],
    Map<String, String>? body,
    bool allowMissing = false,
  }) async {
    final request = await http.openUrl(method, uri).timeout(_timeout);
    request.followRedirects = false;
    request.headers.set('Origin', base.origin);
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    headers.forEach(request.headers.set);
    request.cookies.addAll(cookies);
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await request.close().timeout(_timeout);
    final status = response.statusCode;
    if (status != HttpStatus.ok) {
      if (allowMissing && (status == 404 || status == 405)) {
        return (body: const <String, Object?>{}, cookies: const <Cookie>[], missing: true);
      }
      throw HermesGatewayDirectException(switch (status) {
        401 || 403 => HermesGatewayDirectFailure.rejected,
        429 => HermesGatewayDirectFailure.rateLimited,
        404 || 405 => HermesGatewayDirectFailure.endpointUnavailable,
        _ => HermesGatewayDirectFailure.connectionFailed,
      });
    }
    final bytes = <int>[];
    await for (final chunk in response.timeout(_timeout)) {
      if (bytes.length + chunk.length > 65536) {
        throw const HermesGatewayDirectException(HermesGatewayDirectFailure.invalidResponse);
      }
      bytes.addAll(chunk);
    }
    try {
      final value = jsonDecode(utf8.decode(bytes));
      if (value is Map<String, Object?>) return (body: value, cookies: response.cookies, missing: false);
    } on FormatException {
      // Do not display an unexpected response body (it may contain credentials).
    }
    throw const HermesGatewayDirectException(HermesGatewayDirectFailure.invalidResponse);
  }

  @override
  Future<void> close({String? sessionId, String? subscriptionId}) async {
    if (_closed) return;
    _closed = true;
    if (sessionId != null && subscriptionId != null) {
      try {
        await client
            .request('session.detach', hermesGatewayDetachParams(sessionId, subscriptionId))
            .timeout(const Duration(seconds: 3));
      } catch (_) {}
    }
    await client.close();
  }
}

/// dart:io's WebSocket connector calls only openUrl on its custom client.
final class _DirectWebSocketHttpClient implements HttpClient {
  _DirectWebSocketHttpClient(this._http);

  final HttpClient _http;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    final request = await _http.openUrl(method, url);
    request.followRedirects = false;
    return request;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
