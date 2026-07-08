import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/media/image_compressor.dart';
import '../../../core/theme/colors.dart';

// WhatsApp/Google-Maps-style "pick a location" flow: the pin stays fixed
// at the screen center and the MAP moves under it (via onCameraMove),
// rather than a draggable Marker object — avoids marker-hitbox/drag
// ergonomics entirely and matches how every major app does this picker.
// On confirm, captures a snapshot of the map+pin (no Google Static Maps
// API call, no extra billed API/key, reuses the same compressImageFile
// pipeline real photos already go through) and returns (latitude,
// longitude, snapshotFilePath) via Navigator.pop, or null if the user
// backs out.
class LocationPickerScreen extends StatefulWidget {
  const LocationPickerScreen({super.key});

  @override
  State<LocationPickerScreen> createState() => _LocationPickerScreenState();
}

class _LocationPickerScreenState extends State<LocationPickerScreen> {
  // Baku city center — sensible fallback if location permission is denied
  // or a fix can't be obtained in time, given this app's user base.
  static const LatLng _fallbackCenter = LatLng(40.4093, 49.8671);

  // Only wraps the pin icon, NOT the GoogleMap — a RenderRepaintBoundary
  // can't capture a native PlatformView's content (confirmed on-device:
  // it silently produced a blank white square where the map should have
  // been, since GoogleMap renders through a platform view, not ordinary
  // Flutter painting). The pin is plain Flutter-drawn content, so this
  // boundary captures it correctly; the map itself is captured separately
  // via GoogleMapController.takeSnapshot() (see _captureSnapshot), the
  // plugin's own purpose-built method for exactly this.
  final GlobalKey _pinKey = GlobalKey();

  GoogleMapController? _controller;
  LatLng _center = _fallbackCenter;
  bool _locating = true;
  bool _confirming = false;
  // Gates the confirm button: takeSnapshot() captures whatever the native
  // map view has ACTUALLY painted at that instant — confirmed on-device
  // that tapping "send" right as the map first appears (or right after a
  // "use current location" re-center) can catch it mid-tile-load, still
  // showing the SDK's own blank placeholder fill for streets/buildings
  // even though the pin and the "my location" dot (both already-loaded,
  // one native-drawn/one ours) show up fine. onCameraIdle has no direct
  // "tiles finished" signal to key off (the plugin doesn't expose one),
  // so this debounces a short buffer after the camera actually stops
  // moving instead — cheap, and long enough in practice for the tile
  // fetch already in flight to land.
  bool _mapReady = false;
  Timer? _readyTimer;

  @override
  void initState() {
    super.initState();
    _locateMe();
  }

  @override
  void dispose() {
    _readyTimer?.cancel();
    super.dispose();
  }

  void _onCameraMoveStarted() {
    if (_mapReady) setState(() => _mapReady = false);
  }

  void _onCameraIdle() {
    _readyTimer?.cancel();
    _readyTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _mapReady = true);
    });
  }

  Future<void> _locateMe() async {
    if (mounted) setState(() => _locating = true);
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return;
      }
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return;
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 8),
        ),
      );
      final target = LatLng(position.latitude, position.longitude);
      if (!mounted) return;
      setState(() => _center = target);
      _controller?.animateCamera(CameraUpdate.newLatLng(target));
    } catch (_) {
      // Fine to fall back silently — the map still opens centered on
      // _fallbackCenter, the user can pan manually.
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  // Composites GoogleMapController.takeSnapshot()'s bitmap (the actual map
  // imagery — roads, buildings, whatever the native SDK last rendered)
  // with a separately-captured image of the pin icon (see _pinKey's doc
  // comment for why these can't be captured together), pasted so its
  // bottom tip lands exactly on the map image's own pixel center — which
  // is precisely the picked coordinate, since onCameraMove tracks the
  // camera's center and the map fills this screen edge-to-edge. Both
  // captures use the same devicePixelRatio so the pin's logical 44x44 size
  // scales consistently against the map bitmap's own physical-pixel
  // resolution. Re-encoded through the same JPEG compressor real photos
  // use afterward, so a location message's upload size behaves the same
  // way a photo's does.
  Future<String?> _captureSnapshot() async {
    final controller = _controller;
    if (controller == null) return null;
    ui.Image? mapImage;
    ui.Image? pinImage;
    ui.Image? composed;
    try {
      final mapBytes = await controller.takeSnapshot();
      if (mapBytes == null) return null;
      final mapCodec = await ui.instantiateImageCodec(mapBytes);
      mapImage = (await mapCodec.getNextFrame()).image;

      final pinBoundary =
          _pinKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (pinBoundary != null && mounted) {
        final dpr = MediaQuery.of(context).devicePixelRatio;
        pinImage = await pinBoundary.toImage(pixelRatio: dpr);
      }

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      final width = mapImage.width.toDouble();
      final height = mapImage.height.toDouble();
      canvas.drawImage(mapImage, Offset.zero, Paint());
      if (pinImage != null) {
        final dx = width / 2 - pinImage.width / 2;
        final dy = height / 2 - pinImage.height;
        canvas.drawImage(pinImage, Offset(dx, dy), Paint());
      }
      final picture = recorder.endRecording();
      composed = await picture.toImage(mapImage.width, mapImage.height);
      final byteData = await composed.toByteData(
        format: ui.ImageByteFormat.png,
      );
      if (byteData == null) return null;
      final bytes = byteData.buffer.asUint8List();
      final dir = await getTemporaryDirectory();
      final rawPath =
          '${dir.path}/location_${DateTime.now().microsecondsSinceEpoch}.png';
      await File(rawPath).writeAsBytes(bytes);
      final compressedPath = await compressImageFile(rawPath, hd: false);
      if (compressedPath != rawPath) {
        unawaited(File(rawPath).delete().catchError((_) => File(rawPath)));
      }
      return compressedPath;
    } catch (_) {
      return null;
    } finally {
      mapImage?.dispose();
      pinImage?.dispose();
      composed?.dispose();
    }
  }

  Future<void> _confirm() async {
    setState(() => _confirming = true);
    final snapshotPath = await _captureSnapshot();
    if (!mounted) return;
    if (snapshotPath == null) {
      setState(() => _confirming = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Xəritə şəkli alına bilmədi'),
          backgroundColor: kRed,
        ),
      );
      return;
    }
    Navigator.of(
      context,
    ).pop((_center.latitude, _center.longitude, snapshotPath));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg2,
        title: const Text('Məkan seçin', style: TextStyle(color: kText)),
        iconTheme: const IconThemeData(color: kGold),
      ),
      body: Stack(
        alignment: Alignment.center,
        children: [
          GoogleMap(
            initialCameraPosition: CameraPosition(target: _center, zoom: 15),
            onMapCreated: (c) => _controller = c,
            onCameraMoveStarted: _onCameraMoveStarted,
            onCameraMove: (pos) => _center = pos.target,
            onCameraIdle: _onCameraIdle,
            myLocationEnabled: true,
            myLocationButtonEnabled: false,
            zoomControlsEnabled: false,
          ),
          // Fixed pin at the exact visual center — this IS the picked
          // point once the map settles, not a drag target of its own.
          // Bottom-padded by half the icon's own height so its TIP (not
          // its center) lands on the map's true center point. Wrapped in
          // its own RepaintBoundary so _captureSnapshot can grab just this
          // icon (see that method's doc comment for why it can't be
          // captured together with the map).
          Padding(
            padding: const EdgeInsets.only(bottom: 22),
            child: RepaintBoundary(
              key: _pinKey,
              child: const Icon(Icons.location_pin, color: kGold, size: 44),
            ),
          ),
          Positioned(
            right: 16,
            bottom: 96,
            child: FloatingActionButton(
              heroTag: 'locate_me',
              backgroundColor: kBg2,
              foregroundColor: kGold,
              onPressed: _locating ? null : _locateMe,
              child: _locating
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: kGold,
                      ),
                    )
                  : const Icon(Icons.my_location),
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 24,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: kGold,
                foregroundColor: const Color(0xFF1A0E00),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onPressed: (_confirming || !_mapReady) ? null : _confirm,
              child: _confirming
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Color(0xFF1A0E00),
                      ),
                    )
                  : Text(
                      _mapReady ? 'Bu məkanı göndər' : 'Xəritə yüklənir...',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
