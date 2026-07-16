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

// Thrown only when a caller-supplied cancelSignal actually stopped a
// compression in progress (surfaced from the native "CANCELLED"
// PlatformException both platforms now raise symmetrically — see
// NativeVideoCompressorPlugin.kt's pendingCompressResult fix and the
// matching iOS reader/writer cancellation path). Deliberately distinct
// from every other failure path below, which falls back to the
// uncompressed original instead of throwing — a caller-triggered cancel is
// the one case that must NOT fall back, since silently uploading the
// original after the user explicitly cancelled would defeat the point of
// cancelling.
class VideoCompressionCancelledException implements Exception {
  @override
  String toString() => 'VideoCompressionCancelledException';
}

// Re-encodes filePath via the platform's native hardware encoder —
// AVAssetReader/Writer on iOS (NativeVideoCompressorPlugin.swift), Media3
// Transformer on Android (NativeVideoCompressorPlugin.kt) — behind one
// Dart API so callers don't need per-platform branches. Falls back to the
// original path on any other failure (unsupported format, device-specific
// codec crash, a second call arriving while one is already busy) so a
// compression error never blocks sending, only sends the uncompressed
// original.
// startTimeMs/endTimeMs are optional — when both are provided, the
// native side trims to that range as part of the same compress pass
// (AVAssetReader.timeRange on iOS, MediaItem.ClippingConfiguration on
// Android) rather than compressing then trimming separately. Used by
// the over-30s-video flow (manual trim picker and auto-split into
// consecutive 30s segments) — see create_status_screen.dart.
// cancelSignal is optional — a caller wanting mid-compression cancel
// creates a Completer<void>, holds onto it, and completes it later (see
// UploadProgressScreen._cancelItem). A bare Completer parameter rather
// than changing this function's return type into some handle object keeps
// every other existing call site (none of which need cancellation)
// untouched.
Future<String> compressVideoFile(
  String filePath, {
  required bool hd,
  void Function(double progress)? onProgress,
  int? startTimeMs,
  int? endTimeMs,
  Completer<void>? cancelSignal,
}) async {
  final dir = await getTemporaryDirectory();
  final outputPath =
      '${dir.path}/compressed_video_${DateTime.now().microsecondsSinceEpoch}.mp4';
  StreamSubscription? progressSub;
  if (cancelSignal != null) {
    unawaited(cancelSignal.future.then((_) => _channel.invokeMethod('cancel')));
  }
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
      if (startTimeMs != null) 'startTimeMs': startTimeMs,
      if (endTimeMs != null) 'endTimeMs': endTimeMs,
    });
    if (!await File(outputPath).exists()) return filePath;
    return outputPath;
  } on PlatformException catch (e) {
    if (e.code == 'CANCELLED') throw VideoCompressionCancelledException();
    return filePath;
  } catch (_) {
    return filePath;
  } finally {
    await progressSub?.cancel();
  }
}
