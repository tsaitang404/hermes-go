import 'dart:async';

import 'package:flutter/material.dart';
import 'package:dsh_app/remote/hermes/hermes_gateway_direct.dart';
import 'package:dsh_app/remote/hermes/hermes_gateway_client.dart';
import 'package:dsh_app/ui/hermes/hermes_gateway_page.dart';

class HermesGatewayDirectPage extends StatefulWidget {
  const HermesGatewayDirectPage({super.key});
  @override
  State<HermesGatewayDirectPage> createState() => _HermesGatewayDirectPageState();
}

class _HermesGatewayDirectPageState extends State<HermesGatewayDirectPage> {
  final _address = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  HermesGatewayDirectLink? _link;
  String? _error;
  bool _busy = false;
  bool _handedOff = false;
  bool _sessionOpen = false;
  bool _didDisconnect = false;
  @override
  void dispose() {
    _address.dispose();
    _username.dispose();
    _password.dispose();
    if (!_handedOff) unawaited(_link?.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Hermes Gateway')),
    body: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_link == null) ...[
            TextField(
              controller: _address,
              decoration: const InputDecoration(labelText: 'Gateway URL', hintText: 'https://gateway.example'),
            ),
            TextField(
              controller: _username,
              decoration: const InputDecoration(labelText: 'Username'),
            ),
            TextField(
              controller: _password,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Password'),
            ),
            const SizedBox(height: 12),
            FilledButton(onPressed: _busy ? null : _connect, child: Text(_busy ? 'Connecting…' : 'Connect')),
          ] else if (_sessionOpen) ...[
            const Text('Connected · Gateway sessions are open.'),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: _busy ? null : _disconnect, child: const Text('Disconnect')),
          ],
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
        ],
      ),
    ),
  );

  Future<void> _connect() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final link = await HermesGatewayDirectLink.connect(
        address: _address.text,
        signIn: HermesGatewayPassword(_username.text, _password.text),
      );
      if (!mounted) {
        await link.close();
        return;
      }
      setState(() {
        _link = link;
        _handedOff = true;
        _sessionOpen = true;
        _password.clear();
      });
      await Navigator.of(context)
          .push<void>(MaterialPageRoute<void>(builder: (_) => HermesGatewayPage(directLink: link)));
      await link.close();
      if (mounted)
        setState(() {
          _link = null;
          _handedOff = false;
          _sessionOpen = false;
          _error = _didDisconnect ? 'Disconnected from Hermes Gateway.' : 'Gateway connection ended.';
        });
    } on HermesGatewayDirectException catch (e) {
      if (mounted)
        setState(
          () => _error = switch (e.reason) {
            HermesGatewayDirectFailure.passwordUnavailable => 'This Gateway does not offer password sign-in.',
            HermesGatewayDirectFailure.rejected => 'Gateway rejected the sign-in.',
            HermesGatewayDirectFailure.rateLimited => 'Too many sign-in attempts. Try again later.',
            HermesGatewayDirectFailure.httpsRequired =>
              'Use HTTPS for remote Gateways; HTTP is allowed only on this device.',
            _ => 'Could not connect to Hermes Gateway (${e.reason.name}).',
          },
        );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disconnect() async {
    final link = _link;
    setState(() {
      _didDisconnect = true;
      _link = null;
      _sessionOpen = false;
      _handedOff = false;
    });
    await link?.close();
  }
}
