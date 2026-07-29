import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../firebase/models.dart';
import 'algolia_filter_utils.dart';
import 'algolia_search_service.dart';

// Shared debounced-search + pagination controller for the "type a name to
// pick a user" pattern used by the group/event participant pickers
// (group_info_screen.dart's _AddParticipantsSheet, create_group_screen.dart,
// agreements_screen.dart's _ParticipantPickerDialog). search_screen.dart has
// its own richer version of this (city/instrument/rating/online filters, a
// live-refresh timer for the online filter) and is deliberately left as its
// own thing rather than routed through this — none of that extra complexity
// applies to a plain "search by name, exclude a few uids" picker, and it
// already works.
//
// excludeUids is fixed at construction — every current caller only ever
// excludes a static set (the signed-in user, or a group's existing members)
// that doesn't change over the picker's lifetime, so there's no need for a
// dynamic filter API here.
class UserSearchController extends ChangeNotifier {
  UserSearchController({Iterable<String> excludeUids = const []})
      : _filters = excludeUidsClauses(excludeUids).join(' AND ');

  final AlgoliaSearchService _service = AlgoliaSearchService();
  final String _filters;
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
