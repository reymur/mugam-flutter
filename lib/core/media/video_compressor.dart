import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

// Standard tier targets WhatsApp's documented non-HD profile (720p short
// side, ~1.2 Mbps). HD keeps the same 720p cap — unlike photos, WhatsApp's
// video HD mode does not preserve original resolution, only raises bitrate
// — but re-encodes at a noticeably higher bitrate for less visible
// compression artifacting.
const _shortSide = 720;
const _baseBitrate = 1200000;
const _hdBitrate = 3000000;

const _channel = MethodChannel('mugam/native_video_compressor');
const _progressChannel = EventChannel('mugam/native_video_compressor/progress');

// Re-encodes filePath via the platform's native hardware encoder —
// AVAssetReader/Writer on iOS (NativeVideoCompressorPlugin.swift), Media3
// Transformer on Android (NativeVideoCompressorPlugin.kt) — behind one
// Dart API so callers don't need per-platform branches. Falls back to the
// original path on any failure (unsupported format, device-specific codec
// crash, a second call arriving while one is already busy) so a
// compression error never blocks sending, only sends the uncompressed
// original.
Future<String> compressVideoFile(
  String filePath, {
  required bool hd,
  void Function(double progress)? onProgress,
}) async {
  final dir = await getTemporaryDirectory();
  final outputPath =
      '${dir.path}/compressed_video_${DateTime.now().microsecondsSinceEpoch}.mp4';
  StreamSubscription? progressSub;
  try {
    if (onProgress != null) {
      progressSub = _progressChannel.receiveBroadcastStream().listen((event) {
        if (event is double) onProgress(event);
      });
    }
    await _channel.invokeMethod('compress', {
      'path': filePath,
      'outputPath': outputPath,
      'shortSide': _shortSide,
      'bitrate': hd ? _hdBitrate : _baseBitrate,
    });
    if (!await File(outputPath).exists()) return filePath;
    return outputPath;
  } catch (_) {
    return filePath;
  } finally {
    await progressSub?.cancel();
  }
}
