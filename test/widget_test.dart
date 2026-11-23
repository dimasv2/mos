
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_application_1/main.dart';

void main() {
  testWidgets('MOS FT Maos menampilkan splash screen',
      (WidgetTester tester) async {

    await tester.pumpWidget(
      const MaterialApp(
        home: SplashPage(),
      ),
    );

    expect(find.byType(SplashPage), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
  });
}
