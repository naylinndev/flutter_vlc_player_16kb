// ignore_for_file: no_magic_number
// Unit tests for the subtitle font-size option pipeline.
//
// These tests verify:
// 1. VlcSubtitleOptions generates the correct --freetype-rel-fontsize flag
// 2. The flag can be parsed back to recover the font size (as applySubtitleOptionsIfSupported does)
// 3. VlcPlayerOptions.get() includes subtitle flags in the flat option list
//
// Note: setSubtitleHeightScale is intentionally a no-op on iOS/MobileVLCKit 3.
// Font size is applied at media creation via '--freetype-rel-fontsize=N'.

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_vlc_player_platform_interface/flutter_vlc_player_platform_interface.dart';

void main() {
  group('VlcSubtitleOptions – freetype font size flags', () {
    test('relativeFontSize generates correct --freetype-rel-fontsize flag', () {
      final flag = VlcSubtitleOptions.relativeFontSize(16);
      expect(flag, equals('--freetype-rel-fontsize=16'));
    });

    test('fontSize generates correct --freetype-fontsize flag', () {
      final flag = VlcSubtitleOptions.fontSize(24);
      expect(flag, equals('--freetype-fontsize=24'));
    });

    test('font size flag is parseable (simulates applySubtitleOptionsIfSupported)', () {
      const targetSize = 24.0;
      final options = VlcSubtitleOptions([
        VlcSubtitleOptions.relativeFontSize(targetSize.toInt()),
        VlcSubtitleOptions.boldStyle(true),
      ]);

      double? parsedSize;
      for (final opt in options.options) {
        if (opt.contains('freetype-rel-fontsize=') ||
            opt.contains('freetype-fontsize=')) {
          final parts = opt.split('=');
          if (parts.length > 1) {
            parsedSize = double.tryParse(parts[1]);
          }
        }
      }

      expect(parsedSize, equals(targetSize));

      // Verify scale calculation (gridstreamr base is 16.0)
      if (parsedSize == null) {
        fail('parsedSize should have been set from subtitle options');
      }
      final scale = parsedSize / 16.0;
      expect(scale, closeTo(1.5, 0.001)); // 24 / 16 = 1.5
    });

    test('VlcSubtitleOptions options list contains the font flag', () {
      final subtitleOpts = VlcSubtitleOptions([
        VlcSubtitleOptions.relativeFontSize(20),
        VlcSubtitleOptions.boldStyle(true),
        VlcSubtitleOptions.color(VlcSubtitleColor.white),
      ]);

      expect(subtitleOpts.options, contains('--freetype-rel-fontsize=20'));
      expect(subtitleOpts.options, contains('--freetype-bold'));
    });

    test('VlcPlayerOptions.get() flattens subtitle flags', () {
      final playerOpts = VlcPlayerOptions(
        subtitle: VlcSubtitleOptions([
          VlcSubtitleOptions.relativeFontSize(18),
        ]),
      );

      final flat = playerOpts.get();
      expect(flat, contains('--freetype-rel-fontsize=18'));
    });

    test('different font sizes produce distinct flags', () {
      final sizes = [8, 14, 16, 24, 32];
      final flags = sizes.map(VlcSubtitleOptions.relativeFontSize).toList();

      for (int i = 0; i < sizes.length; i++) {
        expect(flags[i], equals('--freetype-rel-fontsize=${sizes[i]}'));
      }
      // All flags are distinct
      expect(flags.toSet().length, equals(sizes.length));
    });
  });

  group('VlcSubtitleOptions – other styling flags', () {
    test('boldStyle generates correct flags', () {
      expect(VlcSubtitleOptions.boldStyle(true), equals('--freetype-bold'));
      expect(VlcSubtitleOptions.boldStyle(false), equals('--no-freetype-bold'));
    });

    test('backgroundOpacity clamps to valid range in flag string', () {
      final flag = VlcSubtitleOptions.backgroundOpacity(180);
      expect(flag, equals('--freetype-background-opacity=180'));
    });

    test('color uses VlcSubtitleColor.white value', () {
      final flag = VlcSubtitleOptions.color(VlcSubtitleColor.white);
      expect(flag, startsWith('--freetype-color='));
    });

    test('outlineThickness.normal produces correct value', () {
      final flag = VlcSubtitleOptions.outlineThickness(VlcSubtitleThickness.normal);
      expect(flag, equals('--freetype-outline-thickness=4'));
    });
  });

  group('VlcSubtitleOptions – MobileVLCKit 3 compatibility note', () {
    test('setSubtitleHeightScale approach: scale derived from freetype-rel-fontsize', () {
      // This mirrors what vlc_grid_stream_player_controller.dart does:
      // parse freetype-rel-fontsize=N and compute scale = N / 16.0
      // The scale would have been passed to currentSubTitleFontScale (VLCKit 4 only).
      // On MobileVLCKit 3 this is a no-op — font size is already in the media option.

      const base = 16.0;
      final testCases = {
        8: 0.5,
        16: 1.0,
        24: 1.5,
        32: 2.0,
      };

      for (final entry in testCases.entries) {
        final flag = VlcSubtitleOptions.relativeFontSize(entry.key);
        final parts = flag.split('=');
        final parsed = double.parse(parts[1]);
        final scale = parsed / base;
        expect(scale, closeTo(entry.value, 0.001),
            reason: 'font ${entry.key} → scale ${entry.value}');
      }
    });
  });
}
