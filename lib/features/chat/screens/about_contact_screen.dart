import 'package:firebase_auth/firebase_auth.dart' hide User;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../core/theme/colors.dart';
import '../../../firebase/firestore_service.dart';
import '../../../firebase/models.dart';
import '../../status/widgets/status_ring.dart';
import '../../user/screens/user_profile_screen.dart';
import '../../starred/screens/starred_messages_screen.dart';
import '../../../shared/widgets/online_dot.dart';

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

// ТАЙМЕР ЭТОГО ЭКРАНА СНЯТ 18.09, И ВОТ ЧТО ОН ДЕРЖАЛ.
//
// Заводился он ради надписи «Onlayn», а остался — проверкой до снятия — ради
// второго дела, здесь не названного ни словом: ободок истории гаснет по
// сроку годности, а не по изменению документа.
//
// Теперь у обоих признаков часы внутри своих виджетов: кружок «в сети» —
// `shared/widgets/online_dot.dart`, ободок истории —
// `features/status/widgets/status_ring.dart`, будильник у них общий
// (`core/time/stale_clock.dart`). Во всём этом файле от хода времени зависели
// ровно эти два места, и оба уехали — значит держать здесь пустой `setState`
// больше не за чем.

class _AboutContactScreenState extends ConsumerState<AboutContactScreen> {
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
          style: GoogleFonts.nunito(fontSize: 18, color: kText),
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
                  style: GoogleFonts.nunito(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: kText,
                  ),
                ),
                // ЗДЕСЬ СТОЯЛА НАДПИСЬ «● Onlayn / ○ Oflayn» — снята решением
                // владельца 18.09 вместе с её собственным зелёным
                // (`Color(0xFF4CAF50)`, отличным от `kGreen` у всех кружков).
                // «В сети» теперь показывается одним и тем же кружком везде;
                // сам он уехал на портрет выше.
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

class _ContactAvatar extends StatelessWidget {
  final User user;
  const _ContactAvatar({required this.user});

  @override
  Widget build(BuildContext context) {
    final currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    return Stack(
      clipBehavior: Clip.none,
      children: [
        // СВЁРНУТО 18.09. Здесь стояла развилка по `hasActiveStatus` — своя,
        // одна из одиннадцати таких, — и вместе с ней обход к просмотрщику,
        // длинное нажатие и подписка на свой профиль. Всё это уехало в
        // `StatusRing`, а вместе с ним уехал и таймер, который этот экран
        // держал ради срока годности истории.
        //
        // Вид ветви «истории нет» сохранён точно: ободок `kBorder` толщиной 1
        // и знак 64 переданы параметрами, а не подогнаны под умолчания
        // виджета (2.5 и `size * 0.45` дали бы рамку толще и знак крупнее).
        StatusRing(
          user: user,
          currentUid: currentUid,
          size: 140 * 1.2,
          fallbackEmoji: user.emoji,
          plainRingColor: kBorder,
          plainRingWidth: 1,
          plainFallbackFontSize: 64,
        ),
        // КРУЖОК «В СЕТИ» НА ПОРТРЕТЕ — вместо снятой надписи «Onlayn» под
        // именем (владелец, 18.09). Восемнадцать точек и рамка в три — как на
        // экране профиля: там такой же крупный портрет, и двенадцатиточечный
        // кружок на нём потерялся бы. Цвет рамки здесь `kBg`, а не `kHeroBg`:
        // это фон ЭТОГО экрана, а рамка кружка — всегда цвет того, что под
        // ним.
        Positioned(
          bottom: 6,
          right: 6,
          child: OnlineDot(
            user: user,
            size: 18,
            borderColor: kBg,
            borderWidth: 3,
          ),
        ),
      ],
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
//
// Читает точный счёт по запросу (chatImageCountProvider), а не поле
// mediaImageCount из документа чата: поле убрано вместе с записями,
// которые его вели (N3 — см. FirestoreService.countChatImages). Тот же
// приём, что у соседнего _StarredTile, который тоже считает по данным, а
// не по денормализованному числу.
class _MediaTile extends ConsumerWidget {
  final String chatId;
  const _MediaTile({required this.chatId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(chatImageCountProvider(chatId)).value;
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
