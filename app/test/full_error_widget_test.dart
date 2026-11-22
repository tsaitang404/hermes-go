import 'package:dsh_app/diagnostics/full_error_widget.dart';
import 'package:flutter/material.dart' show SelectableText;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows complete exception and stack in a scrollable without MaterialLocalizations', (tester) async {
    final error = StateError('complete exception details');
    final stack = StackTrace.fromString(List.generate(100, (i) => '#$i package:test/file.dart:${i + 1}:2').join('\n'));

    await tester.pumpWidget(FullErrorWidget(details: FlutterErrorDetails(exception: error, stack: stack)));

    expect(find.text('Bad state: complete exception details'), findsOneWidget);
    final stackText = tester.widgetList<SelectableText>(find.byType(SelectableText)).map((text) => text.data ?? '').join('\n');
    expect(stackText, contains('#99 package:test/file.dart:100:2'));
    expect(find.byType(SingleChildScrollView), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('preserves multiline exception and reports absent stack', (tester) async {
    await tester.pumpWidget(const FullErrorWidget(details: FlutterErrorDetails(exception: FormatException('first line\nsecond line'))));
    expect(find.textContaining('first line\nsecond line'), findsOneWidget);
    expect(find.text('<no stack trace available>'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
