// Purpose: Regression tests for Hermes Gateway attach bootstrap and JSON-RPC behavior.
// 创建时间：2026-11-18 Hermes
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_app/remote/hermes/hermes_gateway_client.dart';

void main() {
  group('HermesGatewayAttach', () {
    test('accepts a loopback WebSocket with the Gateway version and ticket protocols', () {
      final attach = HermesGatewayAttach.fromJson({
        'url': 'ws://127.0.0.1:8654/api/ws',
        'protocols': ['hermes-gateway-v1', 'hermes-gateway-ticket.test-ticket'],
        'endpoint': {'profile_id': 'default', 'instance_id': 'instance-test'},
      });

      expect(attach.url, Uri.parse('ws://127.0.0.1:8654/api/ws'));
      expect(attach.protocols, ['hermes-gateway-v1', 'hermes-gateway-ticket.test-ticket']);
      expect(attach.profileId, 'default');
      expect(attach.instanceId, 'instance-test');
    });

    test('rejects attach data without the single-use ticket subprotocol', () {
      expect(
        () => HermesGatewayAttach.fromJson({
          'url': 'ws://127.0.0.1:8654/api/ws',
          'protocols': ['hermes-gateway-v1'],
          'endpoint': {'profile_id': 'default', 'instance_id': 'instance-test'},
        }),
        throwsFormatException,
      );
    });

    test('rejects a non-loopback Gateway endpoint', () {
      expect(
        () => HermesGatewayAttach.fromJson({
          'url': 'ws://gateway.example:8654/api/ws',
          'protocols': ['hermes-gateway-v1', 'hermes-gateway-ticket.test-ticket'],
          'endpoint': {'profile_id': 'default', 'instance_id': 'instance-test'},
        }),
        throwsFormatException,
      );
    });
  });

  test('session create and prompt submit use canonical retry and deduplication fields', () {
    final create = hermesGatewaySessionCreateParams();
    expect(create['source'], 'tui');
    expect(
      create['idempotency_key'],
      matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')),
    );
    expect(create.keys.toSet(), {'source', 'idempotency_key'});
    final prompt = hermesGatewayPromptSubmitParams('session-1', 'hello');
    expect(prompt['session_id'], 'session-1');
    expect(prompt['text'], 'hello');
    expect(
      prompt['submission_id'],
      matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')),
    );
    expect(prompt.keys.toSet(), {'session_id', 'submission_id', 'text'});
  });

  test('clarify result converts multi-select values to the Gateway wire contract', () {
    expect(
      hermesGatewayClarifyAnswers({
        'project': 'gateway',
        'features': ['sessions', 'tools'],
        'skipped': null,
      }),
      {'project': 'gateway', 'features': '["sessions","tools"]', 'skipped': null},
    );
  });

  test('terminal Gateway failures are extracted from session and turn events', () {
    expect(
      hermesGatewayEventError(
        const HermesGatewayEvent(type: 'error', payload: {'message': 'Agent initialization failed'}),
      ),
      'Agent initialization failed',
    );
    expect(
      hermesGatewayEventError(
        const HermesGatewayEvent(
          type: 'message.complete',
          payload: {'status': 'error', 'error': 'Provider returned an error'},
        ),
      ),
      'Provider returned an error',
    );
    expect(
      hermesGatewayEventError(
        const HermesGatewayEvent(
          type: 'message.complete',
          payload: {'status': 'error', 'failure_reason': 'Tool execution failed'},
        ),
      ),
      'Tool execution failed',
    );
    expect(
      hermesGatewayEventError(
        const HermesGatewayEvent(type: 'message.complete', payload: {'status': 'complete', 'text': 'Done'}),
      ),
      isNull,
    );
  });

  test('session attachment retains its subscription token for detach', () {
    final token = hermesGatewaySubscriptionId({
      'session_id': 'live',
      'snapshot': {'subscription_id': 'sub-1'},
    });
    expect(token, 'sub-1');
    expect(hermesGatewayDetachParams('live', token!), {'session_id': 'live', 'subscription_id': 'sub-1'});
  });

  test('session attachment without a subscription token cannot detach', () {
    expect(hermesGatewaySubscriptionId({'session_id': 'live'}), isNull);
  });

  test('JSON-RPC, streamed events, capabilities, and approval requests interoperate', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final inbound = StreamController<Map<String, Object?>>.broadcast();
    final peerReady = Completer<WebSocket>();
    WebSocket? peer;

    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      peer = socket;
      peerReady.complete(socket);
      socket.listen((raw) {
        if (raw is! String) return;
        final decoded = jsonDecode(raw);
        if (decoded is! Map) return;
        final frame = Map<String, Object?>.from(decoded);
        inbound.add(frame);
        final method = frame['method'];
        final id = frame['id'];
        if (method == 'client.capabilities') {
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': id,
              'result': {
                'server_requests': ['approval', 'clarify'],
              },
            }),
          );
        } else if (method == 'session.interrupt') {
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': id,
              'result': {'interrupted': true},
            }),
          );
        } else if (method == 'session.list') {
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': id,
              'result': {
                'sessions': [
                  {'session_id': 'stored-1', 'title': 'A saved session'},
                ],
              },
            }),
          );
        }
      });
      socket.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'method': 'event',
          'params': {'type': 'gateway.ready', 'payload': {}},
        }),
      );
    });

    final capabilitiesFrame = inbound.stream.firstWhere((frame) => frame['method'] == 'client.capabilities');
    final socket = await WebSocket.connect('ws://127.0.0.1:${server.port}/api/ws', protocols: ['hermes-gateway-v1']);
    final client = HermesGatewayClient(socket);
    try {
      await peerReady.future.timeout(const Duration(seconds: 2));
      await client.ready.timeout(const Duration(seconds: 2));
      final capabilities = await capabilitiesFrame.timeout(const Duration(seconds: 2));
      expect(capabilities['params'], {'server_requests': true});

      final listFrameFuture = inbound.stream.firstWhere((frame) => frame['method'] == 'session.list');
      final listResponse = client.request('session.list', const {'scope': 'stored', 'picker': true});
      final listFrame = await listFrameFuture.timeout(const Duration(seconds: 2));
      expect(listFrame['params'], {'scope': 'stored', 'picker': true});
      expect(await listResponse, {
        'sessions': [
          {'session_id': 'stored-1', 'title': 'A saved session'},
        ],
      });

      final interruptFrameFuture = inbound.stream.firstWhere((frame) => frame['method'] == 'session.interrupt');
      final interruptResponse = client.interruptSession('stored-1');
      expect((await interruptFrameFuture.timeout(const Duration(seconds: 2)))['params'], {'session_id': 'stored-1'});
      expect(await interruptResponse, {'interrupted': true});

      final seenEvents = <HermesGatewayEvent>[];
      final eventsReceived = Completer<void>();
      final eventSubscription = client.events.listen((event) {
        seenEvents.add(event);
        if (seenEvents.length == 5 && !eventsReceived.isCompleted) {
          eventsReceived.complete();
        }
      });
      var handledRequests = 0;
      final requestsHandled = Completer<void>();
      final requestSubscription = client.serverRequests.listen((request) {
        if (request.method == 'approval') {
          expect(request.params['command'], 'echo ready');
          client.respond(request.id, const {'choice': 'once'});
        } else if (request.method == 'clarify') {
          expect(request.params['questions'], [
            {'qid': 'project', 'question': 'Which project?'},
          ]);
          client.respond(request.id, const {
            'answers': {'project': 'gateway'},
          });
        } else {
          fail('Unexpected Gateway server request: ${request.method}');
        }
        handledRequests++;
        if (handledRequests == 2 && !requestsHandled.isCompleted) {
          requestsHandled.complete();
        }
      });
      final approvalReply = inbound.stream.firstWhere(
        (frame) => frame['id'] == 'approval-1' && frame['method'] == null,
      );
      final clarifyReply = inbound.stream.firstWhere((frame) => frame['id'] == 'clarify-1' && frame['method'] == null);
      peer!.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'method': 'event',
          'params': {
            'type': 'message.delta',
            'session_id': 'stored-1',
            'payload': {'text': 'Hello'},
          },
        }),
      );
      peer!.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'method': 'event',
          'params': {
            'type': 'tool.start',
            'session_id': 'stored-1',
            'payload': {'name': 'terminal'},
          },
        }),
      );
      peer!.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'method': 'event',
          'params': {
            'type': 'tool.complete',
            'session_id': 'stored-1',
            'payload': {'name': 'terminal', 'status': 'done'},
          },
        }),
      );
      peer!.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'method': 'event',
          'params': {
            'type': 'message.complete',
            'session_id': 'stored-1',
            'payload': {'text': 'Hello.'},
          },
        }),
      );
      peer!.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'method': 'event',
          'params': {
            'type': 'request.cancel',
            'session_id': 'stored-1',
            'payload': {'id': 'withdrawn-1', 'method': 'approval', 'reason': 'answered elsewhere'},
          },
        }),
      );
      peer!.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': 'approval-1',
          'method': 'approval',
          'params': {'session_id': 'stored-1', 'command': 'echo ready'},
        }),
      );
      peer!.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': 'clarify-1',
          'method': 'clarify',
          'params': {
            'questions': [
              {'qid': 'project', 'question': 'Which project?'},
            ],
          },
        }),
      );

      await eventsReceived.future.timeout(const Duration(seconds: 2));
      await requestsHandled.future.timeout(const Duration(seconds: 2));
      final reply = await approvalReply.timeout(const Duration(seconds: 2));
      final clarification = await clarifyReply.timeout(const Duration(seconds: 2));
      expect(seenEvents.map((event) => event.type), [
        'message.delta',
        'tool.start',
        'tool.complete',
        'message.complete',
        'request.cancel',
      ]);
      expect(seenEvents.first.payload['text'], 'Hello');
      expect(seenEvents.last.payload['id'], 'withdrawn-1');
      expect(reply['result'], {'choice': 'once'});
      expect(clarification['result'], {
        'answers': {'project': 'gateway'},
      });
      await eventSubscription.cancel();
      await requestSubscription.cancel();
    } finally {
      await client.close();
      await peer?.close();
      await server.close(force: true);
      await inbound.close();
    }
  });
}
