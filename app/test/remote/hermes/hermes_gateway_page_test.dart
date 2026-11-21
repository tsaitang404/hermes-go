import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/ui/hermes/hermes_gateway_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('Gateway opens under the app Material localization and can switch to SSH', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          locale: Locale('zh'),
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          home: HermesGatewayPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Hermes Gateway'), findsOneWidget);
    expect(find.text('网关直连'), findsOneWidget);
    expect(find.text('网关 URL'), findsOneWidget);
    expect(find.text('网关密码'), findsOneWidget);

    await tester.tap(find.text('网关直连'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('SSH 隧道').last);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('通过已保存的 SSH 主机'), findsOneWidget);
    expect(find.text('网关 URL'), findsNothing);
  });
}
