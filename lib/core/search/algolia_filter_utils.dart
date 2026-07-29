// Shared by every Algolia `filters` expression builder in this app
// (SearchFilters.toAlgoliaFilters, filter_sheet.dart; UserSearchController,
// user_search_controller.dart) — kept in one place so the escaping rule
// can't drift between them.

// Algolia's filter grammar takes double-quoted string values — escape any
// literal `"` or `\` in a value (name, city, instrument label, uid) so it
// can't break out of its quotes and corrupt the rest of the expression.
String escapeAlgoliaFilterValue(String value) =>
    value.replaceAll('\\', '\\\\').replaceAll('"', '\\"');

// One `NOT objectID:"..."` clause per uid to exclude — callers AND-join
// these with whatever other clauses they need (see toAlgoliaFilters and
// UserSearchController's own `_filters`).
List<String> excludeUidsClauses(Iterable<String> uids) => uids
    .map((uid) => 'NOT objectID:"${escapeAlgoliaFilterValue(uid)}"')
    .toList();
