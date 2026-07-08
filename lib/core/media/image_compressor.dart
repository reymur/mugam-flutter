import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:path_provider/path_provider.dart';

// Standard quality caps the long side at 1280px — the target for chat
// photos on a slow connection. HD keeps the device's original resolution
// (minWidth/minHeight set far above anything a phone camera produces —
// the plugin only ever downscales, never upscales, so this is a no-op
// resize) and only re-encodes at a higher JPEG quality, matching
// WhatsApp's documented HD behavior.
const _standardMinDimension = 1280;
const _standardQuality = 70;
const _hdMinDimension = 10000;
const _hdQuality = 90;

// Re-encodes filePath into a temp JPEG at the requested quality tier.
// Falls back to the original, uncompressed path on any failure so a
// codec error or unsupported format never blocks sending the photo.
Future<String> compressImageFile(String filePath, {required bool hd}) async {
  try {
    final dir = await getTemporaryDirectory();
    final targetPath =
        '${dir.path}/compressed_${DateTime.now().microsecondsSinceEpoch}.jpg';
    final result = await FlutterImageCompress.compressAndGetFile(
      filePath,
      targetPath,
      minWidth: hd ? _hdMinDimension : _standardMinDimension,
      minHeight: hd ? _hdMinDimension : _standardMinDimension,
      quality: hd ? _hdQuality : _standardQuality,
      format: CompressFormat.jpeg,
    );
    return result?.path ?? filePath;
  } catch (_) {
    return filePath;
  }
}
