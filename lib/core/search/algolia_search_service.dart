import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../firebase/models.dart';
import '../config/algolia_config.dart';

// Raw REST calls rather than the `algolia` pub package — that package is
// unofficial, last published years ago, and pins http/uuid versions that
// conflict with what this project's pubspec.lock already resolves (see
// SearchFilters/search_screen.dart's own history for the full story). A
// single POST to Algolia's documented query endpoint is all the client
// actually needs, and it's exactly what that package would have done
// internally anyway.
const int _hitsPerPage = 20;

class AlgoliaSearchException implements Exception {
  final String message;
  const AlgoliaSearchException(this.message);

  @override
  String toString() => message;
}

class AlgoliaSearchResult {
  final List<User> users;
  final int page;
  final int nbPages;

  const AlgoliaSearchResult({
    required this.users,
    required this.page,
    required this.nbPages,
  });

  bool get hasMore => page + 1 < nbPages;
}

class AlgoliaSearchService {
  static const String _indexName = 'users';

  // query: raw name search text (empty string matches everyone, same as
  // an unfilled search box). filters: an Algolia `filters` expression, e.g.
  // from SearchFilters.toAlgoliaFilters (filter_sheet.dart) — kept as a
  // plain string parameter here rather than a typed filter object, since
  // building that expression depends on UI-only state (SearchFilters) this
  // service has no reason to know about.
  Future<AlgoliaSearchResult> searchUsers({
    required String query,
    required String filters,
    int page = 0,
  }) async {
    final uri = Uri.parse(
      'https://$algoliaAppId-dsn.algolia.net/1/indexes/$_indexName/query',
    );

    http.Response response;
    try {
      response = await http.post(
        uri,
        headers: {
          'X-Algolia-API-Key': algoliaSearchApiKey,
          'X-Algolia-Application-Id': algoliaAppId,
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'query': query,
          'filters': filters,
          'page': page,
          'hitsPerPage': _hitsPerPage,
        }),
      );
    } catch (_) {
      throw const AlgoliaSearchException('Şəbəkə xətası');
    }

    if (response.statusCode != 200) {
      throw AlgoliaSearchException('Axtarış xətası (${response.statusCode})');
    }

    final Map<String, dynamic> body;
    try {
      body = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      throw const AlgoliaSearchException('Axtarış xətası');
    }

    final hits = (body['hits'] as List? ?? const [])
        .cast<Map<String, dynamic>>()
        .map(User.fromAlgoliaHit)
        .toList();

    return AlgoliaSearchResult(
      users: hits,
      page: (body['page'] as num?)?.toInt() ?? page,
      nbPages: (body['nbPages'] as num?)?.toInt() ?? 1,
    );
  }
}
