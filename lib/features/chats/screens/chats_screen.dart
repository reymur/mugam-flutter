import 'dart:ui' as ui;

import 'package:firebase_auth/firebase_auth.dart' hide User;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import '../../../core/search/user_search_controller.dart';
import '../../../core/theme/colors.dart';
import '../../../firebase/firestore_service.dart';
import '../../../firebase/models.dart';
import '../../../shared/widgets/avatar_ring.dart';
import '../../../shared/widgets/zoomable_image_viewer.dart';
import '../../search/screens/filter_sheet.dart';
import '../../settings/screens/app_settings_screen.dart';
import '../../status/screens/create_status_screen.dart';
import '../../status/screens/status_viewer_screen.dart';
import '../widgets/status_feed_bar.dart';
import 'create_group_screen.dart';

const Color _kOnGold = Color(0xFF1A0E00);
const double _kSearchRowHeight = 46;
const double _kSearchCollapsedRowHeight = 16;

class ChatsScreen extends ConsumerStatefulWidget {
  const ChatsScreen({super.key});

  @override
  ConsumerState<ChatsScreen> createState() => _ChatsScreenState();
}

class _ChatsScreenState extends ConsumerState<ChatsScreen>
    with TickerProviderStateMixin {
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _searchScrollController = ScrollController();
  late final String _currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';
  // Search starts hidden — just empty, collapsed space where the field
  // would be — and the AppBar search icon expands it (see _toggleSearch).
  // Drives both the AppBar icon's search<->close morph and the field's
  // height/opacity here in build(), so they stay in lockstep. (An earlier
  // version put a decorative glowing line in the collapsed state; removed
  // per explicit feedback — collapsed is just empty now, no line.)
  late final AnimationController _searchAnimController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 380),
  );
  bool _searchExpanded = false;
  // Same city/instrument/rating/available/online filters as search_screen.dart
  // — reuses its FilterSheet/SearchFilters as-is (see _openFilters below)
  // rather than a separate, chat-specific filter set.
  SearchFilters _filters = const SearchFilters();
  // A query searches Algolia across every user (same as search_screen.dart),
  // not just this user's own chats — a brand-new account with zero
  // conversations would otherwise have no way to find anyone to message
  // from this tab at all. Empty query keeps the original behavior: the
  // existing chats list, unfiltered. Constructed with the current (initially
  // empty) filters string; _openFilters below calls updateFilters when it
  // changes, since UserSearchController's filters aren't otherwise mutable
  // after construction (the picker call sites that also use this class only
  // ever need a fixed exclude-list, never a changing filter set).
  late final UserSearchController _searchCtrl = UserSearchController(
    filters: _filters.toAlgoliaFilters(_currentUid),
  );
  bool _openingChat = false;

  bool get _isSearching =>
      _searchController.text.isNotEmpty || _filters.activeCount > 0;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    _searchScrollController.addListener(_onSearchScroll);
  }

  void _onSearchChanged() {
    setState(() {}); // toggle between the chats list and search results
    _searchCtrl.search(_searchController.text);
  }

  // Closing also clears whatever was typed/filtered — collapsed means "not
  // actively searching" (matches _isSearching), not "paused with state kept
  // around for whenever it's reopened".
  void _toggleSearch() {
    if (_searchExpanded) {
      setState(() {
        _searchExpanded = false;
        _filters = const SearchFilters();
      });
      _searchAnimController.reverse();
      _searchController.clear();
      _searchCtrl.updateFilters(_filters.toAlgoliaFilters(_currentUid));
    } else {
      setState(() => _searchExpanded = true);
      _searchAnimController.forward();
    }
  }

  Future<void> _openFilters() async {
    final result = await FilterSheet.show(
      context,
      initial: _filters,
      nameController: _searchController,
    );
    if (result != null) {
      setState(() => _filters = result);
      _searchCtrl.updateFilters(_filters.toAlgoliaFilters(_currentUid));
    }
  }

  void _onSearchScroll() {
    if (!_searchCtrl.hasMore || _searchCtrl.isLoading || _searchCtrl.isLoadingMore) {
      return;
    }
    if (_searchScrollController.position.pixels >=
        _searchScrollController.position.maxScrollExtent - 200) {
      _searchCtrl.loadMore();
    }
  }

  // Same find-or-create semantics whether `user` is someone already chatted
  // with (getOrCreateDirectChat just resolves back to that existing chat —
  // see its own doc comment, firestore_service.dart) or a brand-new contact
  // discovered only through this search.
  Future<void> _openChatWith(User user) async {
    if (_openingChat) return;
    setState(() => _openingChat = true);
    try {
      // This screen IS the Chat tab, so chatsProvider is already loaded
      // right here — reuse its own most-recently-active pick for this pair
      // (same dedup as the list itself, see firestore_service.dart's
      // bestPerCounterpart) instead of firing getOrCreateDirectChat's own
      // broader reconciliation query, which has to fetch every chat this
      // uid has all over again just to re-derive data already in memory.
      final cachedChats = ref.read(chatsProvider(_currentUid)).asData?.value;
      Chat? cachedMatch;
      if (cachedChats != null) {
        for (final c in cachedChats) {
          if (!c.isGroup && c.members.contains(user.id)) {
            cachedMatch = c;
            break;
          }
        }
      }
      final chatId = cachedMatch?.id ??
          await ref.read(firestoreServiceProvider).getOrCreateDirectChat(
                myUid: _currentUid,
                otherUid: user.id,
              );
      if (!mounted) return;
      context.push('/chat/$chatId');
    } finally {
      if (mounted) setState(() => _openingChat = false);
    }
  }

  @override
  void dispose() {
    _searchAnimController.dispose();
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    _searchScrollController.removeListener(_onSearchScroll);
    _searchScrollController.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    debugPrint('MY UID: ${FirebaseAuth.instance.currentUser?.uid}');
    final currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final chatsAsync = ref.watch(chatsProvider(currentUid));

    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg2,
        automaticallyImplyLeading: false,
        leading: IconButton(
          icon: const Icon(Icons.settings, color: kGold),
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const AppSettingsScreen()),
          ),
        ),
        title: Text(
          'Mesajlar',
          style: GoogleFonts.nunito(fontSize: 20, color: kText),
        ),
        actions: [
          // Search icon morphs into a close (✕) icon while expanded — same
          // AnimationController as the line<->field morph below, so both
          // stay in lockstep. Positioned before group_add, per the approved
          // preview ("between the title and the group icon").
          AnimatedBuilder(
            animation: _searchAnimController,
            builder: (context, _) {
              final t = _searchAnimController.value;
              return IconButton(
                onPressed: _toggleSearch,
                icon: SizedBox(
                  width: 24,
                  height: 24,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Opacity(
                        opacity: (1 - t).clamp(0.0, 1.0),
                        child: Transform.rotate(
                          angle: t * 0.6,
                          child: const Icon(Icons.search, color: kGold),
                        ),
                      ),
                      Opacity(
                        opacity: t,
                        child: Transform.rotate(
                          angle: (1 - t) * -0.6,
                          child: const Icon(Icons.close, color: kGold),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.group_add, color: kGold),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const CreateGroupScreen()),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          StatusFeedBar(
            currentUid: currentUid,
            onCreateStatus: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const CreateStatusScreen()),
            ),
            onOpenStatus: (ownerUid) {
              return Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => StatusViewerScreen(
                    initialOwnerUid: ownerUid,
                    currentUid: currentUid,
                  ),
                ),
              );
            },
          ),
          // Collapsed: just empty space (no decorative line — removed per
          // explicit feedback), tappable to open. Expanded: the field +
          // filter button. Same AnimationController the AppBar icon above
          // uses, so both stay in lockstep. Content (TextField/filter
          // button) only mounts once the box is more than half open
          // (showContent below) — avoids ever laying a real TextField out
          // inside a near-zero-height box.
          AnimatedBuilder(
            animation: _searchAnimController,
            builder: (context, _) {
              final rawT = _searchAnimController.value;
              final t = Curves.easeOutCubic.transform(rawT);
              final showContent = t > 0.5;
              final contentT = ((t - 0.5) / 0.5).clamp(0.0, 1.0);

              return Padding(
                padding: const EdgeInsets.only(left: 16, right: 16, top: 0, bottom: 0),
                child: Row(
                  children: [
                    Expanded(
                      child: GestureDetector(
                        onTap: t < 0.5 ? _toggleSearch : null,
                        child: SizedBox(
                          // Collapsed row is a compact box that grows to
                          // the full field height as t goes 0->1 — kept
                          // separate from _kSearchRowHeight so the
                          // collapsed line doesn't carry the expanded
                          // field's full-height empty space around it. The
                          // line itself is bottom-anchored (Positioned
                          // bottom: 11) rather than centered, so trimming
                          // this height only pulls space off its top.
                          height: _kSearchCollapsedRowHeight +
                              (_kSearchRowHeight - _kSearchCollapsedRowHeight) * t,
                          child: Stack(
                          alignment: Alignment.center,
                          clipBehavior: Clip.none,
                          children: [
                            // Plain gold line + tapered glow, no shimmer/
                            // pulse animation this time — just present
                            // while collapsed, fading out as the field
                            // opens. Glow is a blurred COPY of the same
                            // tapering gradient (not a BoxShadow, which
                            // follows the Container's own rectangular
                            // bounds and doesn't taper — confirmed wrong on
                            // a real device earlier). Small sigma (4), not
                            // 8/16 — a glow around a thin line, not a
                            // cloud.
                            if (t < 0.95)
                              Positioned(
                                bottom: 11,
                                left: 0,
                                right: 0,
                                child: Opacity(
                                opacity: ((1 - t) * 0.55).clamp(0.0, 1.0),
                                child: Stack(
                                  alignment: Alignment.center,
                                  children: [
                                    ImageFiltered(
                                      imageFilter: ui.ImageFilter.blur(sigmaX: 4, sigmaY: 4),
                                      child: Container(
                                        height: 2,
                                        margin: const EdgeInsets.symmetric(horizontal: 4),
                                        decoration: BoxDecoration(
                                          borderRadius: BorderRadius.circular(2),
                                          gradient: LinearGradient(
                                            colors: [
                                              kGold2.withAlpha(0),
                                              kGold2,
                                              kGold2,
                                              kGold2.withAlpha(0),
                                            ],
                                            stops: const [0, 0.1, 0.9, 1],
                                          ),
                                        ),
                                      ),
                                    ),
                                    Container(
                                      height: 2,
                                      margin: const EdgeInsets.symmetric(horizontal: 4),
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(2),
                                        gradient: LinearGradient(
                                          colors: [
                                            kGold2.withAlpha(0),
                                            kGold2,
                                            kGold2,
                                            kGold2.withAlpha(0),
                                          ],
                                          stops: const [0, 0.1, 0.9, 1],
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                ),
                              ),
                            Container(
                          height: _kSearchRowHeight * t,
                          width: double.infinity,
                          decoration: BoxDecoration(
                            color: Color.lerp(Colors.transparent, kBg3, t),
                            borderRadius: BorderRadius.circular(12 * t),
                            border: Border.all(
                              color: Color.lerp(Colors.transparent, kBorder, t) ?? kBorder,
                            ),
                          ),
                          child: showContent
                              ? Opacity(
                                  opacity: contentT,
                                  child: Row(
                                    children: [
                                      const SizedBox(width: 14),
                                      const Icon(Icons.search, color: kMuted, size: 18),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: TextField(
                                          controller: _searchController,
                                          autofocus: true,
                                          style: const TextStyle(color: kText),
                                          decoration: const InputDecoration(
                                            isCollapsed: true,
                                            border: InputBorder.none,
                                            hintText: 'Axtar...',
                                            hintStyle: TextStyle(color: kMuted),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 14),
                                    ],
                                  ),
                                )
                              : null,
                        ),
                          ],
                        ),
                        ),
                      ),
                    ),
                    if (showContent)
                      Opacity(
                        opacity: contentT,
                        child: Padding(
                          padding: const EdgeInsets.only(left: 10),
                          child: InkWell(
                            onTap: _openFilters,
                            borderRadius: BorderRadius.circular(12),
                            child: Container(
                              width: _kSearchRowHeight,
                              height: _kSearchRowHeight,
                              decoration: BoxDecoration(
                                color: _filters.activeCount > 0 ? kGold : kBg3,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: _filters.activeCount > 0 ? kGold : kBorder,
                                ),
                              ),
                              child: Stack(
                                clipBehavior: Clip.none,
                                children: [
                                  Center(
                                    child: Icon(
                                      Icons.tune_rounded,
                                      color: _filters.activeCount > 0 ? _kOnGold : kMuted,
                                    ),
                                  ),
                                  if (_filters.activeCount > 0)
                                    Positioned(
                                      right: -4,
                                      top: -4,
                                      child: Container(
                                        padding: const EdgeInsets.all(3),
                                        constraints: const BoxConstraints(
                                          minWidth: 16,
                                          minHeight: 16,
                                        ),
                                        decoration: const BoxDecoration(
                                          color: kRed,
                                          shape: BoxShape.circle,
                                        ),
                                        child: Text(
                                          '${_filters.activeCount}',
                                          textAlign: TextAlign.center,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 10,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
          Expanded(
            child: _isSearching
                ? _buildUserSearchResults()
                : chatsAsync.when(
                    loading: () => const Center(
                      child: CircularProgressIndicator(color: kGold),
                    ),
                    error: (err, stack) => Center(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          err.toString(),
                          style: const TextStyle(color: kRed, fontSize: 12),
                        ),
                      ),
                    ),
                    data: (chats) {
                      if (chats.isEmpty) {
                        return Center(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 32),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Text('💬', style: TextStyle(fontSize: 52)),
                                const SizedBox(height: 12),
                                Text(
                                  'Hələ mesaj yoxdur',
                                  style: GoogleFonts.nunito(
                                    fontSize: 20,
                                    fontWeight: FontWeight.bold,
                                    color: kText,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                const Text(
                                  'Musiqiçilərlə əlaqə saxlamaq üçün onların profilinə keçin',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(fontSize: 13, color: kMuted),
                                ),
                              ],
                            ),
                          ),
                        );
                      }

                      return ListView.builder(
                        // Explicit (even though zero) — BoxScrollView auto-
                        // applies MediaQuery.padding.top when padding is
                        // null (scroll_view.dart's buildSlivers), and
                        // Scaffold does NOT zero that padding out for body
                        // just because there's an AppBar (only extendBody/
                        // extendBodyBehindAppBar do that — scaffold.dart's
                        // _BodyBuilder). Left implicit, this list silently
                        // added the status-bar inset as extra top padding
                        // on top of what the AppBar above it already
                        // cleared, showing up as a large empty gap.
                        padding: EdgeInsets.zero,
                        itemCount: chats.length,
                        itemBuilder: (context, index) {
                          final chat = chats[index];
                          return _ChatListItem(
                            chat: chat,
                            currentUid: currentUid,
                            onTap: () => context.push('/chat/${chat.id}'),
                          );
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  // Query non-empty: search every user via Algolia (same data source/
  // debounce/pagination as search_screen.dart — see UserSearchController),
  // not just this user's own chats. Tapping a result finds-or-creates the
  // 1:1 chat and opens it, whether or not one already existed.
  Widget _buildUserSearchResults() {
    return ListenableBuilder(
      listenable: _searchCtrl,
      builder: (context, _) {
        if (_searchCtrl.isLoading) {
          return const Center(child: CircularProgressIndicator(color: kGold));
        }
        if (_searchCtrl.error != null) {
          return Center(
            child: Text(_searchCtrl.error!, style: const TextStyle(color: kMuted)),
          );
        }

        final results = _searchCtrl.results;
        if (results.isEmpty) {
          return const Center(
            child: Text(
              'Axtarış nəticəsi tapılmadı',
              style: TextStyle(color: kMuted, fontSize: 14),
            ),
          );
        }

        return ListView.builder(
          controller: _searchScrollController,
          padding: EdgeInsets.zero, // see the chats list's own comment above
          itemCount: results.length + (_searchCtrl.isLoadingMore ? 1 : 0),
          itemBuilder: (context, index) {
            if (index >= results.length) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Center(child: CircularProgressIndicator(color: kGold)),
              );
            }
            final user = results[index];
            return ListTile(
              enabled: !_openingChat,
              onTap: () => _openChatWith(user),
              leading: AvatarRing(
                photoURL: user.photoURL,
                fallbackEmoji: user.emoji,
                hasUnviewed: false,
                size: 48,
              ),
              title: Text(
                user.name,
                style: GoogleFonts.nunito(fontWeight: FontWeight.w700, color: kText),
              ),
              subtitle: Text(
                [user.instrument, user.city].where((s) => s.isNotEmpty).join(' · '),
                style: const TextStyle(color: kMuted, fontSize: 12.5),
              ),
              trailing: Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: user.isActuallyOnline ? kGreen : kMuted,
                  shape: BoxShape.circle,
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _ChatListItem extends ConsumerWidget {
  final Chat chat;
  final String currentUid;
  final VoidCallback onTap;

  const _ChatListItem({
    required this.chat,
    required this.currentUid,
    required this.onTap,
  });

  String _formatTime(DateTime? time) {
    if (time == null) return '';
    final now = DateTime.now();
    final isToday =
        time.year == now.year && time.month == now.month && time.day == now.day;
    return isToday
        ? DateFormat('HH:mm').format(time)
        : DateFormat('dd.MM').format(time);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // mugam-v2 writes a 1:1 chat's `name`/`emoji` fields from the
    // initiator's perspective (the other participant's name/emoji at
    // creation time), never updating them afterwards. The recipient reading
    // that field back sees their OWN name/emoji instead of the initiator's.
    // Resolve the other participant's current name/emoji dynamically
    // instead of trusting those static fields.
    var displayName = chat.name;
    var displayEmoji = chat.emoji;
    User? other;
    if (!chat.isGroup) {
      final otherUid = chat.members.firstWhere(
        (m) => m != currentUid,
        orElse: () => '',
      );
      if (otherUid.isNotEmpty) {
        other = ref.watch(currentUserProvider(otherUid)).value;
        if (other != null) {
          displayName = other.name;
          displayEmoji = other.emoji;
        }
      }
    }
    // "Çatı təmizlə" is per-user: clearedBy.{uid} hides everything up to
    // that moment for one member alone, while lastMessage/lastMessageTime
    // on the chat document are shared by everyone. So the clear can only be
    // honoured where the two meet — here, at display time. Writing the
    // preview away would blank the card for the other party too, who
    // cleared nothing.
    //
    // Until this, clearing a chat emptied the conversation but left its
    // card still showing the last message and its timestamp, which read as
    // the clear having silently failed. A message arriving after the clear
    // is newer than the cutoff and brings the card straight back, with no
    // extra bookkeeping.
    final clearedAt = chat.clearedBy[currentUid];
    final isClearedForViewer =
        clearedAt != null &&
        (chat.lastMessageTime == null ||
            !chat.lastMessageTime!.isAfter(clearedAt));
    final hasActiveStatus = !chat.isGroup && other?.hasActiveStatus == true;
    final viewerUser = hasActiveStatus
        ? ref.watch(currentUserProvider(currentUid)).value
        : null;
    final hasUnviewed =
        hasActiveStatus && (viewerUser?.hasUnviewedStatusFrom(other!) ?? false);
    const avatarBaseSize = 48.0;
    final avatarBoxSize = avatarBaseSize * 1.2;
    void openStatusViewer() => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => UserStatusViewerScreen(
              ownerUid: other!.id,
              currentUid: currentUid,
              initialUser: other,
            ),
          ),
        );

    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                SizedBox(
                  width: avatarBoxSize,
                  height: avatarBoxSize,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      if (hasActiveStatus)
                        GestureDetector(
                          onTap: openStatusViewer,
                          onLongPress: () => showAvatarLongPressMenu(
                            context,
                            photoURL: other?.photoURL,
                            onViewStatus: openStatusViewer,
                          ),
                          child: AvatarRing(
                            photoURL: other?.photoURL,
                            fallbackEmoji: displayEmoji,
                            hasUnviewed: hasUnviewed,
                            size: avatarBoxSize,
                          ),
                        )
                      else
                        GestureDetector(
                          onTap: other?.photoURL != null
                              ? () => showFullImage(context, other!.photoURL!)
                              : null,
                          child: Container(
                            width: avatarBoxSize,
                            height: avatarBoxSize,
                            decoration: BoxDecoration(
                              color: kBg3,
                              shape: BoxShape.circle,
                              border: Border.all(color: kBorder, width: 1.5),
                              image: other?.photoURL != null
                                  ? DecorationImage(
                                      image: NetworkImage(other!.photoURL!),
                                      fit: BoxFit.cover,
                                    )
                                  : null,
                            ),
                            alignment: Alignment.center,
                            child: other?.photoURL == null
                                ? Text(
                                    displayEmoji,
                                    style: const TextStyle(fontSize: 24),
                                  )
                                : null,
                          ),
                        ),
                      if (!chat.isGroup)
                        Positioned(
                          bottom: 0,
                          right: 0,
                          child: Container(
                            width: 12,
                            height: 12,
                            decoration: BoxDecoration(
                              color: other?.isActuallyOnline == true
                                  ? kGreen
                                  : kMuted,
                              shape: BoxShape.circle,
                              border: Border.all(color: kBg2, width: 2),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              displayName,
                              overflow: TextOverflow.ellipsis,
                              style: GoogleFonts.nunito(
                                fontWeight: FontWeight.w700,
                                fontSize: 18,
                                color: kText,
                              ),
                            ),
                          ),
                          Text(
                            isClearedForViewer
                                ? ''
                                : _formatTime(chat.lastMessageTime),
                            style: const TextStyle(fontSize: 13.2, color: kMuted),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              isClearedForViewer
                                  ? ''
                                  : chat.lastMessageDeletedFor.contains(
                                          currentUid,
                                        )
                                      ? '🚫 Bu mesajı sildiniz'
                                      : chat.lastMessage,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 15.6,
                                color: kMuted,
                                fontStyle:
                                    !isClearedForViewer &&
                                        chat.lastMessageDeletedFor.contains(
                                          currentUid,
                                        )
                                    ? FontStyle.italic
                                    : FontStyle.normal,
                              ),
                            ),
                          ),
                          if (chat.unreadCount > 0) ...[
                            const SizedBox(width: 8),
                            Container(
                              width: 20,
                              height: 20,
                              decoration: const BoxDecoration(
                                color: kRed,
                                shape: BoxShape.circle,
                              ),
                              alignment: Alignment.center,
                              child: Text(
                                chat.unreadCount.toString(),
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: kBorder.withAlpha(60), indent: 80),
        ],
      ),
    );
  }
}
