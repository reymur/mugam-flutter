import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart' hide User;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../core/theme/colors.dart';
import '../../../firebase/firestore_service.dart';
import '../../../firebase/models.dart';
import '../../../shared/widgets/avatar_ring.dart';
import '../../../shared/widgets/zoomable_image_viewer.dart';
import '../../status/screens/status_viewer_screen.dart';
import '../../user/screens/user_profile_screen.dart';
import '../../starred/screens/starred_messages_screen.dart';

// Matches WhatsApp's "About Contact" screen layout. The User model has
// no phone number field (checked across the whole schema), so the contact's
// name takes the large primary text slot that WhatsApp uses for the phone
// number, with online status as the secondary muted line underneath.
class AboutContactScreen extends ConsumerStatefulWidget {
  final String chatId;
  final String contactUid;

  const AboutContactScreen({
    super.key,
    required this.chatId,
    required this.contactUid,
  });

  @override
  ConsumerState<AboutContactScreen> createState() =>
      _AboutContactScreenState();
}

// isActuallyOnline's staleness threshold is ~2 minutes (see User model /
// docs/presence-system.md); this screen's live Firestore listener
// (currentUserProvider) only rebuilds when the document actually changes,
// not as time simply passes, so a periodic no-op setState is needed to
// re-evaluate isActuallyOnline against a fresh DateTime.now(). 20s is
// frequent enough that the dot flips to offline within a few tens of
// seconds of actually going stale, without being wasteful — it's a pure
// widget rebuild, no refetch, and the underlying heartbeat only writes
// every 60s anyway.
const _presenceRefreshInterval = Duration(seconds: 20);

class _AboutContactScreenState extends ConsumerState<AboutContactScreen> {
  Timer? _presenceRefreshTimer;

  @override
  void initState() {
    super.initState();
    _presenceRefreshTimer = Timer.periodic(_presenceRefreshInterval, (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _presenceRefreshTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final userAsync = ref.watch(currentUserProvider(widget.contactUid));

    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg2,
        elevation: 0,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: kGold),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          'Kontakt haqqında',
          style: GoogleFonts.playfairDisplay(fontSize: 18, color: kText),
        ),
      ),
      body: userAsync.when(
        loading: () =>
            const Center(child: CircularProgressIndicator(color: kGold)),
        error: (_, _) => const Center(
          child: Text('Xəta baş verdi', style: TextStyle(color: kMuted)),
        ),
        data: (user) {
          if (user == null) {
            return const Center(
              child: Text('İstifadəçi tapılmadı', style: TextStyle(color: kMuted)),
            );
          }
          return SingleChildScrollView(
            child: Column(
              children: [
                const SizedBox(height: 28),
                _ContactAvatar(user: user),
                const SizedBox(height: 18),
                Text(
                  user.name,
                  textAlign: TextAlign.center,
                  style: GoogleFonts.playfairDisplay(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: kText,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  user.isActuallyOnline ? '● Onlayn' : '○ Oflayn',
                  style: TextStyle(
                    fontSize: 13,
                    color: user.isActuallyOnline ? const Color(0xFF4CAF50) : kMuted,
                  ),
                ),
                const SizedBox(height: 24),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: _ProfileButton(
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => UserProfileScreen(user: user),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                _SettingsGroup(
                  children: [
                    _MediaTile(chatId: widget.chatId),
                    _SettingsTile(
                      icon: Icons.storage_outlined,
                      title: 'Yaddaşın idarə edilməsi',
                      onTap: () => _showStub(context),
                    ),
                    _StarredTile(chatId: widget.chatId),
                  ],
                ),
                const SizedBox(height: 16),
                _SettingsGroup(
                  children: [
                    _SettingsTile(
                      icon: Icons.palette_outlined,
                      title: 'Söhbət mövzusu',
                      onTap: () => _showStub(context),
                    ),
                    _SettingsTile(
                      icon: Icons.download_outlined,
                      title: '"Foto"da saxla',
                      trailing: 'Standart',
                      onTap: () => _showStub(context),
                    ),
                  ],
                ),
                const SizedBox(height: 32),
              ],
            ),
          );
        },
      ),
    );
  }

  static void _showStub(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Bu funksiya tezliklə əlavə olunacaq'),
        backgroundColor: kBg3,
      ),
    );
  }
}

class _ContactAvatar extends ConsumerWidget {
  final User user;
  const _ContactAvatar({required this.user});

  Widget _plainAvatar() {
    return Container(
      width: 140 * 1.2,
      height: 140 * 1.2,
      decoration: BoxDecoration(
        color: kBg3,
        shape: BoxShape.circle,
        border: Border.all(color: kBorder, width: 1),
        image: user.photoURL != null
            ? DecorationImage(
                image: NetworkImage(user.photoURL!),
                fit: BoxFit.cover,
              )
            : null,
      ),
      child: user.photoURL == null
          ? Center(
              child: Text(user.emoji, style: const TextStyle(fontSize: 64)),
            )
          : null,
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!user.hasActiveStatus) {
      return GestureDetector(
        onTap: user.photoURL != null
            ? () => showFullImage(context, user.photoURL!)
            : null,
        child: _plainAvatar(),
      );
    }

    final currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final viewerUser = ref.watch(currentUserProvider(currentUid)).value;
    final hasUnviewed = viewerUser?.hasUnviewedStatusFrom(user) ?? false;

    void openStatusViewer() => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => UserStatusViewerScreen(
              ownerUid: user.id,
              currentUid: currentUid,
              initialUser: user,
            ),
          ),
        );

    return GestureDetector(
      onTap: openStatusViewer,
      onLongPress: () => showAvatarLongPressMenu(
        context,
        photoURL: user.photoURL,
        onViewStatus: openStatusViewer,
      ),
      child: AvatarRing(
        photoURL: user.photoURL,
        fallbackEmoji: user.emoji,
        hasUnviewed: hasUnviewed,
        size: 140 * 1.2,
      ),
    );
  }
}

// Single button in place of WhatsApp's "Сообщение"/"Поиск" pair — visual
// style (rounded box, icon over label, translucent border) kept, but using
// the app's gold accent instead of WhatsApp green to match the rest of the
// app's button language.
class _ProfileButton extends StatelessWidget {
  final VoidCallback onTap;
  const _ProfileButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: kBg3,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 20),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: kGold.withAlpha(90)),
          ),
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.person_outline, color: kGold, size: 30),
              SizedBox(height: 8),
              Text(
                'Profil',
                style: TextStyle(
                  color: kText,
                  fontWeight: FontWeight.w600,
                  fontSize: 16,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SettingsGroup extends StatelessWidget {
  final List<Widget> children;
  const _SettingsGroup({required this.children});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        decoration: BoxDecoration(
          color: kCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: kBorder),
        ),
        child: Column(
          children: [
            for (int i = 0; i < children.length; i++) ...[
              children[i],
              if (i < children.length - 1)
                const Divider(height: 1, color: kBorder, indent: 52),
            ],
          ],
        ),
      ),
    );
  }
}

class _SettingsTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? trailing;
  final VoidCallback onTap;

  const _SettingsTile({
    required this.icon,
    required this.title,
    required this.onTap,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: kGold, size: 22),
      title: Text(title, style: const TextStyle(color: kText, fontSize: 15)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (trailing != null)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Text(trailing!, style: const TextStyle(color: kMuted, fontSize: 13)),
            ),
          const Icon(Icons.chevron_right, color: kMuted, size: 20),
        ],
      ),
      onTap: onTap,
    );
  }
}

// Real data: counts this chat's image messages, matching the reference
// screenshot's "97" style trailing count. Tapping is still a stub — a full
// media grid viewer is out of scope for this round.
class _MediaTile extends ConsumerWidget {
  final String chatId;
  const _MediaTile({required this.chatId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(chatMetaProvider(chatId)).value?['mediaImageCount']
        as int?;
    return _SettingsTile(
      icon: Icons.image_outlined,
      title: 'Media, keçidlər və sənədlər',
      trailing: count == null ? null : '$count',
      onTap: () => _AboutContactScreenState._showStub(context),
    );
  }
}

// Real data + real navigation: shows this chat's starred-message count and
// opens the per-chat filtered Starred Messages view (Part 4).
class _StarredTile extends ConsumerWidget {
  final String chatId;
  const _StarredTile({required this.chatId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final starredAsync = ref.watch(starredMessagesProvider(currentUid));
    final count = starredAsync.value
        ?.where((m) => m.chatId == chatId)
        .length;
    return _SettingsTile(
      icon: Icons.star_border,
      title: 'Seçilmişlər',
      trailing: count == null ? null : (count == 0 ? 'Yoxdur' : '$count'),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) =>
              StarredMessagesScreen(chatId: chatId, title: 'Seçilmişlər'),
        ),
      ),
    );
  }
}
