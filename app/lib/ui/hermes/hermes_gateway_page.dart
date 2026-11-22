// Purpose: Dedicated mobile UI for Hermes TUI Gateway sessions and requests.
// 创建时间：2026-11-18 Hermes
import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';

import '../../remote/hermes/hermes_gateway_client.dart';
import '../../remote/hermes/hermes_gateway_direct.dart';
import '../../remote/ssh/ssh_host_config.dart';
import '../../state/connection_state.dart' show sshTransportFactoryProvider;
import '../../state/hosts_state.dart' show hostsProvider, HostsState;

class HermesGatewayPage extends ConsumerStatefulWidget {
  const HermesGatewayPage({super.key, this.directLink});
  final HermesGatewayDirectLink? directLink;

  @override
  ConsumerState<HermesGatewayPage> createState() => _HermesGatewayPageState();
}

class _HermesGatewayPageState extends ConsumerState<HermesGatewayPage> {
  final _prompt = TextEditingController();
  final _scroll = ScrollController();
  String? _selectedHostId;
  HermesGatewaySshLink? _link;
  HermesGatewayDirectLink? _directLink;
  StreamSubscription<HermesGatewayEvent>? _eventSubscription;
  StreamSubscription<HermesGatewayRequest>? _requestSubscription;
  StreamSubscription<Object>? _connectionSubscription;
  final List<_GatewaySession> _sessions = [];
  final List<_GatewayLine> _lines = [];
  final List<HermesGatewayRequest> _requestQueue = [];
  String? _activeSessionId;
  String? _activeSubscriptionId;
  String? _selectedSessionId;
  String? _error;
  String? _notice;
  bool _busy = false;
  bool _connecting = false;
  bool _handlingRequest = false;
  bool _streaming = false;
  String? _activeRequestId;
  final Set<String> _cancelledRequestIds = {};
  VoidCallback? _dismissActiveDialog;

  @override
  void initState() {
    super.initState();
    final direct = widget.directLink;
    if (direct != null) unawaited(openDirect(direct));
  }

  @override
  void dispose() {
    _eventSubscription?.cancel();
    _requestSubscription?.cancel();
    _connectionSubscription?.cancel();
    _dismissActiveDialog?.call();
    _dismissActiveDialog = null;
    if (_directLink != null) unawaited(_directLink!.close());
    final link = _link;
    if (link != null) {
      unawaited(link.close(sessionId: _activeSessionId, subscriptionId: _activeSubscriptionId));
    }
    _prompt.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _buildGatewayPage(context);

  Widget _buildGatewayPage(BuildContext context) {
    final hosts = ref.watch(hostsProvider);
    final host = _findHost(hosts);
    final direct = _directLink != null;
    final connected = _link != null || direct;
    final localeZh = Localizations.localeOf(context).languageCode == 'zh';
    String tr(String zh, String en) => localeZh ? zh : en;

    if (_selectedHostId == null && hosts.ssh.isNotEmpty) {
      _selectedHostId = hosts.ssh.first.id;
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Hermes Gateway'),
        actions: [
          if (connected)
            IconButton(
              tooltip: tr('刷新会话', 'Refresh sessions'),
              onPressed: _busy ? null : _refreshSessions,
              icon: const Icon(AppIcons.refresh),
            ),
          if (connected)
            IconButton(
              tooltip: tr('断开连接', 'Disconnect'),
              onPressed: _busy ? null : _disconnect,
              icon: const Icon(AppIcons.disconnected),
            ),
        ],
      ),
      body: Column(
        children: [
          _connectionBar(hosts, host, tr, direct: direct),
          if (_error != null) _Banner(text: _error!, color: Theme.of(context).colorScheme.errorContainer),
          if (_notice != null) _Banner(text: _notice!, color: Theme.of(context).colorScheme.secondaryContainer),
          if (!connected)
            Expanded(child: _emptyState(hosts, tr))
          else ...[
            _sessionPicker(tr),
            Expanded(child: _transcript(tr)),
            _composer(tr),
          ],
        ],
      ),
    );
  }

  Widget _connectionBar(HostsState hosts, SshHostConfig? host, String Function(String, String) tr, {required bool direct}) {
    if (direct) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Row(children: [const Icon(AppIcons.link), const SizedBox(width: 10), Expanded(child: Text(_notice ?? 'Direct Gateway connection'))]),
      );
    }
    final connected = _link != null || _directLink != null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: DropdownButtonFormField<String>(
              key: ValueKey(_selectedHostId),
              initialValue: _selectedHostId,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: tr('通过已保存的 SSH 主机', 'Saved SSH host'),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              items: [
                for (final item in hosts.ssh)
                  DropdownMenuItem(
                    value: item.id,
                    child: Text('${item.name} · ${item.address}', overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: connected || _connecting ? null : (id) => setState(() => _selectedHostId = id),
            ),
          ),
          const SizedBox(width: 10),
          FilledButton.icon(
            onPressed: host == null || connected || _connecting ? null : () => _connect(host),
            icon: _connecting
                ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(AppIcons.link),
            label: Text(_connecting ? tr('连接中', 'Connecting') : tr('连接', 'Connect')),
          ),
        ],
      ),
    );
  }

  Widget _emptyState(HostsState hosts, String Function(String, String) tr) {
    final message = hosts.ssh.isEmpty
        ? tr('先在“远程主机”里添加并验证 SSH 主机。', 'Add and verify an SSH host in Remote Hosts first.')
        : tr(
            '连接会通过已固定主机密钥的 SSH 隧道进行，不需要公开 Hermes Gateway 端口。',
            'Connection uses a pinned SSH host key and tunnel; no public Hermes Gateway port is needed.',
          );
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(AppIcons.terminal, size: 44),
            const SizedBox(height: 16),
            Text(message, textAlign: TextAlign.center),
            if (hosts.ssh.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                tr(
                  '首次连接会在远端执行 hermes gateway attach --json --start。',
                  'First connect runs hermes gateway attach --json --start remotely.',
                ),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _sessionPicker(String Function(String, String) tr) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: DropdownButtonFormField<String>(
              key: ValueKey('session-${_activeSessionId ?? 'none'}'),
              initialValue: _sessions.any((s) => s.id == _selectedSessionId) ? _selectedSessionId : null,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: tr('Gateway 会话', 'Gateway session'),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              hint: Text(tr('选择会话', 'Select a session')),
              items: [
                for (final session in _sessions)
                  DropdownMenuItem(
                    value: session.id,
                    child: Text(session.title, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: _busy
                  ? null
                  : (id) {
                      if (id != null) unawaited(_resumeSession(id));
                    },
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filledTonal(
            tooltip: tr('新建会话', 'New session'),
            onPressed: _busy ? null : _createSession,
            icon: const Icon(AppIcons.add),
          ),
        ],
      ),
    );
  }

  Widget _transcript(String Function(String, String) tr) {
    if (_activeSessionId == null) {
      return Center(child: Text(tr('选择已有会话，或新建一个。', 'Choose a session or create one.')));
    }
    if (_lines.isEmpty) {
      return Center(child: Text(tr('会话已连接。发送一条消息开始。', 'Session attached. Send a message to begin.')));
    }
    final showTyping = _streaming && (_lines.isEmpty || _lines.last.role != 'assistant' || _lines.last.tool);
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      itemCount: _lines.length + (showTyping ? 1 : 0),
      itemBuilder: (context, index) {
        if (showTyping && index == _lines.length) {
          return _MessageBubble(role: 'assistant', text: '', streaming: true);
        }
        final line = _lines[index];
        return _MessageBubble(role: line.role, text: line.text, tool: line.tool);
      },
    );
  }

  Widget _composer(String Function(String, String) tr) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: _prompt,
                minLines: 1,
                maxLines: 5,
                enabled: !_busy && _activeSessionId != null,
                textInputAction: TextInputAction.newline,
                decoration: InputDecoration(
                  hintText: tr('发送到 Hermes…', 'Send to Hermes…'),
                  border: const OutlineInputBorder(),
                ),
                onSubmitted: (_) => _sendPrompt(),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              onPressed: _busy || _activeSessionId == null ? null : _sendPrompt,
              tooltip: tr('发送', 'Send'),
              icon: _busy
                  ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(AppIcons.send),
            ),
          ],
        ),
      ),
    );
  }

  HermesGatewayClient? get _client => _directLink?.client ?? _link?.client;
  String? get _connectionLabel => _directLink == null ? null : 'Direct · ${_directLink!.base.host}';

  SshHostConfig? _findHost(HostsState state) {
    for (final host in state.ssh) {
      if (host.id == _selectedHostId) return host;
    }
    return state.ssh.isEmpty ? null : state.ssh.first;
  }

  Future<void> openDirect(HermesGatewayDirectLink link) async {
    if (_link != null || _directLink != null) await _disconnect();
    if (!mounted) { await link.close(); return; }
    _directLink = link;
    _eventSubscription = link.client.events.listen(_onEvent, onError: _setError);
    _requestSubscription = link.client.serverRequests.listen(_onServerRequest);
    _connectionSubscription = link.client.connectionErrors.listen(_onConnectionFailure);
    setState(() { _error = null; _notice = 'Direct · ${link.base.host}'; });
    try {
      final runtime = await link.client.request('runtime.describe');
      final sessionCreate = runtime is Map ? runtime['session_create'] : null;
      final sources = sessionCreate is Map ? sessionCreate['sources'] : null;
      if (sources is! List || !sources.contains('tui')) throw StateError('Hermes Gateway does not advertise session source "tui".');
      await _refreshSessions();
      final selectedSession = _selectedSessionId;
      if (selectedSession != null && _sessions.any((session) => session.id == selectedSession)) await _resumeSession(selectedSession);
    } catch (error) {
      _setError(error);
      await _handleConnectionFailure(error);
    }
  }

  Future<void> _connect(SshHostConfig host) async {
    setState(() {
      _connecting = true;
      _error = null;
      _notice = null;
    });
    try {
      final secrets = await ref.read(hostsProvider.notifier).loadSecrets(host.id);
      final link = await HermesGatewaySshLink.connect(
        config: host,
        secrets: secrets,
        transportFactory: ref.read(sshTransportFactoryProvider),
      );
      if (!mounted) {
        await link.close();
        return;
      }
      _link = link;
      _eventSubscription = link.client.events.listen(_onEvent, onError: _setError);
      _requestSubscription = link.client.serverRequests.listen(_onServerRequest);
      _connectionSubscription = link.client.connectionErrors.listen(_onConnectionFailure);
      setState(() {
        _connecting = false;
        _notice = 'SSH · ${host.name} · ${link.attach.profileId}';
      });
      final runtime = await link.client.request('runtime.describe');
      final sessionCreate = runtime is Map ? runtime['session_create'] : null;
      final sources = sessionCreate is Map ? sessionCreate['sources'] : null;
      if (sources is! List || !sources.contains('tui')) {
        throw StateError('Hermes Gateway does not advertise session source "tui".');
      }
      await _refreshSessions();
      final selectedSession = _selectedSessionId;
      if (selectedSession != null && _sessions.any((session) => session.id == selectedSession)) {
        await _resumeSession(selectedSession);
      }
    } catch (error) {
      if (!mounted) return;
      await _eventSubscription?.cancel();
      await _requestSubscription?.cancel();
      await _connectionSubscription?.cancel();
      _eventSubscription = null;
      _requestSubscription = null;
      _connectionSubscription = null;
      final link = _link;
      _link = null;
      if (link != null) await link.close();
      setState(() {
        _connecting = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _disconnect() async {
    final direct = _directLink;
    _directLink = null;
    if (direct != null) await direct.close();
    final link = _link;
    final sessionId = _activeSessionId;
    final subscriptionId = _activeSubscriptionId;
    _link = null;
    await _eventSubscription?.cancel();
    await _requestSubscription?.cancel();
    await _connectionSubscription?.cancel();
    _eventSubscription = null;
    _requestSubscription = null;
    _connectionSubscription = null;
    _dismissActiveDialog?.call();
    _dismissActiveDialog = null;
    if (link != null) await link.close(sessionId: sessionId, subscriptionId: subscriptionId);
    if (!mounted) return;
    setState(() {
      _activeSessionId = null;
      _activeSubscriptionId = null;
      _selectedSessionId = null;
      _sessions.clear();
      _lines.clear();
      _requestQueue.clear();
      _streaming = false;
      _notice = null;
      _error = null;
    });
  }

  Future<void> _refreshSessions() async {
    final client = _client;
    if (client == null) return;
    try {
      final raw = await client.request('session.list', const {
        'scope': 'stored',
        'limit': 40,
        'include_hidden': false,
        'picker': true,
      });
      final list = _sessionItems(raw);
      if (!mounted) return;
      setState(() {
        _sessions
          ..clear()
          ..addAll(list);
      });
    } catch (error) {
      _setError(error);
    }
  }

  Future<void> _createSession() async {
    final client = _client;
    if (client == null) return;
    final previousSessionId = _activeSessionId;
    final previousSubscriptionId = _activeSubscriptionId;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await client.request('session.create', hermesGatewaySessionCreateParams());
      final id = _stringField(result, const ['session_id', 'id']);
      if (id == null) throw StateError('session.create returned no session_id.');
      // Canonical session.create returns the attached snapshot, including subscription_id.
      final activeId = _stringField(result, const ['session_id']) ?? id;
      final selectedId = _stringField(result, const ['stored_session_id']) ?? id;
      await _attachSnapshot(activeId, result, selectedId: selectedId);
      await _detachPreviousSession(client, previousSessionId, previousSubscriptionId, activeId);
      await _refreshSessions();
    } catch (error) {
      _setError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resumeSession(String id) async {
    final client = _client;
    if (client == null) return;
    final previousSessionId = _activeSessionId;
    final previousSubscriptionId = _activeSubscriptionId;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await client.request('session.resume', {'session_id': id, 'display_projection': true});
      final activeId = _stringField(result, const ['session_id']) ?? id;
      await _attachSnapshot(activeId, result, selectedId: _stringField(result, const ['stored_session_id']) ?? id);
      await _detachPreviousSession(client, previousSessionId, previousSubscriptionId, activeId);
    } catch (error) {
      _setError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _detachPreviousSession(
    HermesGatewayClient client,
    String? previousId,
    String? previousSubscriptionId,
    String activeId,
  ) async {
    if (previousId == null || previousId == activeId || previousSubscriptionId == null) return;
    try {
      await client.request('session.detach', hermesGatewayDetachParams(previousId, previousSubscriptionId));
    } catch (error) {
      _setError(error);
    }
  }

  Future<void> _attachSnapshot(String id, Object? raw, {String? selectedId}) async {
    final client = _client;
    if (client == null) return;
    final snapshot = raw is Map ? Map<String, Object?>.from(raw) : const <String, Object?>{};
    final nested = snapshot['snapshot'] is Map ? Map<String, Object?>.from(snapshot['snapshot'] as Map) : snapshot;
    final messagesRaw = nested['display_messages'] ?? nested['messages'] ?? nested['transcript'];
    final messages = _decodeMessages(messagesRaw);
    if (!mounted) return;
    setState(() {
      _activeSessionId = id;
      _activeSubscriptionId = hermesGatewaySubscriptionId(raw);
      _selectedSessionId = selectedId ?? id;
      _lines
        ..clear()
        ..addAll(messages);
      _streaming = false;
    });
    client.restoreOpenRequests(snapshot['open_requests'] ?? nested['open_requests']);
    final inflight = snapshot['inflight'] ?? nested['inflight'];
    if (inflight is Map && mounted) {
      final displayKind = inflight['display_kind'];
      if (displayKind == 'process_complete') {
        final metadata = inflight['display_metadata'];
        final displayText = metadata is Map ? metadata['display_text'] : null;
        if (displayText is String && displayText.isNotEmpty) {
          setState(() => _lines.add(_GatewayLine(role: 'system', text: displayText, tool: true)));
        }
      } else if (displayKind != 'hidden') {
        final userText = inflight['user'];
        if (userText is String && userText.isNotEmpty) {
          setState(() => _lines.add(_GatewayLine(role: 'user', text: userText)));
        }
      }
      final assistantText = inflight['assistant'];
      if (assistantText is String && assistantText.isNotEmpty && displayKind != 'hidden') {
        setState(() {
          _lines.add(_GatewayLine(role: 'assistant', text: assistantText));
          _streaming = inflight['streaming'] == true;
        });
      }
      final failure = inflight['error'];
      if (failure is String && failure.isNotEmpty) {
        setState(() => _lines.add(_GatewayLine(role: 'system', text: failure, tool: true)));
      }
    }
    _scrollToBottom();
  }

  Future<void> _sendPrompt() async {
    final client = _client;
    final sessionId = _activeSessionId;
    final text = _prompt.text.trim();
    if (client == null || sessionId == null || text.isEmpty) return;
    _prompt.clear();
    setState(() {
      _lines.add(_GatewayLine(role: 'user', text: text));
      _streaming = true;
      _busy = true;
      _error = null;
    });
    _scrollToBottom();
    try {
      await client.request('prompt.submit', hermesGatewayPromptSubmitParams(sessionId, text));
    } catch (error) {
      _setError(error);
      if (mounted) setState(() => _streaming = false);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _onEvent(HermesGatewayEvent event) {
    if (!mounted || (event.sessionId != null && event.sessionId != _activeSessionId)) return;
    final payload = event.payload;
    switch (event.type) {
      case 'request.cancel':
        final id = payload['id'];
        if (id is String && id == _activeRequestId) {
          _cancelledRequestIds.add(id);
          final dismiss = _dismissActiveDialog;
          if (dismiss != null) {
            dismiss();
          } else {
            // A cancel can arrive before showDialog has built its route. Retry after this frame
            // so the just-created approval/clarify dialog does not remain stuck on a withdrawn request.
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && _activeRequestId == id) _dismissActiveDialog?.call();
            });
          }
        } else if (id is String) {
          _requestQueue.removeWhere((request) => request.id == id);
        }
        break;
      case 'message.delta':
        final text = payload['text'];
        if (text is String && text.isNotEmpty) {
          setState(() {
            if (_lines.isEmpty || _lines.last.role != 'assistant' || _lines.last.tool) {
              _lines.add(_GatewayLine(role: 'assistant', text: text));
            } else {
              _lines.last.text += text;
            }
            _streaming = true;
          });
          _scrollToBottom();
        }
        break;
      case 'message.complete':
        final text = payload['text'];
        final terminalError = hermesGatewayEventError(event);
        setState(() {
          if (text is String && text.isNotEmpty) {
            if (_lines.isNotEmpty && _lines.last.role == 'assistant' && !_lines.last.tool) {
              _lines.last.text = text;
            } else {
              _lines.add(_GatewayLine(role: 'assistant', text: text));
            }
          }
          if (terminalError != null) {
            _lines.add(_GatewayLine(role: 'system', text: terminalError, tool: true));
          }
          _streaming = false;
        });
        _scrollToBottom();
        break;
      case 'error':
        final message = hermesGatewayEventError(event);
        if (message != null) {
          setState(() {
            _lines.add(_GatewayLine(role: 'system', text: message, tool: true));
            _streaming = false;
          });
          _scrollToBottom();
        }
        break;
      case 'tool.start':
      case 'tool.generating':
      case 'tool.complete':
        setState(() => _lines.add(_GatewayLine(role: 'tool', text: '${event.type}\n${_pretty(payload)}', tool: true)));
        _scrollToBottom();
        break;
      default:
        break;
    }
  }

  void _onServerRequest(HermesGatewayRequest request) {
    _requestQueue.add(request);
    unawaited(_drainRequestQueue());
  }

  Future<void> _drainRequestQueue() async {
    if (_handlingRequest || !mounted) return;
    _handlingRequest = true;
    try {
      while (_requestQueue.isNotEmpty && mounted) {
        final request = _requestQueue.removeAt(0);
        _activeRequestId = request.id;
        try {
          if (request.method == 'approval') {
            final choice = await _askApproval(request);
            if (!_cancelledRequestIds.remove(request.id)) _client?.respond(request.id, {'choice': choice});
          } else if (request.method == 'clarify') {
            final answers = await _askClarify(request);
            if (!_cancelledRequestIds.remove(request.id)) {
              _client?.respond(
                request.id,
                answers == null ? const {} : {'answers': hermesGatewayClarifyAnswers(answers), 'outcome': 'submitted'},
              );
            }
          }
        } finally {
          _activeRequestId = null;
          _dismissActiveDialog = null;
          _cancelledRequestIds.remove(request.id);
        }
      }
    } finally {
      _handlingRequest = false;
      if (_requestQueue.isNotEmpty && mounted) unawaited(_drainRequestQueue());
    }
  }

  Future<String> _askApproval(HermesGatewayRequest request) async {
    final params = request.params;
    final rawChoices = params['choices'];
    var choices = rawChoices is List ? rawChoices.whereType<String>().toList() : <String>['once', 'deny'];
    if (params['allow_session'] == false) choices.remove('session');
    if (params['allow_permanent'] == false) choices.remove('always');
    if (choices.isEmpty) choices = ['deny'];
    final choice = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        _dismissActiveDialog = () {
          final route = ModalRoute.of(dialogContext);
          if (route?.isCurrent == true) Navigator.of(dialogContext).pop();
        };
        return AlertDialog(
          title: Text(_tr(dialogContext, '需要批准', 'Approval required')),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (params['description'] is String) Text(params['description'] as String),
                if (params['command'] is String) ...[
                  const SizedBox(height: 12),
                  SelectableText(
                    params['command'] as String,
                    style: Theme.of(dialogContext).textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            for (final offered in choices)
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, offered),
                child: Text(_choiceLabel(dialogContext, offered)),
              ),
          ],
        );
      },
    );
    return choice ?? 'deny';
  }

  Future<Map<String, Object?>?> _askClarify(HermesGatewayRequest request) async {
    final rawQuestions = request.params['questions'];
    if (rawQuestions is! List) return null;
    final questions = rawQuestions.whereType<Map>().map((m) => Map<String, Object?>.from(m)).toList();
    final selected = await showDialog<Map<String, Object?>>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        _dismissActiveDialog = () {
          final route = ModalRoute.of(dialogContext);
          if (route?.isCurrent == true) Navigator.of(dialogContext).pop();
        };
        return _ClarifyDialog(questions: questions);
      },
    );
    if (selected == null) return null;
    return {
      for (final question in questions)
        if (question['qid'] is String) question['qid'] as String: selected[question['qid'] as String],
    };
  }

  void _onConnectionFailure(Object error) {
    unawaited(_handleConnectionFailure(error));
  }

  Future<void> _handleConnectionFailure(Object error) async {
    final direct = _directLink;
    _directLink = null;
    if (direct != null) await direct.close();
    final link = _link;
    _link = null;
    await _eventSubscription?.cancel();
    await _requestSubscription?.cancel();
    await _connectionSubscription?.cancel();
    _eventSubscription = null;
    _requestSubscription = null;
    _connectionSubscription = null;
    _dismissActiveDialog?.call();
    _dismissActiveDialog = null;
    _requestQueue.clear();
    if (link != null) await link.close();
    if (!mounted) return;
    setState(() {
      _activeSessionId = null;
      _activeSubscriptionId = null;
      _streaming = false;
      _busy = false;
      _error = error.toString();
      _notice = _selectedSessionId == null
          ? _connectionLabel
          : _tr(context, '连接中断；重新连接后会尝试恢复当前会话。', 'Connection lost; reconnect to restore the active session.');
    });
  }

  void _setError(Object error) {
    if (!mounted) return;
    setState(() => _error = error.toString());
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }
}

class _GatewaySession {
  const _GatewaySession(this.id, this.title);
  final String id;
  final String title;
}

class _GatewayLine {
  _GatewayLine({required this.role, required this.text, this.tool = false});
  final String role;
  String text;
  final bool tool;
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.role, required this.text, this.tool = false, this.streaming = false});
  final String role;
  final String text;
  final bool tool;
  final bool streaming;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final color = tool
        ? colorScheme.tertiaryContainer
        : role == 'user'
        ? colorScheme.primaryContainer
        : colorScheme.surfaceContainerHighest;
    return Align(
      alignment: role == 'user' ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 760),
        margin: const EdgeInsets.symmetric(vertical: 5),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(14)),
        child: SelectableText(text.isEmpty && streaming ? '…' : text),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.text, required this.color});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(10)),
    child: SelectableText(text),
  );
}

class _ClarifyDialog extends StatefulWidget {
  const _ClarifyDialog({required this.questions});
  final List<Map<String, Object?>> questions;

  @override
  State<_ClarifyDialog> createState() => _ClarifyDialogState();
}

class _ClarifyDialogState extends State<_ClarifyDialog> {
  static const _otherValue = '\u0000other';
  final Map<String, Object?> _answers = {};
  final Map<String, TextEditingController> _textControllers = {};

  @override
  void dispose() {
    for (final controller in _textControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Map<String, Object?> _buildAnswers() {
    return {
      for (final question in widget.questions)
        if (question['qid'] is String) question['qid'] as String: _answerFor(question),
    };
  }

  Object? _answerFor(Map<String, Object?> question) {
    final id = question['qid'] as String;
    final choices = question['choices'] is List ? question['choices'] as List : const [];
    if (choices.isEmpty)
      return _textControllers[id]?.text.trim().isNotEmpty == true ? _textControllers[id]!.text.trim() : null;
    if (question['multi_select'] == true) {
      final selected = (_answers[id] as List<String>?) ?? const <String>[];
      return selected.isEmpty ? null : selected;
    }
    final selected = _answers[id];
    if (selected == _otherValue) {
      final text = _textControllers[id]?.text.trim() ?? '';
      return text.isEmpty ? null : text;
    }
    return selected is String ? selected : null;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_tr(context, 'Hermes 在询问', 'Hermes needs clarification')),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [for (final question in widget.questions) _question(context, question)],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(_tr(context, '取消全部', 'Cancel all'))),
        FilledButton(
          onPressed: () => Navigator.pop(context, _buildAnswers()),
          child: Text(_tr(context, '提交答案', 'Submit answers')),
        ),
      ],
    );
  }

  Widget _question(BuildContext context, Map<String, Object?> question) {
    final id = question['qid'] is String ? question['qid'] as String : '';
    final title = question['question'] is String ? question['question'] as String : id;
    final choices = question['choices'] is List
        ? (question['choices'] as List).whereType<String>().toList()
        : <String>[];
    final multi = question['multi_select'] == true;
    if (choices.isEmpty) {
      final controller = _textControllers.putIfAbsent(id, TextEditingController.new);
      return Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title),
            const SizedBox(height: 8),
            TextField(controller: controller, minLines: 1, maxLines: 3),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleSmall),
          if (multi)
            for (final choice in choices)
              CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(choice),
                value: ((_answers[id] as List<String>?) ?? const []).contains(choice),
                onChanged: (selected) => setState(() {
                  final selectedChoices = [...((_answers[id] as List<String>?) ?? const <String>[])];
                  selected == true ? selectedChoices.add(choice) : selectedChoices.remove(choice);
                  _answers[id] = selectedChoices;
                }),
              )
          else ...[
            RadioGroup<String>(
              groupValue: _answers[id] as String?,
              onChanged: (value) => setState(() => _answers[id] = value),
              child: Column(
                children: [
                  for (final choice in choices)
                    RadioListTile<String>(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(choice),
                      value: choice,
                    ),
                  RadioListTile<String>(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(_tr(context, '其他（填写回答）', 'Other (type your answer)')),
                    value: _otherValue,
                  ),
                ],
              ),
            ),
            if (_answers[id] == _otherValue)
              Padding(
                padding: const EdgeInsets.only(left: 12, right: 12, bottom: 8),
                child: TextField(
                  controller: _textControllers.putIfAbsent(id, TextEditingController.new),
                  minLines: 1,
                  maxLines: 3,
                ),
              ),
          ],
        ],
      ),
    );
  }
}

List<_GatewaySession> _sessionItems(Object? raw) {
  Object? candidate = raw;
  if (candidate is Map) candidate = candidate['sessions'] ?? candidate['items'] ?? candidate['results'];
  if (candidate is Map) candidate = candidate['items'] ?? candidate['sessions'];
  if (candidate is! List) return const [];
  final sessions = <_GatewaySession>[];
  for (final entry in candidate) {
    if (entry is! Map) continue;
    final id = _stringField(entry, const ['session_id', 'id']);
    if (id == null) continue;
    final title = _stringField(entry, const ['title', 'name', 'label']) ?? id;
    sessions.add(_GatewaySession(id, title));
  }
  return sessions;
}

List<_GatewayLine> _decodeMessages(Object? raw) {
  if (raw is! List) return const [];
  final result = <_GatewayLine>[];
  for (final item in raw) {
    if (item is! Map) continue;
    final role = _stringField(item, const ['role', 'speaker']) ?? 'assistant';
    final text = _messageText(item['content'] ?? item['text'] ?? item['message']);
    if (text.isNotEmpty) result.add(_GatewayLine(role: role, text: text));
  }
  return result;
}

String _messageText(Object? value) {
  if (value is String) return value;
  if (value is List) {
    return value.map((part) {
      if (part is String) return part;
      if (part is Map && part['text'] is String) return part['text'] as String;
      return '';
    }).join();
  }
  if (value is Map && value['text'] is String) return value['text'] as String;
  return '';
}

String? _stringField(Object? value, List<String> fields) {
  if (value is! Map) return null;
  for (final field in fields) {
    if (value[field] is String && (value[field] as String).isNotEmpty) return value[field] as String;
  }
  return null;
}

String _pretty(Object? value) {
  try {
    return const JsonEncoder.withIndent('  ').convert(value);
  } catch (_) {
    return value.toString();
  }
}

String _tr(BuildContext context, String zh, String en) =>
    Localizations.localeOf(context).languageCode == 'zh' ? zh : en;

String _choiceLabel(BuildContext context, String choice) => switch (choice) {
  'once' => _tr(context, '仅这一次', 'Once'),
  'session' => _tr(context, '本会话', 'This session'),
  'always' => _tr(context, '始终允许', 'Always allow'),
  'deny' => _tr(context, '拒绝', 'Deny'),
  _ => choice,
};
