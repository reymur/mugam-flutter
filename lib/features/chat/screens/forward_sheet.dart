import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/colors.dart';
import '../../../firebase/firestore_service.dart';
import '../../../firebase/models.dart';
import '../../chats/screens/create_group_screen.dart';
import 'chat_screen.dart';

// WhatsApp-style forward sheet (Phase C2) — replaces chat_screen.dart's
// old single-tap-and-close bottom sheet. Search + "Often contacted"/
// "Recent chats" sections (unfiltered browse view only — search collapses
// to one flat filtered list, sections don't make sense once you're
// searching), multi-select up to 10 targets, an optional caption applied
// to every forwarded copy in every selected chat, and a "New group" entry
// that abandons this forward (matches WhatsApp's own behavior — group
// creation is a separate flow, not merged into this one).
//
// Owns the actual send loop itself (via FirestoreService.forwardMessage,
// moved there from chat_screen.dart's own private _forwardMessage so this
// file can call it without reaching into ChatScreen's private state) —
// onDone is the one thing that has to call back into ChatScreen, since
// exiting message-selection mode is that screen's own state, not this
// sheet's.
class ForwardSheet extends ConsumerStatefulWidget {
  final List<Message> messages;
  final String sourceChatId;
  final String currentUid;
  final VoidCallback onDone;

  const ForwardSheet({
    super.key,
    required this.messages,
    required this.sourceChatId,
    required this.currentUid,
    required this.onDone,
  });

  @override
  ConsumerState<ForwardSheet> createState() => _ForwardSheetState();
}

class _ForwardSheetState extends ConsumerState<ForwardSheet> {
  static const int _maxSelected = 10;

  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _captionController = TextEditingController();
  String _search = '';
  final Set<String> _selectedChatIds = {};
  bool _sending = false;

  @override
  void dispose() {
    _searchController.dispose();
    _captionController.dispose();
    super.dispose();
  }

  void _toggleChat(String chatId) {
    if (!_selectedChatIds.contains(chatId) &&
        _selectedChatIds.length >= _maxSelected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Maksimum 10 söhbət seçə bilərsiniz'),
        ),
      );
      return;
    }
    setState(() {
      if (_selectedChatIds.contains(chatId)) {
        _selectedChatIds.remove(chatId);
      } else {
        _selectedChatIds.add(chatId);
      }
    });
  }

  // Shared by _send() and _openNewGroup() — forwards every
  // widget.messages entry into every target chat, per-message-per-chat
  // try/catch (one message failing doesn't abort the rest of that
  // chat's batch), using the caption field's current text as an
  // override. Returns whether any individual forward failed, for the
  // caller's own success/partial-failure SnackBar.
  Future<bool> _forwardTo(Iterable<String> chatIds) async {
    final service = ref.read(firestoreServiceProvider);
    final captionText = _captionController.text.trim();
    final captionOverride = captionText.isEmpty ? null : captionText;
    var anyFailed = false;
    for (final chatId in chatIds) {
      for (final msg in widget.messages) {
        try {
          await service.forwardMessage(
            message: msg,
            targetChatId: chatId,
            senderId: widget.currentUid,
            captionOverride: captionOverride,
          );
        } catch (_) {
          anyFailed = true;
        }
      }
    }
    return anyFailed;
  }

  // Matches real WhatsApp's own forward-sheet behavior: "New group"
  // pushes CreateGroupScreen (popWithChatId: true, so it hands the new
  // chatId back via a plain pop instead of navigating itself into the
  // new group's ChatScreen — see CreateGroupScreen's own doc comment)
  // rather than abandoning the forward. Cancelling there pops with null
  // — the forward sheet is still showing underneath (it was never
  // popped), so there's nothing further to do; the in-progress
  // selection/caption are untouched, exactly as if this had never been
  // tapped. On an actual chatId, forwards the message(s) into it and
  // lands the user directly in that new group's chat — same "land in
  // the new chat" behavior normal group creation already has — rather
  // than back in the chat they were forwarding from, which is why this
  // pops the sheet AND pushReplacements the original ChatScreen, not
  // just one or the other.
  //
  // Navigator captured before the sheet's own pop, same reasoning as
  // messenger elsewhere in this file: this widget's own context is
  // about to be unmounted by that pop, but the NavigatorState itself
  // (owned by an ancestor still very much alive) stays valid to keep
  // driving afterward.
  Future<void> _openNewGroup() async {
    final navigator = Navigator.of(context);
    final chatId = await navigator.push<String>(
      MaterialPageRoute(
        builder: (_) => const CreateGroupScreen(popWithChatId: true),
      ),
    );
    if (!mounted || chatId == null) return;
    setState(() => _sending = true);
    // Navigate regardless of partial per-message failure, same as a
    // normal send — landing in the new group with whatever did arrive
    // is itself the confirmation, no separate SnackBar needed here.
    await _forwardTo([chatId]);
    if (!mounted) return;
    navigator.pop();
    widget.onDone();
    navigator.pushReplacement(
      MaterialPageRoute(builder: (_) => ChatScreen(chatId: chatId)),
    );
  }

  Future<void> _send() async {
    if (_selectedChatIds.isEmpty || _sending) return;
    // Captured before any await — ScaffoldMessenger.of(context) must not
    // be looked up again after this sheet's own context is popped below,
    // but the State object itself (belonging to ChatScreen's ancestor
    // Scaffold, still mounted underneath) stays valid to use afterward.
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _sending = true);
    final anyFailed = await _forwardTo(_selectedChatIds);
    if (!mounted) return;
    Navigator.of(context).pop();
    widget.onDone();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          anyFailed ? 'Bəzi söhbətlərə göndərilmədi' : 'Yönləndirildi',
        ),
        backgroundColor: anyFailed ? kRed : null,
      ),
    );
  }

  // Top 5 by messageCount desc (ties broken by lastMessageTime desc),
  // messageCount > 0 only — a brand-new 0-message chat shouldn't fill a
  // top-5 slot just because there's nothing else to rank. "Recent" is
  // everything else, in chatsProvider's own existing lastMessageTime-desc
  // order (targets is already sorted that way — see watchChats), minus
  // whatever "Often" already claimed, so no chat appears in both.
  (List<Chat>, List<Chat>) _sections(List<Chat> targets) {
    final often = targets.where((c) => c.messageCount > 0).toList()
      ..sort((a, b) {
        final byCount = b.messageCount.compareTo(a.messageCount);
        if (byCount != 0) return byCount;
        if (a.lastMessageTime == null && b.lastMessageTime == null) {
          return 0;
        }
        if (a.lastMessageTime == null) return 1;
        if (b.lastMessageTime == null) return -1;
        return b.lastMessageTime!.compareTo(a.lastMessageTime!);
      });
    final oftenTop = often.take(5).toList();
    final oftenIds = oftenTop.map((c) => c.id).toSet();
    final recent = targets.where((c) => !oftenIds.contains(c.id)).toList();
    return (oftenTop, recent);
  }

  Widget _sectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title,
        style: const TextStyle(
          color: kMuted,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 1,
        ),
      ),
    );
  }

  Widget _chatRow(Chat chat) {
    final selected = _selectedChatIds.contains(chat.id);
    return ListTile(
      onTap: () => _toggleChat(chat.id),
      leading: Container(
        width: 46,
        height: 46,
        decoration: BoxDecoration(
          color: kBg3,
          shape: BoxShape.circle,
          border: selected ? Border.all(color: kGold, width: 2) : null,
        ),
        alignment: Alignment.center,
        child: Text(chat.emoji, style: const TextStyle(fontSize: 20)),
      ),
      title: Text(
        chat.name,
        style: const TextStyle(color: kText),
      ),
      trailing: Container(
        width: 24,
        height: 24,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: selected ? kGold : Colors.transparent,
          border: Border.all(color: selected ? kGold : kBorder, width: 2),
        ),
        child: selected
            ? const Icon(Icons.check, size: 14, color: Color(0xFF1A0E00))
            : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final chatsAsync = ref.watch(chatsProvider(widget.currentUid));
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.85,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 16, 0),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.close, color: kMuted),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                    Expanded(
                      child: Text(
                        _selectedChatIds.isEmpty
                            ? 'Yönləndir'
                            : 'Yönləndir (${_selectedChatIds.length})',
                        style: const TextStyle(
                          color: kText,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    _sending
                        ? const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: kGold,
                            ),
                          )
                        : IconButton(
                            icon: Icon(
                              Icons.send,
                              color: _selectedChatIds.isEmpty
                                  ? kMuted
                                  : kGold,
                            ),
                            onPressed: _selectedChatIds.isEmpty ? null : _send,
                          ),
                  ],
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
              ListTile(
                onTap: _openNewGroup,
                leading: const CircleAvatar(
                  radius: 23,
                  backgroundColor: kBg3,
                  child: Icon(Icons.group_add, color: kGold),
                ),
                title: const Text(
                  'Yeni qrup',
                  style: TextStyle(color: kText, fontWeight: FontWeight.w600),
                ),
              ),
              Expanded(
                child: chatsAsync.when(
                  loading: () => const Center(
                    child: CircularProgressIndicator(color: kGold),
                  ),
                  error: (_, _) => const Center(
                    child: Text('Xəta', style: TextStyle(color: kMuted)),
                  ),
                  data: (chats) {
                    final targets = chats
                        .where((c) => c.id != widget.sourceChatId)
                        .toList();
                    if (targets.isEmpty) {
                      return const Center(
                        child: Text(
                          'Söhbət tapılmadı',
                          style: TextStyle(color: kMuted),
                        ),
                      );
                    }
                    final query = _search.trim().toLowerCase();
                    if (query.isNotEmpty) {
                      final filtered = targets
                          .where((c) => c.name.toLowerCase().contains(query))
                          .toList();
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
                        itemBuilder: (ctx, i) => _chatRow(filtered[i]),
                      );
                    }
                    final (often, recent) = _sections(targets);
                    return ListView(
                      children: [
                        if (often.isNotEmpty) ...[
                          _sectionHeader('Tez-tez yazışılanlar'),
                          for (final chat in often) _chatRow(chat),
                        ],
                        if (recent.isNotEmpty) ...[
                          _sectionHeader('Son söhbətlər'),
                          for (final chat in recent) _chatRow(chat),
                        ],
                      ],
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: TextField(
                  controller: _captionController,
                  style: const TextStyle(color: kText),
                  decoration: InputDecoration(
                    hintText: 'Mesaj əlavə edin...',
                    hintStyle: const TextStyle(color: kMuted),
                    filled: true,
                    fillColor: kBg3,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
