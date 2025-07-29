// This is a basic example of a Flutter test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app_2_note_detection_real_time_final/main.dart';

void main() {
  testWidgets('Guitar Tuner app smoke test', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(MyApp());

    // Verify that our guitar tuner starts with "No Input" text.
    expect(find.text('No Input'), findsOneWidget);
    expect(find.text('Professional Guitar Tuner'), findsOneWidget);

    // Verify that we have the main control buttons
    expect(find.text('Start'), findsOneWidget);
    expect(find.text('Reference'), findsOneWidget);

    // Verify the tuning dropdown exists
    expect(find.text('Standard'), findsOneWidget);
  });

  testWidgets('Settings dialog test', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(MyApp());

    // Tap the settings icon to open settings dialog
    await tester.tap(find.byIcon(Icons.settings));
    await tester.pumpAndSettle();

    // Verify settings dialog content
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Reference Pitch (A4)'), findsOneWidget);
    expect(find.text('Tuning Tolerance'), findsOneWidget);
    expect(find.text('Guitar Mode'), findsOneWidget);
    expect(find.text('Keep Screen Awake'), findsOneWidget);
    expect(find.text('Detection Algorithm'), findsOneWidget);
  });

  testWidgets('History dialog test', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(MyApp());

    // Tap the history icon to open history dialog
    await tester.tap(find.byIcon(Icons.history));
    await tester.pumpAndSettle();

    // Verify history dialog content
    expect(find.text('Detection History'), findsOneWidget);
    expect(find.text('No detections yet'), findsOneWidget);
  });

  testWidgets('Tuning preset selector test', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(MyApp());

    // Find the dropdown button and tap it
    final dropdownFinder = find.byType(DropdownButton<String>);
    await tester.tap(dropdownFinder);
    await tester.pumpAndSettle();

    // Verify all tuning presets are available
    expect(find.text('Standard'), findsWidgets);
    expect(find.text('Drop D'), findsOneWidget);
    expect(find.text('Open G'), findsOneWidget);
    expect(find.text('DADGAD'), findsOneWidget);
  });
}