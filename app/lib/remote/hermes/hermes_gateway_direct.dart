import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'hermes_gateway_client.dart';

sealed class HermesGatewaySignIn {
  const HermesGatewaySignIn();
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

final class HermesGatewayDirectException implements Exception {
  const HermesGatewayDirectException(this.reason);
  final HermesGatewayDirectFailure reason;
  @override
  String toString() => 'Hermes Gateway: ${reason.name}';
}

Uri hermesGatewayDirectBase(String input) {
  final uri = Uri.tryParse(input.trim());
  if (uri == null ||
      !{'https', 'http', 'wss', 'ws'}.contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    throw const HermesGatewayDirectException(HermesGatewayDirectFailure.invalidUrl);
  }
  final secure = uri.scheme == 'https' || uri.scheme == 'wss';
  if (!secure && !{'127.0.0.1', 'localhost', '::1'}.contains(uri.host)) {
    throw const HermesGatewayDirectException(HermesGatewayDirectFailure.httpsRequired);
  }
  var path = uri.path.replaceFirst(RegExp(r'/+$'), '');
  if (path.endsWith('/api/ws')) path = path.substring(0, path.length - 7);
  return uri.replace(scheme: secure ? 'https' : 'http', path: path);
}

/// Direct official Gateway login. Credentials/tickets remain in memory; ticket is only a WS subprotocol.
class HermesGatewayDirectLink {
  HermesGatewayDirectLink._(this.client, this.base);
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
      if (signIn is! HermesGatewayPassword)
        throw const HermesGatewayDirectException(HermesGatewayDirectFailure.credentialsRequired);
      final username = signIn.username.trim();
      if (username.isEmpty || signIn.password.isEmpty)
        throw const HermesGatewayDirectException(HermesGatewayDirectFailure.credentialsRequired);
      final providers = await _json(http, base, 'GET', _route(base, '/api/auth/providers'));
      final rows = providers.body['providers'];
      if (rows is! List) throw const HermesGatewayDirectException(HermesGatewayDirectFailure.invalidResponse);
      final names = rows
          .whereType<Map>()
          .where((p) => p['supports_password'] == true)
          .map((p) => p['name'])
          .whereType<String>()
          .toList();
      final provider = names.contains('basic')
          ? 'basic'
          : names.length == 1
          ? names.single
          : null;
      if (provider == null) throw const HermesGatewayDirectException(HermesGatewayDirectFailure.passwordUnavailable);
      final loginUri = _route(base, '/auth/password-login');
      final login = await _json(
        http,
        base,
        'POST',
        loginUri,
        body: {'provider': provider, 'username': username, 'password': signIn.password, 'next': '${base.path}/'},
      );
      if (login.body['ok'] != true)
        throw const HermesGatewayDirectException(HermesGatewayDirectFailure.invalidResponse);
      final cookies = login.cookies.where((c) => _useCookie(c, loginUri, _route(base, '/api/auth/ws-ticket'))).toList();
      final grant = await _json(http, base, 'POST', _route(base, '/api/auth/ws-ticket'), cookies: cookies);
      final ticket = grant.body['ticket'];
      if (ticket is! String || !RegExp(r'^[A-Za-z0-9_-]{1,256}$').hasMatch(ticket))
        throw const HermesGatewayDirectException(HermesGatewayDirectFailure.invalidResponse);
      final wsUri = _route(
        base,
        '/api/ws',
      ).replace(scheme: base.scheme == 'https' ? 'wss' : 'ws', port: base.hasPort ? base.port : null);
      socket = await WebSocket.connect(
        wsUri.toString(),
        protocols: ['hermes-gateway-v1', 'hermes-gateway-ticket.$ticket'],
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
      if (error is WebSocketException && (error.httpStatusCode == 401 || error.httpStatusCode == 403))
        throw const HermesGatewayDirectException(HermesGatewayDirectFailure.rejected);
      throw const HermesGatewayDirectException(HermesGatewayDirectFailure.connectionFailed);
    } finally {
      http.close(force: true);
    }
  }

  static Uri _route(Uri base, String path) => base.replace(path: '${base.path}$path');
  static bool _useCookie(Cookie c, Uri from, Uri to) {
    final domain = c.domain?.toLowerCase().replaceFirst(RegExp(r'^\.'), '');
    if (domain != null && domain != from.host.toLowerCase()) return false;
    if (c.secure && to.scheme != 'https') return false;
    final path = c.path?.startsWith('/') == true ? c.path! : from.path.substring(0, from.path.lastIndexOf('/'));
    return to.path == path || to.path.startsWith(path.endsWith('/') ? path : '$path/');
  }

  static Future<({Map<String, Object?> body, List<Cookie> cookies})> _json(
    HttpClient http,
    Uri base,
    String method,
    Uri uri, {
    List<Cookie> cookies = const [],
    Map<String, String>? body,
  }) async {
    final request = await http.openUrl(method, uri).timeout(_timeout)
      ..followRedirects = false;
    request.headers.set('Origin', base.origin);
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    request.cookies.addAll(cookies);
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await request.close().timeout(_timeout);
    if (response.statusCode != HttpStatus.ok)
      throw HermesGatewayDirectException(switch (response.statusCode) {
        401 || 403 => HermesGatewayDirectFailure.rejected,
        429 => HermesGatewayDirectFailure.rateLimited,
        404 || 405 => HermesGatewayDirectFailure.endpointUnavailable,
        _ => HermesGatewayDirectFailure.connectionFailed,
      });
    final bytes = <int>[];
    await for (final chunk in response.timeout(_timeout)) {
      if (bytes.length + chunk.length > 65536)
        throw const HermesGatewayDirectException(HermesGatewayDirectFailure.invalidResponse);
      bytes.addAll(chunk);
    }
    try {
      final value = jsonDecode(utf8.decode(bytes));
      if (value is Map<String, Object?>) return (body: value, cookies: response.cookies);
    } on FormatException {}
    throw const HermesGatewayDirectException(HermesGatewayDirectFailure.invalidResponse);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await client.close();
  }
}

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
