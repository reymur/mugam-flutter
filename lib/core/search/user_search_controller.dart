import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../firebase/models.dart';
import 'algolia_filter_utils.dart';
import 'algolia_search_service.dart';

// Shared debounced-search + pagination controller for the "type a name to
// pick a user" pattern used by the group/event participant pickers
// (group_info_screen.dart's _AddParticipantsSheet, create_group_screen.dart,
// agreements_screen.dart's _ParticipantPickerDialog) and, with a full
// SearchFilters-built filters string via updateFilters, chats_screen.dart's
// own city/instrument/rating/online filter button (reuses filter_sheet.dart's
// FilterSheet/SearchFilters — same widget as search_screen.dart). Everything
// else about search_screen.dart's own online-filter live-refresh timer stays
// specific to that screen rather than moving here — nothing else needs it.
//
// excludeUids is fixed at construction — every static-list caller (the
// three pickers above) only ever excludes a fixed set (the signed-in user,
// or a group's existing members) that doesn't change over the picker's
// lifetime. Pass `filters` instead when the caller needs to change filters
// later (SearchFilters.toAlgoliaFilters already folds in its own
// NOT objectID exclusion, so the two constructor params are mutually
// exclusive in practice, not combined).
class UserSearchController extends ChangeNotifier {
  UserSearchController({Iterable<String> excludeUids = const [], String? filters})
      : _filters = filters ?? excludeUidsClauses(excludeUids).join(' AND ');

  final AlgoliaSearchService _service = AlgoliaSearchService();
  String _filters;
  Timer? _debounce;
  int _requestId = 0;
  String _query = '';
  int _page = 0;

  List<User> results = [];
  bool isLoading = true;
  bool isLoadingMore = false;
  bool hasMore = false;
  String? error;

  // Call once (e.g. from initState) to populate the initial, unfiltered
  // (empty query) list — matches the old allUsersProvider-backed screens'
  // behavior of showing everyone before the user types anything.
  Future<void> loadInitial() => _fetch(page: 0);

  // Call on every TextField change — debounces internally, so callers don't
  // need their own Timer (unlike search_screen.dart, which manages its own
  // because it also debounces on filter-sheet changes that don't go through
  // this controller at all).
  void search(String query) {
    _query = query;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () => _fetch(page: 0));
  }

  // Replaces the filters string and re-runs the current query from page 0 —
  // for callers whose filters can change after construction (chats_screen.dart's
  // filter button), unlike the fixed excludeUids the picker callers use.
  void updateFilters(String filters) {
    _filters = filters;
    _fetch(page: 0);
  }

  Future<void> loadMore() async {
    if (isLoading || isLoadingMore || !hasMore) return;
    await _fetch(page: _page + 1, append: true);
  }

  Future<void> _fetch({required int page, bool append = false}) async {
    final requestId = ++_requestId;
    if (append) {
      isLoadingMore = true;
    } else {
      isLoading = true;
      error = null;
    }
    notifyListeners();

    try {
      final result = await _service.searchUsers(
        query: _query,
        filters: _filters,
        page: page,
      );
      if (requestId != _requestId) return;
      results = append ? [...results, ...result.users] : result.users;
      _page = result.page;
      hasMore = result.hasMore;
      isLoading = false;
      isLoadingMore = false;
      notifyListeners();
    } on AlgoliaSearchException catch (e) {
      if (requestId != _requestId) return;
      isLoading = false;
      isLoadingMore = false;
      // A load-more failure leaves the already-visible page intact rather
      // than surfacing `error` (which replaces the whole list view in every
      // consumer below) — same "don't wreck what's already on screen for a
      // background/pagination hiccup" reasoning as search_screen.dart's own
      // _loadMore.
      if (!append) error = e.message;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }
}
