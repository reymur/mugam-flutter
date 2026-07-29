// Application ID and Search-Only API Key are both meant to ship in the
// client binary — Algolia's own security model is that the Search-Only key
// can only read, never write/delete, so it's safe to embed (see
// functions/src/index.ts's ALGOLIA_APP_ID comment for the server-side half
// of this split; the Admin API Key never appears on the client at all).
//
// Overridable via --dart-define=ALGOLIA_APP_ID=... /
// --dart-define=ALGOLIA_SEARCH_API_KEY=... if these ever need to differ
// per build flavor; the defaults below are the real, current values so no
// build-time flag is required day to day.
const String algoliaAppId = String.fromEnvironment(
  'ALGOLIA_APP_ID',
  defaultValue: 'XNU1ONO1UZ',
);

const String algoliaSearchApiKey = String.fromEnvironment(
  'ALGOLIA_SEARCH_API_KEY',
  defaultValue: '998b08f2287a6144061677d78983aff0',
);
