import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_agent/ui/intro.dart';
import 'package:life_agent/ui/theme.dart';

void main() {
  testWidgets('the sunrise plays first, then the app is there', (t) async {
    await t.pumpWidget(
      const MaterialApp(
        home: IntroGate(child: Scaffold(body: Text('the app'))),
      ),
    );
    expect(find.byKey(const Key('intro')), findsOneWidget);
    await t.pump(const Duration(milliseconds: 700));
    expect(
      find.byKey(const Key('intro')),
      findsOneWidget,
      reason: 'still playing',
    );
    await t.pump(const Duration(milliseconds: 1000));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('intro')), findsNothing);
    expect(find.text('the app'), findsOneWidget);
  });

  testWidgets('a tap skips it', (t) async {
    await t.pumpWidget(
      const MaterialApp(
        home: IntroGate(child: Scaffold(body: Text('the app'))),
      ),
    );
    await t.tap(find.byKey(const Key('intro')));
    await t.pump();
    expect(find.byKey(const Key('intro')), findsNothing);
    await t.pumpAndSettle();
  });

  testWidgets('with animations off or disabled the app shows at once', (
    t,
  ) async {
    await t.pumpWidget(
      const MaterialApp(
        home: IntroGate(enabled: false, child: Scaffold(body: Text('the app'))),
      ),
    );
    expect(find.byKey(const Key('intro')), findsNothing);
    expect(find.text('the app'), findsOneWidget);

    await t.pumpWidget(
      const MediaQuery(
        data: MediaQueryData(disableAnimations: true),
        child: MaterialApp(
          home: IntroGate(child: Scaffold(body: Text('the app'))),
        ),
      ),
    );
    expect(find.byKey(const Key('intro')), findsNothing);
  });

  test('the theme uses the icon colours and dark text on coral buttons', () {
    final light = lifeTheme(Brightness.light).colorScheme;
    final dark = lifeTheme(Brightness.dark).colorScheme;
    expect(light.primary, Brand.coral);
    expect(light.onPrimary, Brand.ink);
    expect(light.surface, Brand.cream);
    expect(dark.primary, Brand.coral);
    // dark text on coral must be readable (WCAG contrast of at least 4.5)
    double lum(Color c) {
      double f(double v) => v <= 0.03928
          ? v / 12.92
          : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
      return 0.2126 * f(c.r) + 0.7152 * f(c.g) + 0.0722 * f(c.b);
    }

    final a = lum(Brand.coral), b = lum(Brand.ink);
    expect((a + 0.05) / (b + 0.05), greaterThan(4.5));
  });

  test('every picture the screens use is in the app and small', () {
    for (final name in [
      'home_header',
      'night_card',
      'morning_card',
      'empty_list',
      'chat_welcome',
    ]) {
      final f = File('assets/images/$name.webp');
      expect(f.existsSync(), isTrue, reason: name);
      expect(
        f.lengthSync(),
        lessThan(60 * 1024),
        reason: '$name should stay small',
      );
    }
  });
}
