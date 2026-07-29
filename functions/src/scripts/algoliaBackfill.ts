// One-off backfill: pushes every existing users/{uid} doc into Algolia's
// "users" index, and sets the index's search/facet settings once at the
// start. Needed because onUserWritten (index.ts) only fires on a Firestore
// write from here on — accounts created before that trigger shipped would
// otherwise never appear in Algolia at all.
//
// NOT wired into firebase deploy: this file is never imported from index.ts,
// so `firebase deploy --only functions` does not pick it up as a Cloud
// Function. It's a standalone Node script, run once, by hand.
//
// --- How to run ---
// 1. Store the Admin API Key the same way as AGORA_APP_CERTIFICATE:
//      firebase functions:secrets:set ALGOLIA_ADMIN_KEY
//    (this script itself reads it from a local env var instead, below —
//    Secret Manager is only consulted by the deployed onUserWritten trigger).
// 2. Authenticate the Admin SDK for a one-off script (not the Cloud
//    Functions runtime, so there's no ambient service account):
//      gcloud auth application-default login
// 3. From functions/:
//      npm run build
//      ALGOLIA_ADMIN_KEY="<the admin key>" node lib/scripts/algoliaBackfill.js
//
// Safe to re-run: saveObjects/setSettings are both idempotent upserts.

import { initializeApp, applicationDefault } from "firebase-admin/app";
import { getFirestore } from "firebase-admin/firestore";
import { algoliasearch } from "algoliasearch";
import { ALGOLIA_APP_ID, ALGOLIA_USERS_INDEX, toAlgoliaUserRecord } from "../algoliaShared";

const PROJECT_ID = "mugam-club"; // matches .firebaserc's "default" project

async function main() {
  const adminKey = process.env.ALGOLIA_ADMIN_KEY;
  if (!adminKey) {
    throw new Error("Set ALGOLIA_ADMIN_KEY in the environment before running this script.");
  }

  initializeApp({ credential: applicationDefault(), projectId: PROJECT_ID });
  const db = getFirestore();
  const client = algoliasearch(ALGOLIA_APP_ID, adminKey);

  console.log(`Setting index config on "${ALGOLIA_USERS_INDEX}"...`);
  await client.setSettings({
    indexName: ALGOLIA_USERS_INDEX,
    indexSettings: {
      searchableAttributes: ["name"],
      // filterOnly(lastSeen): needs to be usable in a numeric `filters`
      // expression (see algoliaShared.ts's toAlgoliaUserRecord comment) but
      // never needs facet value counts the way city/activityInstruments/etc.
      // do — filterOnly skips building that facet index for it.
      attributesForFaceting: [
        "city",
        "activityInstruments",
        "available",
        "online",
        "rating",
        "filterOnly(lastSeen)",
      ],
    },
  });

  // Paged via startAfter rather than one giant .get() — keeps memory bounded
  // regardless of how large the users collection eventually gets, same
  // reasoning as deleteGroupChat's message-batching in index.ts.
  const PAGE_SIZE = 500;
  let lastDoc: FirebaseFirestore.QueryDocumentSnapshot | undefined;
  let totalSynced = 0;

  for (;;) {
    let query = db.collection("users").orderBy("__name__").limit(PAGE_SIZE);
    if (lastDoc) query = query.startAfter(lastDoc);
    const snap = await query.get();
    if (snap.empty) break;

    const objects = snap.docs.map((doc) => toAlgoliaUserRecord(doc.id, doc.data()));
    await client.saveObjects({ indexName: ALGOLIA_USERS_INDEX, objects });

    totalSynced += objects.length;
    lastDoc = snap.docs[snap.docs.length - 1];
    console.log(`Synced ${totalSynced} users so far...`);

    if (snap.docs.length < PAGE_SIZE) break;
  }

  console.log(`Done. Backfilled ${totalSynced} users into Algolia.`);
}

main().catch((e) => {
  console.error("Backfill failed:", e);
  process.exit(1);
});
