import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart' hide User;
import 'package:flutter/material.dart';

import '../../../core/models/activity_type.dart';
import '../../../core/search/algolia_search_service.dart';
import '../../../core/theme/colors.dart';
import '../../../firebase/models.dart';
import '../../../shared/widgets/avatar_ring.dart';
import '../../user/screens/user_profile_screen.dart';
import 'filter_sheet.dart';

const double _kSearchRowHeight = 46;

// Server-side search via Algolia (AlgoliaSearchService) — name text search
// plus city/instrument/rating/available/online filters are all combined
// into one query (SearchFilters.toAlgoliaFilters, filter_sheet.dart) and
// sent to Algolia in a single request per keystroke (debounced) or filter
// change, instead of the old approach of streaming every user and filtering
// in memory client-side.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> with WidgetsBindingObserver {
  final TextEditingController _nameController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final AlgoliaSearchService _searchService = AlgoliaSearchService();

  SearchFilters _filters = const SearchFilters();
  Timer? _debounce;

  // Unlike the old allUsersProvider stream, an Algolia result is a snapshot
  // at request time — it never updates itself as wall-clock time passes.
  // That matters specifically for the "Onlayn indi" filter: a user who goes
  // stale (see User.isActuallyOnline/onlineGracePeriod, lib/firebase/
  // models.dart) without a new Firestore write would otherwise sit in the
  // results forever until something else triggers a new search. This timer
  // re-issues the same query periodically, only while it could actually
  // change the results (onlyOnline is on) and only while there's a point in
  // spending the request (screen actually visible and app foregrounded) —
  // see _maybeRefreshOnline.
  Timer? _onlineRefreshTimer;
  static const _onlineRefreshInterval = Duration(seconds: 25);
  AppLifecycleState _lifecycleState = AppLifecycleState.resumed;

  List<User> _results = [];
  bool _isLoading = true;
  bool _isLoadingMore = false;
  bool _hasMore = false;
  int _page = 0;
  String? _error;

  // Bumped on every fresh search — lets an in-flight request whose response
  // arrives after a newer one was already started detect it's stale and
  // discard itself, instead of a slow page-0 response clobbering results
  // from a page-0 search the user has since retyped past.
  int _requestId = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _nameController.addListener(_onNameChanged);
    _scrollController.addListener(_onScroll);
    _runSearch();
    _onlineRefreshTimer = Timer.periodic(
      _onlineRefreshInterval,
      (_) => _maybeRefreshOnline(),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleState = state;
  }

  void _onNameChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), _runSearch);
    setState(() {}); // refresh the clear ("x") button's visibility
  }

  void _onScroll() {
    if (!_hasMore || _isLoading || _isLoadingMore) return;
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      _loadMore();
    }
  }

  // Periodic tick for the "Onlayn indi" filter (see _onlineRefreshTimer's own
  // comment) — a no-op unless that filter is actually on, the app is in the
  // foreground, this tab is the visible one (TickerMode is false for the
  // other IndexedStack branches under app_router.dart's StatefulShellRoute),
  // and no other search request is already in flight. Silent: a transient
  // failure here shouldn't flash an error over results that are still
  // perfectly valid, unlike a user-initiated search.
  void _maybeRefreshOnline() {
    if (!mounted) return;
    if (!_filters.onlyOnline) return;
    if (_lifecycleState != AppLifecycleState.resumed) return;
    if (!TickerMode.valuesOf(context).enabled) return;
    if (_isLoading || _isLoadingMore) return;
    _runSearch(silent: true);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _onlineRefreshTimer?.cancel();
    _debounce?.cancel();
    _nameController.removeListener(_onNameChanged);
    _nameController.dispose();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  String get _currentUid => FirebaseAuth.instance.currentUser?.uid ?? '';

  Future<void> _runSearch({bool silent = false}) async {
    final requestId = ++_requestId;
    if (!silent) {
      setState(() {
        _isLoading = true;
        _error = null;
      });
    }

    try {
      final result = await _searchService.searchUsers(
        query: _nameController.text.trim(),
        filters: _filters.toAlgoliaFilters(_currentUid),
        page: 0,
      );
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _results = result.users;
        _page = result.page;
        _hasMore = result.hasMore;
        _isLoading = false;
      });
    } on AlgoliaSearchException catch (e) {
      if (!mounted || requestId != _requestId) return;
      if (silent) return; // see _maybeRefreshOnline's own comment
      setState(() {
        _error = e.message;
        _isLoading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    setState(() => _isLoadingMore = true);
    try {
      final result = await _searchService.searchUsers(
        query: _nameController.text.trim(),
        filters: _filters.toAlgoliaFilters(_currentUid),
        page: _page + 1,
      );
      if (!mounted) return;
      setState(() {
        _results = [..._results, ...result.users];
        _page = result.page;
        _hasMore = result.hasMore;
        _isLoadingMore = false;
      });
    } on AlgoliaSearchException catch (e) {
      if (!mounted) return;
      setState(() => _isLoadingMore = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _openFilters() async {
    final result = await FilterSheet.show(
      context,
      initial: _filters,
      nameController: _nameController,
    );
    if (result != null) {
      setState(() => _filters = result);
      _runSearch();
    }
  }

  @override
  Widget build(BuildContext context) {
    final activeFilterCount = _filters.activeCount;

    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    // Fixed height + expands:true forces the field's actual
                    // render box to exactly _kSearchRowHeight — deterministic,
                    // unlike tuning contentPadding to approximate a target
                    // height from font-dependent line-height math (the
                    // filter button next to it is a literal fixed-size
                    // Container, not derived from text metrics at all).
                    child: SizedBox(
                      height: _kSearchRowHeight,
                      child: TextField(
                        controller: _nameController,
                        style: const TextStyle(color: kText),
                        expands: true,
                        maxLines: null,
                        minLines: null,
                        textAlignVertical: TextAlignVertical.center,
                        decoration: InputDecoration(
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                          hintText: 'İstifadəçi axtar...',
                          hintStyle: const TextStyle(color: kMuted),
                          prefixIcon: const Icon(Icons.search, color: kMuted),
                          suffixIcon: _nameController.text.isEmpty
                              ? null
                              : IconButton(
                                  icon: const Icon(Icons.close_rounded, color: kMuted),
                                  onPressed: _nameController.clear,
                                ),
                          filled: true,
                          fillColor: kCard,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: const BorderSide(color: kBorder),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: const BorderSide(color: kBorder),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: const BorderSide(color: kGold, width: 1.5),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  InkWell(
                    onTap: _openFilters,
                    borderRadius: BorderRadius.circular(14),
                    child: Container(
                      width: _kSearchRowHeight,
                      height: _kSearchRowHeight,
                      decoration: BoxDecoration(
                        color: activeFilterCount > 0 ? kGold : kCard,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: activeFilterCount > 0 ? kGold : kBorder,
                        ),
                      ),
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Center(
                            child: Icon(
                              Icons.tune_rounded,
                              color: activeFilterCount > 0 ? kOnGold : kMuted,
                            ),
                          ),
                          if (activeFilterCount > 0)
                            Positioned(
                              right: -4,
                              top: -4,
                              child: Container(
                                padding: const EdgeInsets.all(3),
                                constraints: const BoxConstraints(
                                  minWidth: 16,
                                  minHeight: 16,
                                ),
                                decoration: const BoxDecoration(
                                  color: kRed,
                                  shape: BoxShape.circle,
                                ),
                                child: Text(
                                  '$activeFilterCount',
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    color: kOnRed,
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(child: _buildResults()),
          ],
        ),
      ),
    );
  }

  Widget _buildResults() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator(color: kGold));
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Yüklənmə xətası', style: TextStyle(color: kMuted)),
            const SizedBox(height: 8),
            TextButton(onPressed: _runSearch, child: const Text('Yenidən cəhd et')),
          ],
        ),
      );
    }
    if (_results.isEmpty) {
      return const Center(
        child: Text(
          'Nəticə tapılmadı',
          style: TextStyle(color: kMuted, fontSize: 14),
        ),
      );
    }
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: _results.length + (_isLoadingMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= _results.length) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(child: CircularProgressIndicator(color: kGold)),
          );
        }
        return _SearchResultTile(user: _results[index]);
      },
    );
  }
}

class _SearchResultTile extends StatelessWidget {
  final User user;

  const _SearchResultTile({required this.user});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => UserProfileScreen(user: user)),
      ),
      leading: AvatarRing(
        photoURL: user.photoURL,
        fallbackEmoji: user.emoji,
        hasUnviewed: false,
        size: 48,
      ),
      title: Text(
        user.name,
        style: const TextStyle(color: kText, fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        [
          formatActivityForCard(user.activityType, user.instrument),
          user.city,
        ].where((s) => s.isNotEmpty).join(' • '),
        style: const TextStyle(color: kMuted, fontSize: 12.5),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.star_rounded, color: kGold, size: 16),
          const SizedBox(width: 2),
          Text(
            user.rating.toStringAsFixed(1),
            style: const TextStyle(color: kMuted, fontSize: 12.5),
          ),
        ],
      ),
    );
  }
}
