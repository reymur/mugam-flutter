// Shared between index.ts's onUserWritten trigger and
// scripts/algoliaBackfill.ts — kept in its own module (no firebase-admin
// initializeApp() call, no onCall/trigger exports) so the backfill script
// can import toAlgoliaUserRecord without pulling in index.ts's top-level
// initializeApp() (which would throw "default app already exists" once the
// script calls its own) or registering every other Cloud Function as a
// side effect of the import.

// Not a secret — meant to ship in the Flutter client too (see
// lib/core/config/algolia_config.dart) — it's just how a client identifies
// which Algolia app to query. Only the Admin API Key (see index.ts's
// algoliaAdminKey / this script's ALGOLIA_ADMIN_KEY env var) is sensitive.
export const ALGOLIA_APP_ID = "XNU1ONO1UZ";
export const ALGOLIA_USERS_INDEX = "users";

// Deliberately only the fields actually needed to render a search result or
// to filter/facet by (see FilterSheet) — bio/gigs/verified/etc. stay
// Firestore-only, fetched via the existing currentUserProvider/
// userByIdProvider once a result is tapped (see User.fromAlgoliaHit's own
// comment, lib/firebase/models.dart). `instrument` is included even though
// it's not a facet — it's the flat display string search_screen.dart's
// result tiles need for formatActivityForCard, and there's no nested
// activityType map in the index to derive it from.
//
// `lastSeen` (epoch millis, not the Firestore Timestamp itself — Algolia
// numeric filters need a plain number) is here for the same reason
// User.isActuallyOnline (lib/firebase/models.dart) cross-checks it: raw
// `online` alone goes stale (PresenceService's heartbeat pauses rather than
// clears it on backgrounding), so SearchFilters.toAlgoliaFilters
// (filter_sheet.dart) filters on `online:true AND lastSeen > <now minus
// User.onlineGracePeriod>` instead of `online:true` alone — a static index
// snapshot can't call a getter, so the same 2-minute check has to be
// re-expressed as a query-time numeric filter using this field.
//
// `emoji`/`mostRecentStatusExpiresAt`/`mostRecentStatusCreatedAt` were added
// when the same Algolia-backed search got reused for the group/event
// participant pickers (group_info_screen.dart's _AddParticipantsSheet,
// create_group_screen.dart, agreements_screen.dart's
// _ParticipantPickerDialog) — those rows render the same status ring
// (User.hasActiveStatus/hasUnviewedStatusFrom) and avatar-fallback emoji the
// Firestore-backed list they replaced did, so without these fields here
// every row would silently regress to always-muted-ring/generic-emoji.
export function toAlgoliaUserRecord(uid: string, data: FirebaseFirestore.DocumentData) {
  const lastSeen = data.lastSeen as FirebaseFirestore.Timestamp | undefined;
  const mostRecentStatusExpiresAt = data.mostRecentStatusExpiresAt as
    | FirebaseFirestore.Timestamp
    | undefined;
  const mostRecentStatusCreatedAt = data.mostRecentStatusCreatedAt as
    | FirebaseFirestore.Timestamp
    | undefined;
  return {
    objectID: uid,
    id: uid,
    // Same name/displayName fallback as User.fromFirestore (lib/firebase/
    // models.dart) and onNewMessage's senderName in index.ts.
    name: (data.name ?? data.displayName ?? "") as string,
    city: (data.city ?? "") as string,
    activityInstruments: (data.activityInstruments ?? []) as string[],
    instrument: (data.instrument ?? "") as string,
    rating: ((data.rating ?? 0) as number),
    available: (data.available ?? false) as boolean,
    online: (data.online ?? false) as boolean,
    lastSeen: lastSeen ? lastSeen.toMillis() : null,
    photoURL: (data.photoURL ?? null) as string | null,
    emoji: (data.emoji ?? "🎵") as string,
    mostRecentStatusExpiresAt: mostRecentStatusExpiresAt ? mostRecentStatusExpiresAt.toMillis() : null,
    mostRecentStatusCreatedAt: mostRecentStatusCreatedAt ? mostRecentStatusCreatedAt.toMillis() : null,
  };
}
