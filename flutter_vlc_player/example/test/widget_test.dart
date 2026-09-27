// ignore_for_file: prefer_match_file_name
// Widget tests for the VLC subtitle font-size test app.
//
// These tests verify the UI structure without requiring the actual VLC platform
// (which is only available on a real device/simulator).
// Platform-dependent tests live at the integration test level.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// ── Minimal stand-in widgets ────────────────────────────────────────────────
// We recreate only the scaffolding of TestSubtitleApp here so we can test
// the UI structure (app bar title, buttons) without instantiating VlcPlayer.

class _FakeSubtitleTestApp extends StatefulWidget {
  const _FakeSubtitleTestApp();

  @override
  State<_FakeSubtitleTestApp> createState() => _FakeSubtitleTestAppState();
}

class _FakeSubtitleTestAppState extends State<_FakeSubtitleTestApp> {
  String _status = 'Initialized with font size 16 (--freetype-rel-fontsize)';

  static const _fontSizes = <(String, double)>[
    ('Font 8', 8),
    ('Font 14', 14),
    ('Font 16 (default)', 16),
    ('Font 24', 24),
    ('Font 32', 32),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('VLC Font Size Test (MobileVLCKit 3)'),
      ),
      body: SingleChildScrollView(
        child: Column(
          children: [
            // Placeholder instead of VlcPlayer
            const SizedBox(
              height: 200,
              child: Center(child: CircularProgressIndicator()),
            ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                _status,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12, color: Colors.grey),
                key: const Key('status_text'),
              ),
            ),
            Wrap(
              spacing: 8,
              children: [
                for (final (label, size) in _fontSizes)
                  ElevatedButton(
                    onPressed: () => setState(() {
                      _status =
                          'Initialized with font size ${size.toInt()} (--freetype-rel-fontsize)';
                    }),
                    child: Text(label),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ── Tests ────────────────────────────────────────────────────────────────────

void main() {
  testWidgets('App bar renders correct title', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: _FakeSubtitleTestApp()),
    );

    expect(find.text('VLC Font Size Test (MobileVLCKit 3)'), findsOneWidget);
  });

  testWidgets('All font-size buttons are present', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: _FakeSubtitleTestApp()),
    );

    expect(find.text('Font 8'), findsOneWidget);
    expect(find.text('Font 14'), findsOneWidget);
    expect(find.text('Font 16 (default)'), findsOneWidget);
    expect(find.text('Font 24'), findsOneWidget);
    expect(find.text('Font 32'), findsOneWidget);
  });

  testWidgets('Tapping a font button updates the status message',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: _FakeSubtitleTestApp()),
    );

    // Default status shows font 16
    expect(find.textContaining('font size 16'), findsOneWidget);

    // Tap Font 24 button
    await tester.tap(find.text('Font 24'));
    await tester.pump();

    // Status should now mention font 24
    expect(find.textContaining('font size 24'), findsOneWidget);
    expect(find.textContaining('--freetype-rel-fontsize'), findsOneWidget);
  });

  testWidgets('Tapping Font 8 updates status to reflect size 8',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: _FakeSubtitleTestApp()),
    );

    await tester.tap(find.text('Font 8'));
    await tester.pump();

    expect(find.textContaining('font size 8'), findsOneWidget);
  });

  testWidgets('CircularProgressIndicator placeholder is visible',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: _FakeSubtitleTestApp()),
    );

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}
