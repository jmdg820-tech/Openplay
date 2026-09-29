import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openplay_app/widgets/app_version_label.dart';

void main() {
  Future<void> pump(WidgetTester tester, Widget child) =>
      tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));

  testWidgets('shows the release version', (tester) async {
    await pump(tester, const AppVersionLabel(version: '1.0.2'));
    expect(find.text('OpenPlay v1.0.2'), findsOneWidget);
  });

  testWidgets('without OPENPLAY_VERSION it says development build', (tester) async {
    await pump(tester, const AppVersionLabel());
    expect(find.text('OpenPlay (development build)'), findsOneWidget);
  });
}
