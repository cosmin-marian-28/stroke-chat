import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class BgRemovalService {
  static const _channel = MethodChannel('com.strokechat/bg_removal');

  static Future<bool> removeBackground({
    required String inputPath,
    required String outputPath,
    String quality = 'accurate',
  }) async {
    if (!isAvailable) return false;
    try {
      final result = await _channel.invokeMethod('removeBackground', {
        'inputPath': inputPath,
        'outputPath': outputPath,
        'quality': quality,
      });
      return result == true;
    } on PlatformException catch (e) {
      debugPrint('BgRemoval error: ${e.message}');
      return false;
    }
  }

  static Future<int> removeBgBatch({
    required List<String> inputPaths,
    required List<String> outputPaths,
    String quality = 'accurate',
  }) async {
    if (!isAvailable) return 0;
    try {
      final result = await _channel.invokeMethod('removeBgBatch', {
        'inputPaths': inputPaths,
        'outputPaths': outputPaths,
        'quality': quality,
      });
      return result as int? ?? 0;
    } on PlatformException catch (e) {
      debugPrint('BgRemoval batch error: ${e.message}');
      return 0;
    }
  }

  static bool get isAvailable => Platform.isIOS;
}
