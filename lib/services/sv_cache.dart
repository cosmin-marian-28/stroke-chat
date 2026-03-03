import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// Caches extracted visuals and audio from .sv files.
/// Downloads once, extracts sticker image + audio, stores locally.
class SvCache {
  SvCache._();
  static final instance = SvCache._();

  final Map<String, SvData> _cache = {};
  final Map<String, Future<SvData?>> _pending = {};

  /// Get extracted data for an .sv URL. Returns cached if available.
  Future<SvData?> get(String svUrl) async {
    if (_cache.containsKey(svUrl)) return _cache[svUrl];
    if (_pending.containsKey(svUrl)) return _pending[svUrl];
    final future = _extract(svUrl);
    _pending[svUrl] = future;
    final result = await future;
    _pending.remove(svUrl);
    if (result != null) _cache[svUrl] = result;
    return result;
  }

  Future<SvData?> _extract(String svUrl) async {
    try {
      final res = await http.get(Uri.parse(svUrl));
      if (res.statusCode != 200) return null;

      final archive = ZipDecoder().decodeBytes(res.bodyBytes);
      final dir = await getTemporaryDirectory();
      final hash = svUrl.hashCode.abs();

      String? visualPath;
      String? audioPath;

      for (final file in archive.files) {
        if (file.isFile) {
          final outPath = '${dir.path}/sv_cache_${hash}_${file.name}';
          await File(outPath).writeAsBytes(file.content as List<int>);
          if (file.name.startsWith('sticker')) {
            visualPath = outPath;
          } else if (file.name.startsWith('audio')) {
            audioPath = outPath;
          }
        }
      }

      if (visualPath == null) return null;
      final isVideo = visualPath.endsWith('.mp4');
      return SvData(visualPath: visualPath, audioPath: audioPath, isVideo: isVideo);
    } catch (e) {
      debugPrint('SvCache extract error: $e');
      return null;
    }
  }
}

class SvData {
  final String visualPath;
  final String? audioPath;
  final bool isVideo;
  const SvData({required this.visualPath, this.audioPath, this.isVideo = false});
}
