import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart' hide User;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/theme/colors.dart';
import '../../../firebase/firestore_service.dart';

// Group Info screen — mirrors mugam-v2's GroupInfo.tsx (header photo/name/
// emoji, participant list with role badges + per-row admin actions,
// add-participants, leave-group), restyled with this app's own design
// tokens. Presented as a fullscreenDialog route from chat_screen.dart's app
// bar (tapping a group chat's title), matching mugam-v2's own iOS pageSheet
// modal presentation for the same screen.
//
// Wires up FirestoreService's already-committed group-management methods
// (leaveGroup, addGroupMember, removeGroupMember, makeGroupAdmin,
// dismissAsAdmin, updateGroupInfo, uploadGroupPhoto — Phases B-E). Group
// deletion is intentionally NOT wired here: deleteGroup's Cloud Function
// doesn't exist yet (a later phase), so there's no working action to attach
// a button to.
//
// Reads chatMetaProvider (Phase A's live stream) rather than the one-time
// chatDataProvider, so a rename/role change made here — or by another
// admin, from another device — reflects on this screen immediately.
class GroupInfoScreen extends ConsumerStatefulWidget {
  final String chatId;

  const GroupInfoScreen({super.key, required this.chatId});

  @override
  ConsumerState<GroupInfoScreen> createState() => _GroupInfoScreenState();
}

class _GroupInfoScreenState extends ConsumerState<GroupInfoScreen> {
  bool _leaving = false;

  String get _myUid => FirebaseAuth.instance.currentUser?.uid ?? '';
  String get _myName =>
      FirebaseAuth.instance.currentUser?.displayName ?? 'İstifadəçi';

  void _showError(Object e) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('$e'), backgroundColor: kRed));
  }

  Future<void> _editGroupInfo({
    required String currentName,
    required String currentEmoji,
    required String? currentPhotoURL,
  }) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: kBg2,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) => _EditGroupInfoSheet(
        chatId: widget.chatId,
        currentName: currentName,
        currentEmoji: currentEmoji,
        currentPhotoURL: currentPhotoURL,
      ),
    );
  }

  Future<void> _showAddParticipants(List<String> existingMembers) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: kBg2,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) => _AddParticipantsSheet(
        chatId: widget.chatId,
        existingMembers: existingMembers,
        adminUid: _myUid,
        adminName: _myName,
      ),
    );
  }

  void _showMemberActions({required String uid, required bool isTargetAdmin}) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: kBg2,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!isTargetAdmin)
              ListTile(
                leading: const Icon(Icons.admin_panel_settings, color: kGold),
                title: const Text('Admin et', style: TextStyle(color: kText)),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _makeAdmin(uid);
                },
              ),
            if (isTargetAdmin)
              ListTile(
                leading: const Icon(Icons.remove_moderator, color: kGold),
                title: const Text(
                  'Admin statusunu ləğv et',
                  style: TextStyle(color: kText),
                ),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _confirmAndDemote(uid);
                },
              ),
            ListTile(
              leading: const Icon(Icons.person_remove, color: kRed),
              title: const Text(
                'Qrupdan çıxar',
                style: TextStyle(color: kRed),
              ),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _confirmAndRemove(uid);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<String> _resolveName(String uid) async {
    final user = await ref.read(userByIdProvider(uid).future);
    return user?.name ?? 'İstifadəçi';
  }

  Future<void> _makeAdmin(String uid) async {
    try {
      final name = await _resolveName(uid);
      await ref
          .read(firestoreServiceProvider)
          .makeGroupAdmin(
            chatId: widget.chatId,
            uid: uid,
            userName: name,
            adminUid: _myUid,
            adminName: _myName,
          );
    } catch (e) {
      _showError(e);
    }
  }

  Future<void> _confirmAndDemote(String uid) async {
    final name = await _resolveName(uid);
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: kBg2,
        title: const Text(
          'Admin statusunu ləğv et',
          style: TextStyle(color: kText),
        ),
        content: Text(
          '$name admin statusundan çıxarılsın?',
          style: const TextStyle(color: kMuted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Ləğv et', style: TextStyle(color: kMuted)),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Çıxar', style: TextStyle(color: kRed)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ref
          .read(firestoreServiceProvider)
          .dismissAsAdmin(
            chatId: widget.chatId,
            uid: uid,
            userName: name,
            adminUid: _myUid,
            adminName: _myName,
          );
    } catch (e) {
      // Covers both the last-admin guarantee and the (unreachable via this
      // UI, since creator rows never show this menu) creator-immunity
      // check — either way, the user needs to see why the action failed
      // rather than have it silently no-op.
      _showError(e);
    }
  }

  Future<void> _confirmAndRemove(String uid) async {
    final name = await _resolveName(uid);
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: kBg2,
        title: const Text(
          'İştirakçını çıxar',
          style: TextStyle(color: kText),
        ),
        content: Text(
          '$name qrupdan çıxarılsın?',
          style: const TextStyle(color: kMuted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Ləğv et', style: TextStyle(color: kMuted)),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Çıxar', style: TextStyle(color: kRed)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ref
          .read(firestoreServiceProvider)
          .removeGroupMember(
            chatId: widget.chatId,
            uid: uid,
            userName: name,
            removedByName: _myName,
            adminUid: _myUid,
          );
    } catch (e) {
      _showError(e);
    }
  }

  Future<void> _confirmAndLeave() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: kBg2,
        title: const Text('Qrupdan çıx', style: TextStyle(color: kText)),
        content: const Text(
          'Qrupdan çıxmaq istəyirsiniz?',
          style: TextStyle(color: kMuted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Ləğv et', style: TextStyle(color: kMuted)),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Çıx', style: TextStyle(color: kRed)),
          ),
        ],
      ),
    );
    if (confirmed != true || _leaving || !mounted) return;

    setState(() => _leaving = true);
    // Captured immediately after the mounted check above, before
    // leaveGroup's own await — this screen (and the ChatScreen beneath it)
    // is about to be popped, so `context` itself must not be touched again
    // after this point.
    final navigator = Navigator.of(context);
    try {
      await ref
          .read(firestoreServiceProvider)
          .leaveGroup(chatId: widget.chatId, uid: _myUid, userName: _myName);
      // No longer a member of this chat — leave both this screen and the
      // chat screen itself, same as WhatsApp's own post-leave navigation.
      navigator.pop();
      navigator.pop();
    } catch (e) {
      if (mounted) setState(() => _leaving = false);
      _showError(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final metaAsync = ref.watch(chatMetaProvider(widget.chatId));

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
          'Qrup haqqında',
          style: GoogleFonts.playfairDisplay(fontSize: 18, color: kText),
        ),
      ),
      body: metaAsync.when(
        loading: () =>
            const Center(child: CircularProgressIndicator(color: kGold)),
        error: (_, _) => const Center(
          child: Text('Xəta baş verdi', style: TextStyle(color: kMuted)),
        ),
        data: (meta) {
          final name = meta['name'] as String? ?? '';
          final emoji = meta['emoji'] as String? ?? '👥';
          final photoURL = meta['photoURL'] as String?;
          final admins = List<String>.from(
            meta['admins'] as List? ?? const [],
          );
          final createdBy = meta['createdBy'] as String? ?? '';
          final members = List<String>.from(
            meta['members'] as List? ?? const [],
          );
          final isAdminOrCreator =
              admins.contains(_myUid) || createdBy == _myUid;

          return ListView(
            children: [
              const SizedBox(height: 24),
              GestureDetector(
                onTap: isAdminOrCreator
                    ? () => _editGroupInfo(
                        currentName: name,
                        currentEmoji: emoji,
                        currentPhotoURL: photoURL,
                      )
                    : null,
                child: Column(
                  children: [
                    Container(
                      width: 120,
                      height: 120,
                      decoration: BoxDecoration(
                        color: kBg3,
                        shape: BoxShape.circle,
                        border: Border.all(color: kBorder, width: 1),
                        image: photoURL != null
                            ? DecorationImage(
                                image: NetworkImage(photoURL),
                                fit: BoxFit.cover,
                              )
                            : null,
                      ),
                      child: photoURL == null
                          ? Center(
                              child: Text(
                                emoji,
                                style: const TextStyle(fontSize: 48),
                              ),
                            )
                          : null,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      name,
                      textAlign: TextAlign.center,
                      style: GoogleFonts.playfairDisplay(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        color: kText,
                      ),
                    ),
                    if (isAdminOrCreator) ...[
                      const SizedBox(height: 4),
                      const Text(
                        'Dəyişmək üçün toxunun',
                        style: TextStyle(color: kMuted, fontSize: 12),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 24),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'İştirakçılar (${members.length})',
                    style: const TextStyle(
                      color: kMuted,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              if (isAdminOrCreator)
                ListTile(
                  leading: const CircleAvatar(
                    backgroundColor: kBg3,
                    child: Icon(Icons.person_add, color: kGold),
                  ),
                  title: const Text(
                    'İştirakçı əlavə et',
                    style: TextStyle(color: kGold, fontWeight: FontWeight.w600),
                  ),
                  onTap: () => _showAddParticipants(members),
                ),
              for (final uid in members)
                _ParticipantTile(
                  uid: uid,
                  isCreator: uid == createdBy,
                  isAdmin: admins.contains(uid),
                  isMe: uid == _myUid,
                  // The creator is fully immune (per removeGroupMember/
                  // dismissAsAdmin's own server-side checks) — this is the
                  // UI-level mirror of that protection, not a replacement
                  // for it, so the action menu never even appears for
                  // their row.
                  showActions:
                      isAdminOrCreator && uid != _myUid && uid != createdBy,
                  onActionsTap: () => _showMemberActions(
                    uid: uid,
                    isTargetAdmin: admins.contains(uid),
                  ),
                ),
              const SizedBox(height: 24),
              ListTile(
                leading: _leaving
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: kRed,
                        ),
                      )
                    : const Icon(Icons.logout, color: kRed),
                title: const Text('Qrupdan çıx', style: TextStyle(color: kRed)),
                onTap: _leaving ? null : _confirmAndLeave,
              ),
              const SizedBox(height: 32),
            ],
          );
        },
      ),
    );
  }
}

class _ParticipantTile extends ConsumerWidget {
  final String uid;
  final bool isCreator;
  final bool isAdmin;
  final bool isMe;
  final bool showActions;
  final VoidCallback onActionsTap;

  const _ParticipantTile({
    required this.uid,
    required this.isCreator,
    required this.isAdmin,
    required this.isMe,
    required this.showActions,
    required this.onActionsTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(userByIdProvider(uid)).value;
    final name = isMe ? 'Siz' : (user?.name ?? 'İstifadəçi');
    final emoji = user?.emoji ?? '👤';

    return ListTile(
      leading: Container(
        width: 44,
        height: 44,
        decoration: const BoxDecoration(color: kBg3, shape: BoxShape.circle),
        alignment: Alignment.center,
        child: Text(emoji, style: const TextStyle(fontSize: 18)),
      ),
      title: Text(
        name,
        style: GoogleFonts.playfairDisplay(fontSize: 14, color: kText),
      ),
      // Creator label takes precedence over admin — a creator is never
      // shown as just "Admin" even though createGroupChat also seeds them
      // into the admins array.
      subtitle: isCreator
          ? const Text('Yaradıcı', style: TextStyle(color: kGold, fontSize: 11))
          : (isAdmin
                ? const Text('Admin', style: TextStyle(color: kGold, fontSize: 11))
                : null),
      trailing: showActions
          ? IconButton(
              icon: const Icon(Icons.more_vert, color: kMuted),
              onPressed: onActionsTap,
            )
          : null,
    );
  }
}

// Edit flow for the header (photo/name/emoji) — only reachable when the
// current user is admin or creator (see GroupInfoScreen's own gate on the
// header GestureDetector). Mirrors edit_profile_screen.dart's
// camera/gallery picker sheet and create_group_screen.dart's emoji-choice
// sheet, condensed into one bottom sheet rather than a full screen since
// Group Info itself is already the "screen" here.
class _EditGroupInfoSheet extends ConsumerStatefulWidget {
  final String chatId;
  final String currentName;
  final String currentEmoji;
  final String? currentPhotoURL;

  const _EditGroupInfoSheet({
    required this.chatId,
    required this.currentName,
    required this.currentEmoji,
    required this.currentPhotoURL,
  });

  @override
  ConsumerState<_EditGroupInfoSheet> createState() =>
      _EditGroupInfoSheetState();
}

class _EditGroupInfoSheetState extends ConsumerState<_EditGroupInfoSheet> {
  late final TextEditingController _nameController;
  late String _emoji;
  String? _localPhotoPath;
  bool _saving = false;
  final _picker = ImagePicker();

  static const List<String> _emojiChoices = [
    '👥', '🎵', '🎸', '🥁', '🎹', '🎺', '🎤', '🎧',
  ];

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.currentName);
    _emoji = widget.currentEmoji;
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _pickPhoto() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      backgroundColor: kBg3,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera, color: kGold),
              title: const Text('Kamera', style: TextStyle(color: kText)),
              onTap: () => Navigator.pop(context, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library, color: kGold),
              title: const Text('Qalereya', style: TextStyle(color: kText)),
              onTap: () => Navigator.pop(context, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null) return;
    final picked = await _picker.pickImage(
      source: source,
      imageQuality: 80,
      maxWidth: 800,
    );
    if (picked == null) return;
    setState(() => _localPhotoPath = picked.path);
  }

  void _showEmojiPicker() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: kBg3,
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
                      color: kBg,
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

  Future<void> _save() async {
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
    setState(() => _saving = true);
    try {
      final service = ref.read(firestoreServiceProvider);
      String? photoURL;
      if (_localPhotoPath != null) {
        photoURL = await service.uploadGroupPhoto(
          chatId: widget.chatId,
          uri: _localPhotoPath!,
        );
      }
      await service.updateGroupInfo(
        chatId: widget.chatId,
        name: name,
        emoji: _emoji,
        photoURL: photoURL,
      );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Yadda saxlanmadı: $e'),
            backgroundColor: kRed,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    ImageProvider? photo;
    if (_localPhotoPath != null) {
      photo = FileImage(File(_localPhotoPath!));
    } else if (widget.currentPhotoURL != null) {
      photo = NetworkImage(widget.currentPhotoURL!);
    }

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: 16 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                GestureDetector(
                  onTap: _pickPhoto,
                  child: Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      color: kBg,
                      shape: BoxShape.circle,
                      border: Border.all(color: kBorder),
                      image: photo != null
                          ? DecorationImage(image: photo, fit: BoxFit.cover)
                          : null,
                    ),
                    child: photo == null
                        ? const Icon(Icons.camera_alt, color: kMuted)
                        : null,
                  ),
                ),
                const SizedBox(width: 12),
                GestureDetector(
                  onTap: _showEmojiPicker,
                  child: Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      color: kBg,
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
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _saving ? null : _save,
                style: ElevatedButton.styleFrom(backgroundColor: kGold),
                child: _saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Color(0xFF1A0E00),
                        ),
                      )
                    : const Text(
                        'Yadda saxla',
                        style: TextStyle(
                          color: Color(0xFF1A0E00),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Add-participants flow — reuses create_group_screen.dart's own
// search+checklist structure (same visual idiom, same filtering approach)
// rather than building a new picker from scratch, scoped down to a bottom
// sheet since this is a secondary action on an already-existing group
// rather than the primary create-group flow.
class _AddParticipantsSheet extends ConsumerStatefulWidget {
  final String chatId;
  final List<String> existingMembers;
  final String adminUid;
  final String adminName;

  const _AddParticipantsSheet({
    required this.chatId,
    required this.existingMembers,
    required this.adminUid,
    required this.adminName,
  });

  @override
  ConsumerState<_AddParticipantsSheet> createState() =>
      _AddParticipantsSheetState();
}

class _AddParticipantsSheetState extends ConsumerState<_AddParticipantsSheet> {
  final TextEditingController _searchController = TextEditingController();
  String _search = '';
  final Set<String> _selectedUids = {};
  bool _adding = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
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

  Future<void> _add() async {
    if (_selectedUids.isEmpty) return;
    setState(() => _adding = true);
    final service = ref.read(firestoreServiceProvider);
    try {
      for (final uid in _selectedUids) {
        final user = await ref.read(userByIdProvider(uid).future);
        await service.addGroupMember(
          chatId: widget.chatId,
          uid: uid,
          userName: user?.name ?? 'İstifadəçi',
          addedByName: widget.adminName,
          adminUid: widget.adminUid,
        );
      }
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() => _adding = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Əlavə edilmədi: $e'), backgroundColor: kRed),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final usersAsync = ref.watch(allUsersProvider);

    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.75,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'İştirakçı əlavə et',
                      style: GoogleFonts.playfairDisplay(
                        fontSize: 16,
                        color: kText,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: (_selectedUids.isEmpty || _adding)
                        ? null
                        : _add,
                    child: _adding
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: kGold,
                            ),
                          )
                        : Text(
                            'Əlavə et',
                            style: TextStyle(
                              color: kGold.withAlpha(
                                _selectedUids.isEmpty ? 100 : 255,
                              ),
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
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
            const SizedBox(height: 8),
            Expanded(
              child: usersAsync.when(
                data: (users) {
                  final filtered = users
                      .where((u) => !widget.existingMembers.contains(u.id))
                      .where((u) {
                        if (_search.trim().isEmpty) return true;
                        final q = _search.toLowerCase();
                        return u.name.toLowerCase().contains(q) ||
                            u.instrument.toLowerCase().contains(q) ||
                            u.city.toLowerCase().contains(q);
                      })
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
                    itemBuilder: (context, index) {
                      final u = filtered[index];
                      final selected = _selectedUids.contains(u.id);
                      return ListTile(
                        onTap: () => _toggleUser(u.id),
                        leading: Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: kBg3,
                            shape: BoxShape.circle,
                            border: selected
                                ? Border.all(color: kGold, width: 2)
                                : null,
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            u.emoji,
                            style: const TextStyle(fontSize: 18),
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
                          width: 22,
                          height: 22,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: selected ? kGold : Colors.transparent,
                            border: Border.all(
                              color: selected ? kGold : kBorder,
                              width: 2,
                            ),
                          ),
                          child: selected
                              ? const Icon(
                                  Icons.check,
                                  size: 14,
                                  color: Color(0xFF1A0E00),
                                )
                              : null,
                        ),
                      );
                    },
                  );
                },
                loading: () =>
                    const Center(child: CircularProgressIndicator(color: kGold)),
                error: (_, _) => const Center(
                  child: Text('Xəta baş verdi', style: TextStyle(color: kMuted)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
