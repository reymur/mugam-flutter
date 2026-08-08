import 'package:firebase_auth/firebase_auth.dart' hide User;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../core/models/activity_type.dart';
import '../../../core/theme/colors.dart';
import '../../../shared/widgets/topbar.dart';
import '../../../shared/widgets/avatar_ring.dart';
import '../../../shared/widgets/zoomable_image_viewer.dart';
import '../../../firebase/models.dart';
import '../../../firebase/firestore_service.dart';
import '../../job_offer/job_offer_entry.dart';
import '../../status/screens/status_viewer_screen.dart';
import '../../user/screens/user_profile_screen.dart';

// ── Screen ────────────────────────────────────────────────────────────────────

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        child: Column(
          children: [
            // Бейдж уведомлений снят СОВСЕМ, а не обнулён (решение
            // владельца 07.08): здесь стояло вшитое `notificationCount: 3`
            // — у человека постоянно висела тройка вне всякой связи с
            // тем, сколько у него уведомлений, а нажатие не делало ничего
            // (N64). Ноль на месте числа читался бы как поломка; вернём
            // с настоящим числом, когда появятся настоящие уведомления.
            const Topbar(onLanguageTap: null),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: const [
                    // ВХОД С ГЛАВНОГО (пункт 6, `docs/plan.md`) — тот
                    // самый, который не знает НИЧЕГО: ни человека, ни
                    // дня. Именно он и проверяет, что «предложить можно
                    // откуда угодно» держится на точке вызова, а не на
                    // осведомлённости входов: спрашивает недостающее не
                    // экран, а она.
                    //
                    // Кнопка стоит НАД списком музыкантов, а не под ним:
                    // список длинный и прокручивается, а действие
                    // относится ко всему экрану, а не к последнему в нём.
                    _OfferFromHomeButton(),
                    // Баннер «RƏSMİ KLUB» снят 07.08 вместе с двумя
                    // кнопками, ни одна из которых не делала ничего —
                    // «Musiqiçi Tap» и «Elan Ver» (N65). Нажатие без
                    // ответа человек читает как поломку, а не как
                    // незаконченность. Обещания вернутся кнопками, когда
                    // за ними будет что открыть: поиск уже есть на
                    // «Axtar», объявления — работа по N60.
                    _MusiciansSection(),
                    // Секции «Tədbirlər» и «Otaqlar» сняты 07.08 вместе с
                    // вшитыми в код майскими концертами: в проде коллекции
                    // events и rooms ПУСТЫ, значит `list.isEmpty` было
                    // истинно всегда и живым людям показывалась выдумка.
                    // Пустые секции вместо неё не оставлены намеренно —
                    // молчащий заголовок читается как поломка, а главный
                    // экран всё равно переписывается своим шагом плана.
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// «Предложить работу» с главного экрана — вход, не знающий ничего.
///
/// Ни человека, ни дня он не передаёт: и то и другое спрашивает точка
/// вызова. Своего вопроса «кому?» здесь нет намеренно — заведи его тут, и
/// вопрос будет задан столькими способами, сколько входов.
class _OfferFromHomeButton extends ConsumerWidget {
  const _OfferFromHomeButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: OutlinedButton(
        onPressed: () => proposeJobOffer(context, ref),
        style: OutlinedButton.styleFrom(
          side: const BorderSide(color: kGold),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(28),
          ),
          padding: const EdgeInsets.symmetric(vertical: 14),
        ),
        child: const Text(
          '📅 İş təklif et',
          style: TextStyle(color: kGold, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }
}

// ── Musicians section ─────────────────────────────────────────────────────────

class _MusiciansSection extends ConsumerWidget {
  const _MusiciansSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncMusicians = ref.watch(musiciansProvider);
    final currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          margin: const EdgeInsets.only(top: 18, bottom: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Musiqiçilər',
                style: GoogleFonts.nunito(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: kText,
                ),
              ),
              const Text(
                'Hamısı →',
                style: TextStyle(
                  fontSize: 12,
                  color: kGold,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 240,
          child: asyncMusicians.when(
            data: (list) {
              final musicians = list.excludingUid(currentUid);
              if (musicians.isEmpty) {
                return const _EmptyMusicians(
                  message: 'Musiqiçi tapılmadı',
                );
              }
              return ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: musicians.length,
                itemBuilder: (context, index) => Padding(
                  padding: EdgeInsets.only(
                    right: index == musicians.length - 1 ? 0 : 12,
                  ),
                  child: _MusicianCard(musician: musicians[index]),
                ),
              );
            },
            loading: () => const Center(
              child: CircularProgressIndicator(color: kGold),
            ),
            error: (_, _) => const _EmptyMusicians(
              message: 'Musiqiçilər yüklənmədi',
            ),
          ),
        ),
      ],
    );
  }
}

class _EmptyMusicians extends StatelessWidget {
  final String message;

  const _EmptyMusicians({required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.people_outline_rounded, color: kMuted, size: 32),
          const SizedBox(height: 8),
          Text(
            message,
            style: const TextStyle(color: kMuted, fontSize: 13),
          ),
        ],
      ),
    );
  }
}

class _MusicianCard extends ConsumerWidget {
  final User musician;

  const _MusicianCard({required this.musician});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final hasActiveStatus = musician.hasActiveStatus;
    final viewerUser = hasActiveStatus
        ? ref.watch(currentUserProvider(currentUid)).value
        : null;
    final hasUnviewed =
        hasActiveStatus && (viewerUser?.hasUnviewedStatusFrom(musician) ?? false);
    const avatarBaseSize = 58.0;
    final avatarBoxSize = avatarBaseSize * 1.2;
    void openStatusViewer() => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => UserStatusViewerScreen(
              ownerUid: musician.id,
              currentUid: currentUid,
              initialUser: musician,
            ),
          ),
        );
    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => UserProfileScreen(user: musician),
        ),
      ),
      child: Container(
        width: 140,
        decoration: BoxDecoration(
          color: kCard,
          border: Border.all(
            color: musician.goldRing ? kGold : kBorder,
          ),
          borderRadius: BorderRadius.circular(18),
        ),
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: SizedBox(
                    width: avatarBoxSize,
                    height: avatarBoxSize,
                    child: Stack(
                      children: [
                        if (hasActiveStatus)
                          GestureDetector(
                            onTap: openStatusViewer,
                            onLongPress: () => showAvatarLongPressMenu(
                              context,
                              photoURL: musician.photoURL,
                              onViewStatus: openStatusViewer,
                            ),
                            child: AvatarRing(
                              photoURL: musician.photoURL,
                              fallbackEmoji: musician.emoji,
                              hasUnviewed: hasUnviewed,
                              size: avatarBoxSize,
                            ),
                          )
                        else
                          GestureDetector(
                            onTap: musician.photoURL != null
                                ? () => showFullImage(context, musician.photoURL!)
                                : null,
                            child: Container(
                              width: avatarBoxSize,
                              height: avatarBoxSize,
                              decoration: BoxDecoration(
                                color: kBg3,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: musician.goldRing ? kGold : kBorder,
                                  width: 2,
                                ),
                                image: musician.photoURL != null
                                    ? DecorationImage(
                                        image: NetworkImage(musician.photoURL!),
                                        fit: BoxFit.cover,
                                      )
                                    : null,
                              ),
                              child: musician.photoURL == null
                                  ? Center(
                                      child: Text(
                                        musician.emoji,
                                        style: const TextStyle(fontSize: 24),
                                      ),
                                    )
                                  : null,
                            ),
                          ),
                        Positioned(
                          bottom: 0,
                          left: 0,
                          child: Container(
                            width: 12,
                            height: 12,
                            decoration: BoxDecoration(
                              color: musician.isActuallyOnline ? kGreen : kMuted,
                              shape: BoxShape.circle,
                              border: Border.all(color: kCard, width: 2),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  musician.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: GoogleFonts.nunito(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: kText,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  formatActivityForCard(musician.activityType, musician.instrument),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 11,
                    color: kGold,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  musician.city,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 11,
                    color: kMuted,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  '⭐ ${musician.rating} (${musician.reviews})',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 10,
                    color: kMuted,
                  ),
                ),
                const Spacer(),
                // Кнопка «Dəvət et» снята 07.08: она не делала ничего
                // (N65). Пригласить музыканта можно с его страницы —
                // карточка по нажатию её и открывает.
              ],
            ),
          ),
          if (musician.available)
            Positioned(
              top: 8,
              right: 8,
              child: Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: kGreen,
                  shape: BoxShape.circle,
                  border: Border.all(color: kCard, width: 2),
                ),
              ),
            ),
        ],
      ),
      ),
    );
  }
}
