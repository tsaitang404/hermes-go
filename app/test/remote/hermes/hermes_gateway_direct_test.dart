import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/remote/hermes/hermes_gateway_client.dart';
import 'package:dsh_app/remote/hermes/hermes_gateway_direct.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const ticket = 'short_lived_once';
  late HttpServer server;
  late String origin;
  setUp(() async { server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0); origin = 'http://127.0.0.1:${server.port}'; });
  tearDown(() => server.close(force: true));

  test('password login gets a fresh ticket and sends exact official subprotocols, never query', () async {
    final paths = <String>[];
    server.listen((r) async {
      paths.add('${r.method} ${r.uri.path}');
      switch (r.uri.path) {
        case '/api/auth/providers': await _json(r, {'providers':[{'name':'basic','supports_password':true}]});
        case '/auth/password-login':
          expect(jsonDecode(await utf8.decoder.bind(r).join()), {'provider':'basic','username':'tester','password':'test-only-secret','next':'/'});
          r.response.cookies.add(Cookie('session','mock')..path='/');
          await _json(r, {'ok':true});
        case '/api/auth/ws-ticket':
          expect(r.method, 'POST');
          expect(r.cookies.map((c)=>c.name), ['session']);
          await _json(r, {'ticket':ticket,'ttl_seconds':30});
        case '/api/ws':
          expect(r.uri.queryParameters, isEmpty);
          expect(r.headers.value('sec-websocket-protocol')?.split(',').map((p)=>p.trim()).toList(), ['hermes-gateway-v1','hermes-gateway-ticket.$ticket']);
          await _gateway(r);
        default: fail('unexpected endpoint ${r.uri.path}');
      }
    });
    final link = await HermesGatewayDirectLink.connect(address: origin, signIn: const HermesGatewayPassword('tester','test-only-secret'));
    addTearDown(link.close);
    expect(await link.client.request('session.list'), {'sessions':[]});
    expect(paths, ['GET /api/auth/providers','POST /auth/password-login','POST /api/auth/ws-ticket','GET /api/ws']);
  });

  test('password login supports the shared session page RPC flow and gateway-ready ordering', () async {
    final frames = <Map<String, Object?>>[];
    final methods = <String>[];
    server.listen((r) async {
      if (r.uri.path == '/api/auth/providers') { await _json(r, {'providers':[{'name':'basic','supports_password':true}]}); return; }
      if (r.uri.path == '/auth/password-login') { await r.drain<void>(); r.response.cookies.add(Cookie('session','mock')..path='/'); await _json(r, {'ok':true}); return; }
      if (r.uri.path == '/api/auth/ws-ticket') { await _json(r, {'ticket':ticket}); return; }
      if (r.uri.path != '/api/ws') { fail('unexpected path ${r.uri.path}'); return; }
      final socket = await WebSocketTransformer.upgrade(r, protocolSelector: (_) => 'hermes-gateway-v1');
      socket.add(jsonEncode({'jsonrpc':'2.0','method':'event','params':{'type':'gateway.ready','payload':{}}}));
      socket.listen((raw) {
        final frame = Map<String,Object?>.from(jsonDecode(raw as String) as Map);
        frames.add(frame);
        final method = frame['method'] as String;
        methods.add(method);
        final result = switch (method) {
          'client.capabilities' => {'server_requests':['approval','clarify']},
          'runtime.describe' => {'session_create':{'sources':['tui']}},
          'session.list' => {'sessions':[{'session_id':'stored-1','title':'Stored'}]},
          'session.create' => {'session_id':'live-1','subscription_id':'sub-1','snapshot':{'messages':[]}},
          'prompt.submit' => {'accepted':true},
          _ => <String,Object?>{},
        };
        socket.add(jsonEncode({'jsonrpc':'2.0','id':frame['id'],'result':result}));
      });
    });
    final link = await HermesGatewayDirectLink.connect(address: origin, signIn: const HermesGatewayPassword('tester','test-only-secret'));
    addTearDown(link.close);
    await link.client.request('runtime.describe');
    await link.client.request('session.list', const {'scope':'stored','limit':40,'include_hidden':false,'picker':true});
    final create = await link.client.request('session.create', hermesGatewaySessionCreateParams());
    expect(create, containsPair('session_id','live-1'));
    await link.client.request('prompt.submit', hermesGatewayPromptSubmitParams('live-1','hello from fake'));
    await Future<void>.delayed(const Duration(milliseconds:10));
    expect(methods.first, 'client.capabilities');
    expect(methods, containsAllInOrder(['client.capabilities','runtime.describe','session.list','session.create','prompt.submit']));
    expect(frames.first['params'], {'server_requests':true});
    expect(frames.singleWhere((f)=>f['method']=='session.list')['params'], {'scope':'stored','limit':40,'include_hidden':false,'picker':true});
    expect(frames.singleWhere((f)=>f['method']=='prompt.submit')['params'], {'session_id':'live-1','submission_id':isA<String>(),'text':'hello from fake'});
  });
  test('missing password provider gives an explicit failure', () async {
    server.listen((r) async => _json(r, {'providers':[{'name':'oauth','supports_password':false}]}));
    await expectLater(HermesGatewayDirectLink.connect(address: origin, signIn: const HermesGatewayPassword('tester','x')),
      throwsA(isA<HermesGatewayDirectException>().having((e)=>e.reason,'reason',HermesGatewayDirectFailure.passwordUnavailable)));
  });

  test('Remote screen routes to direct Gateway and does not display/use DSH Remote', () async {
    final source = await File('lib/ui/remote/remote_screen.dart').readAsString();
    expect(source, contains('HermesGatewayDirectPage'));
    expect(source, isNot(contains('_RelaySection(onUse:')));
  });
}
Future<void> _json(HttpRequest r, Map<String,Object?> body) async { r.response.headers.contentType=ContentType.json; r.response.write(jsonEncode(body)); await r.response.close(); }
Future<void> _gateway(HttpRequest r) async {
  final socket = await WebSocketTransformer.upgrade(r, protocolSelector: (protocols)=>protocols.first);
  socket.add(jsonEncode({'jsonrpc':'2.0','method':'event','params':{'type':'gateway.ready','payload':{'session_authority':true}}}));
  socket.listen((message) { final rpc=jsonDecode(message as String) as Map; socket.add(jsonEncode({'jsonrpc':'2.0','id':rpc['id'],'result':{'sessions':[]}})); });
}
