import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/remote/hermes/hermes_gateway_direct.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const token = 'test-deployment-token';
  const ticket = 'test_single_use_ticket';
  late HttpServer server;
  late String origin;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin = 'http://127.0.0.1:${server.port}';
  });

  tearDown(() => server.close(force: true));

  test('normalizes HTTPS, WSS, port and path without accepting credentials in URLs', () {
    expect(
      hermesGatewayDirectBase(' wss://gateway.example:8443/hermes/api/ws/ ').toString(),
      'https://gateway.example:8443/hermes',
    );
    expect(hermesGatewayDirectBase('wss://gateway.example/api/ws').port, 443);
    for (final bad in [
      'http://192.168.1.50:9119',
      'https://me:secret@gateway.example',
      'https://gateway.example?token=secret',
      'https://gateway.example#secret',
      'ssh://example.com',
    ]) {
      expect(() => hermesGatewayDirectBase(bad), throwsA(isA<HermesGatewayDirectException>()));
    }
  });

  test('deployment token mints a ticket; RPC goes over the WebSocket, not SSH', () async {
    final seen = <String>[];
    server.listen((r) async {
      seen.add('${r.method} ${r.uri.path}');
      if (r.uri.path == '/hermes/api/auth/ws-ticket') {
        expect(r.headers.value('X-Hermes-Session-Token'), token);
        expect(await utf8.decoder.bind(r).join(), isEmpty);
        await _json(r, {'ticket': ticket, 'ttl_seconds': 30});
      } else {
        expect(r.uri.path, '/hermes/api/ws');
        expect(r.uri.queryParameters, {'ticket': ticket});
        expect(r.headers.value('X-Hermes-Session-Token'), isNull);
        await _gateway(r);
      }
    });
    final link = await HermesGatewayDirectLink.connect(
      address: '$origin/hermes',
      signIn: const HermesGatewaySessionToken(token),
    );
    addTearDown(link.close);
    final runtime = await link.client.request('runtime.describe');
    expect(runtime, {
      'session_create': {
        'sources': ['tui'],
      },
    });
    expect(await link.client.request('session.list'), {'sessions': []});
    expect(seen, ['POST /hermes/api/auth/ws-ticket', 'GET /hermes/api/ws']);
  });

  test('password login discovers the provider, uses scoped cookies, then opens a ticketed socket', () async {
    server.listen((r) async {
      switch (r.uri.path) {
        case '/prefix/api/auth/providers':
          expect(r.method, 'GET');
          await _json(r, {
            'providers': [
              {'name': 'other', 'supports_password': false},
              {'name': 'basic', 'supports_password': true},
            ],
          });
        case '/prefix/auth/password-login':
          expect(r.method, 'POST');
          expect(jsonDecode(await utf8.decoder.bind(r).join()), {
            'provider': 'basic',
            'username': 'tester',
            'password': 'test password',
            'next': '/prefix/',
          });
          r.response.cookies.addAll([
            Cookie('session', 'fake')
              ..path = '/prefix'
              ..httpOnly = true,
            Cookie('ignored', 'other')..path = '/prefix-other',
            Cookie('elsewhere', 'other')
              ..domain = 'unrelated.example'
              ..path = '/',
          ]);
          await _json(r, {'ok': true, 'next': '/prefix/'});
        case '/prefix/api/auth/ws-ticket':
          expect(r.cookies.map((cookie) => cookie.name), ['session']);
          expect(r.headers.value('X-Hermes-Session-Token'), isNull);
          await _json(r, {'ticket': ticket});
        case '/prefix/api/ws':
          expect(r.uri.queryParameters, {'ticket': ticket});
          expect(r.cookies, isEmpty);
          await _gateway(r);
        default:
          fail('Unexpected endpoint: ${r.uri.path}');
      }
    });
    final link = await HermesGatewayDirectLink.connect(
      address: '$origin/prefix',
      signIn: const HermesGatewayPassword('tester', 'test password'),
    );
    addTearDown(link.close);
    expect(await link.client.request('session.list'), {'sessions': []});
  });

  test('legacy token mode falls back only when the ticket endpoint is missing', () async {
    server.listen((r) async {
      if (r.uri.path == '/api/auth/ws-ticket') {
        r.response.statusCode = HttpStatus.notFound;
        await r.response.close();
      } else {
        expect(r.uri.queryParameters, {'token': token});
        await _gateway(r);
      }
    });
    final link = await HermesGatewayDirectLink.connect(address: origin, signIn: const HermesGatewaySessionToken(token));
    addTearDown(link.close);
    expect(await link.client.request('session.list'), {'sessions': []});
  });

  test('a rejected token never falls back and error text cannot expose credentials', () async {
    final paths = <String>[];
    server.listen((r) async {
      paths.add(r.uri.path);
      r.response.statusCode = HttpStatus.unauthorized;
      await _json(r, {'detail': token});
    });
    await expectLater(
      HermesGatewayDirectLink.connect(address: origin, signIn: const HermesGatewaySessionToken(token)),
      throwsA(
        isA<HermesGatewayDirectException>()
            .having((e) => e.reason, 'reason', HermesGatewayDirectFailure.rejected)
            .having((e) => e.toString(), 'message', isNot(contains(token))),
      ),
    );
    expect(paths, ['/api/auth/ws-ticket']);
  });

  test('does not follow redirects during WebSocket upgrade or expose the ticket', () async {
    final paths = <String>[];
    server.listen((r) async {
      paths.add(r.uri.path);
      if (r.uri.path == '/api/auth/ws-ticket') {
        await _json(r, {'ticket': ticket});
      } else {
        r.response.statusCode = HttpStatus.movedTemporarily;
        r.response.headers.set(HttpHeaders.locationHeader, '$origin/untrusted');
        await r.response.close();
      }
    });
    await expectLater(
      HermesGatewayDirectLink.connect(address: origin, signIn: const HermesGatewaySessionToken(token)),
      throwsA(isA<HermesGatewayDirectException>().having((e) => e.toString(), 'message', isNot(contains(ticket)))),
    );
    expect(paths, ['/api/auth/ws-ticket', '/api/ws']);
  });
}

Future<void> _json(HttpRequest request, Map<String, Object?> value) async {
  request.response.headers.contentType = ContentType.json;
  request.response.write(jsonEncode(value));
  await request.response.close();
}

Future<void> _gateway(HttpRequest request) async {
  final socket = await WebSocketTransformer.upgrade(request);
  socket.add(
    jsonEncode({
      'jsonrpc': '2.0',
      'method': 'event',
      'params': {
        'type': 'gateway.ready',
        'payload': {'session_authority': true},
      },
    }),
  );
  socket.listen((message) {
    final rpc = jsonDecode(message as String) as Map;
    final result = switch (rpc['method']) {
      'runtime.describe' => {
        'session_create': {
          'sources': ['tui'],
        },
      },
      'session.list' => {'sessions': []},
      _ => {'ok': true},
    };
    socket.add(jsonEncode({'jsonrpc': '2.0', 'id': rpc['id'], 'result': result}));
  });
}
