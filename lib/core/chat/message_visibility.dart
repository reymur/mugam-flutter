import '../../firebase/models.dart';

// The single answer to "does this message appear in this user's chat view".
//
// It used to be three answers in three places that could disagree with each
// other: the "Çatı təmizlə" cutoff was applied in ChatMessagesController's
// own _filtered(), the per-user `deletedFor` filter in chat_screen.dart's
// build() (and again, separately, in chat_attachment_viewer_screen.dart),
// and pagination applied neither — it decided "is there more history" from
// the raw page length, before any of them ran. That split is what made B7/B8
// possible at all: a page of 50 real documents that renders as zero visible
// rows looks like progress to the pager and like "nothing happened" to the
// user, and the two never compare notes.
//
// Note what is deliberately NOT here: `deletedForAll`. A message deleted for
// everyone stays visible as a tombstone bubble ("Bu mesaj silindi", see
// _buildMessageBubble) until chat_screen's own 5-minute purge timer hard
// deletes it. It's rendered differently, not hidden — so it must keep
// counting as a visible row for pagination too, or scrolling up through a
// stretch of deleted messages would page right past them.
//
// `uid` may be empty (signed out mid-teardown); that only disables the
// per-user filter rather than hiding everything, matching what the call
// sites did individually before.
bool isMessageVisible(
  Message message, {
  required String uid,
  required DateTime? clearedAt,
}) {
  if (uid.isNotEmpty && message.deletedFor.contains(uid)) return false;
  if (clearedAt == null) return true;
  final sentAt = message.timestamp?.toDate();
  // No timestamp yet = a pending send this device just enqueued. It cannot
  // predate a cutoff that was written before it existed, so it's visible —
  // the same `?? true` the cutoff filter has always used.
  if (sentAt == null) return true;
  return sentAt.isAfter(clearedAt);
}
