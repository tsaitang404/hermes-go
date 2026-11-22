import 'package:flutter/material.dart' show SelectableText;
import 'package:flutter/widgets.dart';

/// Plain, scrollable error details that work before Material localization exists.
class FullErrorWidget extends StatelessWidget {
  const FullErrorWidget({super.key, required this.details});
  final FlutterErrorDetails details;

  @override
  Widget build(BuildContext context) => Directionality(
    textDirection: TextDirection.ltr,
    child: ColoredBox(
      color: const Color(0xFF171717),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Application error', style: TextStyle(color: Color(0xFFF2F2F2), fontSize: 20, fontWeight: FontWeight.bold)),
              const SizedBox(height: 16),
              const Text('Exception', style: TextStyle(color: Color(0xFFF2F2F2), fontWeight: FontWeight.bold)),
              SelectableText(details.exceptionAsString(), style: const TextStyle(color: Color(0xFFF2F2F2), fontSize: 14)),
              const SizedBox(height: 16),
              const Text('Stack trace', style: TextStyle(color: Color(0xFFF2F2F2), fontWeight: FontWeight.bold)),
              SelectableText(
                details.stack?.toString() ?? '<no stack trace available>',
                style: const TextStyle(color: Color(0xFFF2F2F2), fontFamily: 'monospace', fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
