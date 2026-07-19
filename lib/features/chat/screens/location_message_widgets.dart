import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/theme/colors.dart';
import 'video_message_widgets.dart'
    show MediaOverlayChip, MessageDeliveryStatus, UploadProgressOverlay;

// Static-location chat bubble: the map snapshot image (see
// LocationPickerScreen._captureSnapshot) fills the bubble edge-to-edge —
// same treatment as ImageMessageBubble/VideoMessageBubble — tap opens the
// coordinates in the OS's own native Maps app(s) instead of an in-app
// zoomable viewer, since there's nothing further to see in-app once
// you're looking at a map. Fixed-aspect box rather than the source
// image's own dimensions (unlike a real photo, a map snapshot has no
// meaningful "natural" aspect ratio worth preserving).
class LocationMessageBubble extends StatelessWidget {
  static const double _width = 240;
  static const double _height = 150;

  final String? locationImageURL;
  final String? localFilePath;
  final double? latitude;
  final double? longitude;
  // Shown as the pin's label in the native maps app (matching WhatsApp's
  // own "<Sender name> (Вы)"-style pin) — the sender's display name,
  // already resolved by the caller (see chat_screen.dart's
  // _replySenderName, reused as-is rather than duplicated here).
  final String? senderLabel;
  final double bubbleRadius;
  final Widget timeCheckmarkOverlay;
  // Single computed source of truth (see deliveryStatusFor) — same value
  // the corner checkmark and every other media bubble already key off.
  final MessageDeliveryStatus deliveryStatus;
  final double? localUploadProgress;
  final VoidCallback? onCancelUpload;
  // Optional caption (Message.text) — same treatment as ImageMessageBubble,
  // see its own caption field comment for the full rationale.
  final String caption;
  final bool isMe;

  const LocationMessageBubble({
    super.key,
    this.locationImageURL,
    this.localFilePath,
    this.latitude,
    this.longitude,
    this.senderLabel,
    required this.bubbleRadius,
    required this.timeCheckmarkOverlay,
    required this.deliveryStatus,
    this.localUploadProgress,
    this.onCancelUpload,
    this.caption = '',
    required this.isMe,
  });

  void _showOpenFailedSnackbar(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Xəritə açıla bilmədi'),
        backgroundColor: kRed,
      ),
    );
  }

  Future<void> _openInMaps(BuildContext context) async {
    final lat = latitude;
    final lng = longitude;
    if (lat == null || lng == null) return;
    final label = Uri.encodeComponent(senderLabel ?? 'Məkan');

    // Both platforms now build an explicit per-service candidate list
    // rather than trusting a single shared URI scheme (geo: on Android,
    // a bare custom scheme on iOS) to reliably reach the right app.
    // Android's own OS-level "choose an app" dialog for geo: was assumed
    // to make an explicit picker unnecessary there, but two real
    // on-device reports this session (a non-Google-Maps app misreading
    // the label-bearing q= form, then Waze itself opening the wrong
    // coordinates even from the label-free form) showed geo: is
    // interpreted inconsistently enough across real installed apps that
    // it can't be trusted as the one shared mechanism — each app instead
    // gets its own real, documented, unambiguous deep link, exactly like
    // the iOS branch already did.
    final candidates = <(String label, Uri uri, IconData icon, Color color)>[];

    if (Platform.isIOS) {
      // iOS has no built-in disambiguation for custom URL schemes —
      // launchUrl silently opens whichever app matches first, so
      // replicate WhatsApp's own "Choose app" sheet: offer every
      // installed maps app we can actually detect. Apple Maps is always
      // the baseline; Google Maps/Waze only get added if canLaunchUrl
      // confirms they're really installed (both schemes are declared in
      // Info.plist's LSApplicationQueriesSchemes — required for
      // canLaunchUrl to report anything but false on iOS 9+, per Apple's
      // own restriction). iOS gives no public API for a regular app to
      // fetch another app's real installed icon by bundle id — that's
      // what makes the system Share Sheet's own "choose app" list able
      // to show live icons, but it's not something a third-party app can
      // replicate for a custom URL-scheme picker like this one. Each
      // service gets its own recognizable icon+brand color instead (not
      // exact logos, but distinguishable at a glance without needing
      // bundled trademarked icon assets).
      candidates.add((
        'Apple Maps',
        Uri.parse('https://maps.apple.com/?ll=$lat,$lng&q=$label'),
        Icons.map,
        const Color(0xFF007AFF),
      ));
      if (await canLaunchUrl(Uri.parse('comgooglemaps://'))) {
        candidates.add((
          'Google Maps',
          Uri.parse('comgooglemaps://?center=$lat,$lng&q=$lat,$lng($label)'),
          Icons.location_on,
          const Color(0xFFEA4335),
        ));
      }
    } else {
      // Android — Google Maps is the always-present baseline here (its
      // own universal maps.google.com link, not the ambiguous geo:
      // scheme; opens the app directly if installed, else the web page,
      // so no canLaunchUrl detection is even needed for it).
      candidates.add((
        'Google Maps',
        Uri.parse(
          'https://www.google.com/maps/search/?api=1&query=$lat,$lng',
        ),
        Icons.location_on,
        const Color(0xFFEA4335),
      ));
    }

    // Waze uses the exact same real, documented deep link on both
    // platforms (ll=lat,lng&navigate=yes) — the one already proven
    // correct on iOS; the bug Teymur found was specifically the
    // Android side going through the ambiguous shared geo: URI instead
    // of this.
    if (await canLaunchUrl(Uri.parse('waze://'))) {
      candidates.add((
        'Waze',
        Uri.parse('waze://?ll=$lat,$lng&navigate=yes'),
        Icons.navigation,
        const Color(0xFF33CCFF),
      ));
    }

    if (!context.mounted) return;
    final Uri? chosen;
    if (candidates.length == 1) {
      chosen = candidates.first.$2;
    } else {
      chosen = await showModalBottomSheet<Uri>(
        context: context,
        backgroundColor: kBg2,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        builder: (sheetContext) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final candidate in candidates)
                ListTile(
                  leading: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: candidate.$4,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(candidate.$3, color: Colors.white, size: 20),
                  ),
                  title: Text(
                    candidate.$1,
                    style: const TextStyle(color: kText),
                  ),
                  onTap: () => Navigator.of(sheetContext).pop(candidate.$2),
                ),
            ],
          ),
        ),
      );
    }
    if (chosen == null) return;
    final opened = await launchUrl(chosen, mode: LaunchMode.externalApplication);
    if (!opened && context.mounted) _showOpenFailedSnackbar(context);
  }

  @override
  Widget build(BuildContext context) {
    final isUploading =
        deliveryStatus == MessageDeliveryStatus.queued ||
        deliveryStatus == MessageDeliveryStatus.uploading;
    final hasCaption = caption.trim().isNotEmpty;

    final mapStack = ClipRRect(
      borderRadius: hasCaption
          ? BorderRadius.only(
              topLeft: Radius.circular(bubbleRadius),
              topRight: Radius.circular(bubbleRadius),
            )
          : BorderRadius.circular(bubbleRadius),
      child: SizedBox(
        width: _width,
        height: _height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Container(color: kBg3),
            localFilePath != null
                ? Image.file(File(localFilePath!), fit: BoxFit.cover)
                : CachedNetworkImage(
                    imageUrl: locationImageURL!,
                    fit: BoxFit.cover,
                    placeholder: (ctx, url) =>
                        const Center(
                          child: CircularProgressIndicator(color: kGold),
                        ),
                    errorWidget: (ctx, url, err) => Container(
                      color: kBg3,
                      child: const Icon(
                        Icons.location_off,
                        color: kMuted,
                      ),
                    ),
                  ),
            if (isUploading)
              UploadProgressOverlay(
                progress: deliveryStatus == MessageDeliveryStatus.uploading
                    ? localUploadProgress
                    : null,
                onCancel: onCancelUpload,
              ),
            if (!hasCaption)
              Positioned(
                right: 8,
                bottom: 8,
                child: MediaOverlayChip(child: timeCheckmarkOverlay),
              ),
          ],
        ),
      ),
    );

    if (!hasCaption) {
      return GestureDetector(
        onTap: isUploading ? null : () => _openInMaps(context),
        child: mapStack,
      );
    }

    return GestureDetector(
      onTap: isUploading ? null : () => _openInMaps(context),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(bubbleRadius),
        child: Container(
          width: _width,
          color: isMe ? kGold : kBg3,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              mapStack,
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Flexible(
                      child: Text(
                        caption,
                        style: TextStyle(
                          color: isMe
                              ? const Color(0xFF1A0E00)
                              : kText,
                          fontSize: 14,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    timeCheckmarkOverlay,
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
