import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../core/theme/colors.dart';
import '../../../firebase/firestore_service.dart';
import '../../../shared/widgets/avatar_ring.dart';
import '../../../shared/widgets/zoomable_image_viewer.dart';
import '../../chat/screens/chat_screen.dart';
import '../../status/screens/status_viewer_screen.dart';

// Group-creation screen — mirrors mugam-v2's CreateGroup.tsx + UserPicker.tsx
// exactly in structure (name+emoji row, search, selected-member chips,
// checkbox list), restyled with this app's own design tokens rather than
// mugam-v2's literal colors. See FirestoreService.createGroupChat for the
// Firestore write shape this produces.
class CreateGroupScreen extends ConsumerStatefulWidget {
  // Default (false) preserves this screen's original standalone
  // behavior (chats_screen.dart's "+" button) — land directly in the
  // new group's own ChatScreen via pushReplacement. true is for callers
  // like ForwardSheet that need the new chatId handed back via a plain
  // pop instead, so they can act on it themselves (e.g. forward a
  // message into the just-created group) rather than being replaced by
  // it.
  final bool popWithChatId;

  const CreateGroupScreen({super.key, this.popWithChatId = false});

  @override
  ConsumerState<CreateGroupScreen> createState() => _CreateGroupScreenState();
}

class _CreateGroupScreenState extends ConsumerState<CreateGroupScreen> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _searchController = TextEditingController();
  String _emoji = '👥';
  String _search = '';
  final Set<String> _selectedUids = {};
  bool _creating = false;

  static const List<String> _emojiChoices = [
    '👥', '🎵', '🎸', '🥁', '🎹', '🎺', '🎤', '🎧',
  ];

  @override
  void dispose() {
    _nameController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Qrup adı daxil edin'),
          backgroundColor: kRed,
        ),
      );
      return;
    }
    if (_selectedUids.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Ən az 1 iştirakçı seçin'),
          backgroundColor: kRed,
        ),
      );
      return;
    }
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) return;

    setState(() => _creating = true);
    try {
      final chatId = await ref.read(firestoreServiceProvider).createGroupChat(
        creatorUid: currentUser.uid,
        creatorName: currentUser.displayName ?? 'İstifadəçi',
        groupName: name,
        memberUids: _selectedUids.toList(),
        emoji: _emoji,
      );
      if (!mounted) return;
      if (widget.popWithChatId) {
        Navigator.of(context).pop(chatId);
        return;
      }
      // Replace this create-group screen with the new group's chat, same
      // as mugam-v2's onCreated navigation.
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => ChatScreen(chatId: chatId)),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _creating = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Qrup yaradılmadı'),
          backgroundColor: kRed,
        ),
      );
    }
  }

  void _toggleUser(String uid) {
    setState(() {
      if (_selectedUids.contains(uid)) {
        _selectedUids.remove(uid);
      } else {
        _selectedUids.add(uid);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final usersAsync = ref.watch(allUsersProvider);

    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg2,
        automaticallyImplyLeading: false,
        leading: TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Ləğv et', style: TextStyle(color: kMuted)),
        ),
        title: Text(
          'Yeni qrup',
          style: GoogleFonts.playfairDisplay(fontSize: 16, color: kText),
        ),
        centerTitle: true,
        actions: [
          TextButton(
            onPressed: _creating ? null : _create,
            child: _creating
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: kGold,
                    ),
                  )
                : Text(
                    'Yarat',
                    style: TextStyle(
                      color: kGold.withAlpha(_selectedUids.isEmpty ? 100 : 255),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: kBorder)),
            ),
            child: Row(
              children: [
                GestureDetector(
                  onTap: () => _showEmojiPicker(context),
                  child: Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      color: kBg3,
                      shape: BoxShape.circle,
                      border: Border.all(color: kBorder),
                    ),
                    alignment: Alignment.center,
                    child: Text(_emoji, style: const TextStyle(fontSize: 26)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _nameController,
                    style: const TextStyle(color: kText, fontSize: 16),
                    maxLength: 50,
                    decoration: const InputDecoration(
                      hintText: 'Qrup adı...',
                      hintStyle: TextStyle(color: kMuted),
                      counterText: '',
                      enabledBorder: UnderlineInputBorder(
                        borderSide: BorderSide(color: kBorder),
                      ),
                      focusedBorder: UnderlineInputBorder(
                        borderSide: BorderSide(color: kGold),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          if (_selectedUids.isNotEmpty)
            Container(
              height: 52,
              padding: const EdgeInsets.symmetric(vertical: 8),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: kBorder)),
              ),
              child: usersAsync.when(
                data: (users) {
                  final selected =
                      users.where((u) => _selectedUids.contains(u.id));
                  return ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    children: [
                      for (final u in selected)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: GestureDetector(
                            onTap: () => _toggleUser(u.id),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 6,
                              ),
                              decoration: BoxDecoration(
                                color: kBg3,
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(color: kBorder),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(u.emoji, style: const TextStyle(fontSize: 14)),
                                  const SizedBox(width: 4),
                                  ConstrainedBox(
                                    constraints: const BoxConstraints(maxWidth: 80),
                                    child: Text(
                                      u.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: kText,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 2),
                                  const Text(
                                    '✕',
                                    style: TextStyle(color: kMuted, fontSize: 10),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  );
                },
                loading: () => const SizedBox.shrink(),
                error: (_, _) => const SizedBox.shrink(),
              ),
            ),

          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: TextField(
              controller: _searchController,
              style: const TextStyle(color: kText),
              onChanged: (v) => setState(() => _search = v),
              decoration: InputDecoration(
                hintText: 'Axtar...',
                hintStyle: const TextStyle(color: kMuted),
                filled: true,
                fillColor: kBg3,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12),
              ),
            ),
          ),

          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'İştirakçılar (${_selectedUids.length} seçildi)',
                style: const TextStyle(
                  color: kMuted,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1,
                ),
              ),
            ),
          ),

          Expanded(
            child: usersAsync.when(
              data: (users) {
                final filtered = users.where((u) => u.id != currentUid).where((u) {
                  if (_search.trim().isEmpty) return true;
                  final q = _search.toLowerCase();
                  return u.name.toLowerCase().contains(q) ||
                      u.instrument.toLowerCase().contains(q) ||
                      u.city.toLowerCase().contains(q);
                }).toList();

                if (filtered.isEmpty) {
                  return const Center(
                    child: Text(
                      'Nəticə tapılmadı',
                      style: TextStyle(color: kMuted),
                    ),
                  );
                }

                return ListView.builder(
                  itemCount: filtered.length,
                  itemBuilder: (context, index) {
                    final u = filtered[index];
                    final selected = _selectedUids.contains(u.id);
                    final hasActiveStatus = u.hasActiveStatus;
                    final viewerUser = hasActiveStatus
                        ? ref.watch(currentUserProvider(currentUid)).value
                        : null;
                    final hasUnviewed = hasActiveStatus &&
                        (viewerUser?.hasUnviewedStatusFrom(u) ?? false);
                    const avatarBaseSize = 46.0;
                    final avatarBoxSize = avatarBaseSize * 1.2;
                    void openStatusViewer() => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => UserStatusViewerScreen(
                              ownerUid: u.id,
                              currentUid: currentUid,
                              initialUser: u,
                            ),
                          ),
                        );
                    return ListTile(
                      onTap: () => _toggleUser(u.id),
                      leading: SizedBox(
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
                                  photoURL: u.photoURL,
                                  onViewStatus: openStatusViewer,
                                ),
                                child: AvatarRing(
                                  photoURL: u.photoURL,
                                  fallbackEmoji: u.emoji,
                                  hasUnviewed: hasUnviewed,
                                  size: avatarBoxSize,
                                ),
                              )
                            else
                              GestureDetector(
                                onTap: u.photoURL != null
                                    ? () => showFullImage(context, u.photoURL!)
                                    : null,
                                child: Container(
                                  width: avatarBoxSize,
                                  height: avatarBoxSize,
                                  decoration: BoxDecoration(
                                    color: kBg3,
                                    shape: BoxShape.circle,
                                    border: selected
                                        ? Border.all(color: kGold, width: 2)
                                        : null,
                                  ),
                                  alignment: Alignment.center,
                                  child: Text(u.emoji, style: const TextStyle(fontSize: 20)),
                                ),
                              ),
                            Positioned(
                              bottom: 0,
                              right: 0,
                              child: Container(
                                width: 12,
                                height: 12,
                                decoration: BoxDecoration(
                                  color: u.isActuallyOnline ? kGreen : kMuted,
                                  shape: BoxShape.circle,
                                  border: Border.all(color: kBg2, width: 2),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      title: Text(
                        u.name,
                        style: GoogleFonts.playfairDisplay(
                          fontSize: 14,
                          color: kText,
                        ),
                      ),
                      subtitle: Text(
                        '${u.instrument} · ${u.city}',
                        style: const TextStyle(color: kMuted, fontSize: 12),
                      ),
                      trailing: Container(
                        width: 24,
                        height: 24,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: selected ? kGold : Colors.transparent,
                          border: Border.all(
                            color: selected ? kGold : kBorder,
                            width: 2,
                          ),
                        ),
                        child: selected
                            ? const Icon(Icons.check, size: 14, color: Color(0xFF1A0E00))
                            : null,
                      ),
                    );
                  },
                );
              },
              loading: () => const Center(
                child: CircularProgressIndicator(color: kGold),
              ),
              error: (_, _) => const Center(
                child: Text(
                  'Xəta baş verdi',
                  style: TextStyle(color: kMuted),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showEmojiPicker(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: kBg2,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final e in _emojiChoices)
                GestureDetector(
                  onTap: () {
                    setState(() => _emoji = e);
                    Navigator.of(sheetContext).pop();
                  },
                  child: Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: kBg3,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: e == _emoji ? kGold : kBorder,
                        width: e == _emoji ? 2 : 1,
                      ),
                    ),
                    alignment: Alignment.center,
                    child: Text(e, style: const TextStyle(fontSize: 24)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
