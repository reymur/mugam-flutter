# Presence / Online-Status System

This document describes how the app tracks and displays whether a user is
online (`User.online`) and when they were last seen (`User.lastSeen`).

## Current state

- `User.online` (`bool`) and `User.lastSeen` (`Timestamp`/`DateTime?`) live on
  the `User` model (`lib/firebase/models.dart`) and are stored on each user's
  Firestore document (`users/{uid}`).
- Both fields are written by `PresenceService`, which runs a periodic
  Firestore heartbeat (~60s interval) while the app is in the foreground.
  It uses `WidgetsBindingObserver` to detect foreground/background
  transitions: the heartbeat resumes (and immediately rewrites
  `online: true`) when the app returns to the foreground, and is paused
  (no more writes, `online` goes stale) when the app is backgrounded.
  `online: false` is only written on explicit sign-out — backgrounding
  alone deliberately does *not* flip it, to avoid flickering the presence
  dot offline for brief app-switches. See "Staleness window" below.
- The raw `online` boolean is **not** trusted directly by UI. Because
  backgrounding pauses the heartbeat rather than clearing `online` (see
  above), `online` alone can be stuck `true` for a long-backgrounded user
  with no further correction until they return or sign out. `User` exposes
  a computed getter, `isActuallyOnline`, that cross-checks `online` against
  `lastSeen` freshness:

  ```dart
  bool get isActuallyOnline {
    if (!online) return false;
    final seen = lastSeen;
    if (seen == null) return false;
    return DateTime.now().difference(seen.toDate()) < const Duration(minutes: 2);
  }
  ```

  Effective online status is therefore `online && lastSeen is fresher than
  ~2 minutes` (double the 60s heartbeat interval, so one missed/delayed beat
  doesn't falsely flip someone offline). This means backgrounding naturally
  "goes offline" for UI purposes within ~2 minutes without needing any
  additional write — the staleness of `lastSeen` does the correction that an
  immediate `online: false` write would otherwise have had to do.
- Several screens read presence via `isActuallyOnline` (not raw `online`) to
  render presence UI: chat header, about/contact screen, user profile
  screen, and the home screen's musician list. Two of these (chat header's
  `otherUser`, about/contact screen) read through `currentUserProvider`, a
  live Firestore stream, so their presence dot updates in real time as
  `lastSeen`/`online` change. The other two (home screen's musician list,
  user profile screen) read a point-in-time `User` snapshot, so
  `isActuallyOnline` is still correctly staleness-corrected at the moment
  it's read, but won't re-evaluate live on its own as time passes while the
  screen stays open.

## This is a TEMPORARY / INTERIM solution

Cloud Firestore has no native disconnect-detection primitive — unlike the
Realtime Database's `onDisconnect()`, Firestore cannot tell the server "mark
this user offline the moment their connection drops." Presence has to be
approximated instead by having the client periodically write `online: true`
and a `lastSeen` timestamp while it's active, and writing `online: false`
explicitly on sign-out.

This has real, inherent limitations:

- **Staleness window**: `online` is only ever refreshed while the app is
  foregrounded. The moment the app is backgrounded, the heartbeat pauses and
  the *stored* `online` field stops updating — it stays `true` in Firestore
  for as long as the user leaves the app backgrounded, not just for one
  heartbeat interval, since backgrounding deliberately doesn't write `false`
  (to avoid flicker on brief app-switches). The stored field only clears on
  the next explicit sign-out, or gets refreshed again the moment the app is
  foregrounded. A killed/crashed app or lost network mid-session leaves it
  stale the same way. UI never sees this staleness directly, though —
  `User.isActuallyOnline` (see "Current state" above) cross-checks the
  stored `online` against `lastSeen`'s age, so the *displayed* status still
  self-corrects to offline within ~2 minutes even though the raw stored
  field does not.
- **Constant writes**: every foregrounded client writes to Firestore every
  ~60s just to say "I'm still here," which is write-volume/cost overhead a
  real persistent-connection system wouldn't need.
- **No true real-time accuracy**: presence is only ever as fresh as the last
  heartbeat, not the instant a connection actually drops.

This tradeoff is accepted for now because it's cheap to build on top of the
existing Firestore-only architecture and "good enough" for a presence dot in
the UI. It is not the long-term design.

## Planned future replacement

The confirmed future direction is a **self-hosted WebSocket Gateway
server**, backed by **Redis** (for multi-instance sync and room state) and
an **SFU media server** for group calls. This infrastructure is being built
as **shared infrastructure for several features**, not for presence alone:

- Voice/video calls
- Live location sharing
- Casual live gameplay
- Instant typing indicators

Once that persistent-connection server exists, presence should come "for
free" from the same connection: a client with an open socket to the gateway
*is* online, and disconnection is detected immediately by the socket closing
— no heartbeat, no polling, no staleness window. At that point, the
Firestore heartbeat system described above (`PresenceService`, the `online`
and `lastSeen` fields as currently written) should be retired in favor of
presence derived from the WebSocket Gateway's connection state.

**Status**: this WebSocket Gateway + Redis + SFU initiative is a confirmed
future initiative but is **not yet scheduled or started**. The Firestore
heartbeat system in this document is the active, in-production presence
mechanism until that work begins and lands.
