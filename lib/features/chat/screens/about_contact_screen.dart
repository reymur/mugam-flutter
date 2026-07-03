import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../core/theme/colors.dart';
import '../../../firebase/firestore_service.dart';
import '../../../firebase/models.dart';
import '../../musician/screens/musician_profile_screen.dart';
import '../../starred/screens/starred_messages_screen.dart';

// Matches WhatsApp's "About Contact" screen layout. The Musician model has
// no phone number field (checked across the whole schema), so the contact's
// name takes the large primary text slot that WhatsApp uses for the phone
// number, with online status as the secondary muted line underneath.
class AboutContactScreen extends ConsumerWidget {
  final String chatId;
  final String contactUid;

  const AboutContactScreen({
    super.key,
    required this.chatId,
    required this.contactUid,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final musicianAsync = ref.watch(userByIdProvider(contactUid));

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
      body: musicianAsync.when(
        loading: () =>
            const Center(child: CircularProgressIndicator(color: kGold)),
        error: (_, _) => const Center(
          child: Text('Xəta baş verdi', style: TextStyle(color: kMuted)),
        ),
        data: (musician) {
          if (musician == null) {
            return const Center(
              child: Text('İstifadəçi tapılmadı', style: TextStyle(color: kMuted)),
            );
          }
          return SingleChildScrollView(
            child: Column(
              children: [
                const SizedBox(height: 28),
                _ContactAvatar(musician: musician),
                const SizedBox(height: 18),
                Text(
                  musician.name,
                  textAlign: TextAlign.center,
                  style: GoogleFonts.playfairDisplay(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: kText,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  musician.online ? '● Onlayn' : '○ Oflayn',
                  style: TextStyle(
                    fontSize: 13,
                    color: musician.online ? const Color(0xFF4CAF50) : kMuted,
                  ),
                ),
                const SizedBox(height: 24),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 60),
                  child: _ProfileButton(
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => MusicianProfileScreen(musician: musician),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                _SettingsGroup(
                  children: [
                    _MediaTile(chatId: chatId),
                    _SettingsTile(
                      icon: Icons.storage_outlined,
                      title: 'Yaddaşın idarə edilməsi',
                      onTap: () => _showStub(context),
                    ),
                    _StarredTile(chatId: chatId),
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

class _ContactAvatar extends StatelessWidget {
  final Musician musician;
  const _ContactAvatar({required this.musician});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 140,
      height: 140,
      decoration: BoxDecoration(
        color: kBg3,
        shape: BoxShape.circle,
        border: Border.all(color: kBorder, width: 1),
        image: musician.photoURL != null
            ? DecorationImage(
                image: NetworkImage(musician.photoURL!),
                fit: BoxFit.cover,
              )
            : null,
      ),
      child: musician.photoURL == null
          ? Center(
              child: Text(musician.emoji, style: const TextStyle(fontSize: 64)),
            )
          : null,
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
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: kGold.withAlpha(90)),
          ),
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.person_outline, color: kGold),
              SizedBox(height: 6),
              Text(
                'Profil',
                style: TextStyle(color: kText, fontWeight: FontWeight.w600),
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
    final messagesAsync = ref.watch(messagesProvider(chatId));
    final count = messagesAsync.value?.where((m) => m.type == 'image').length;
    return _SettingsTile(
      icon: Icons.image_outlined,
      title: 'Media, keçidlər və sənədlər',
      trailing: count == null ? null : '$count',
      onTap: () => AboutContactScreen._showStub(context),
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
