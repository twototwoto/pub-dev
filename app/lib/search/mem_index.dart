// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:math' as math;

import 'package:meta/meta.dart';
import 'package:logging/logging.dart';
import 'package:pana/pana.dart' show DependencyTypes;
import 'package:path/path.dart' as p;

import '../shared/tags.dart';
import '../shared/utils.dart' show boundedList, StringInternPool;

import 'scope_specificity.dart';
import 'scoring.dart';
import 'search_service.dart';
import 'text_utils.dart';
import 'token_index.dart';

final _logger = Logger('search.mem_index');

class InMemoryPackageIndex implements PackageIndex {
  final math.Random _random;
  final bool _isSdkIndex;
  final String _urlPrefix;
  final Map<String, PackageDocument> _packages = <String, PackageDocument>{};
  final Map<String, String> _normalizedPackageText = <String, String>{};
  final _packageNameIndex = _PackageNameIndex();
  final TokenIndex _nameTokenIndex = TokenIndex(minLength: 2);
  final TokenIndex _descrIndex = TokenIndex(minLength: 3);
  final TokenIndex _readmeIndex = TokenIndex(minLength: 3);
  final TokenIndex _apiSymbolIndex = TokenIndex(minLength: 2);
  final TokenIndex _apiDartdocIndex = TokenIndex(minLength: 3);
  final StringInternPool _internPool = StringInternPool();
  DateTime _lastUpdated;
  bool _isReady = false;

  InMemoryPackageIndex({math.Random random})
      : _random = random ?? math.Random.secure(),
        _isSdkIndex = false,
        _urlPrefix = null;

  InMemoryPackageIndex.sdk({@required String urlPrefix})
      : _random = math.Random.secure(),
        _isSdkIndex = true,
        _urlPrefix = urlPrefix;

  @override
  Future<IndexInfo> indexInfo() async {
    return IndexInfo(
      isReady: _isReady,
      packageCount: _packages.length,
      lastUpdated: _lastUpdated,
    );
  }

  @override
  Future<void> markReady() async {
    _isReady = true;
  }

  @override
  Future<void> addPackage(PackageDocument document) async {
    final doc = document.intern(_internPool.intern);
    _packages[doc.package] = doc;

    // The method could be a single sync block, however, while the index update
    // happens, we are not serving queries. With the forced async segments,
    // the waiting queries will be served earlier.
    await Future.delayed(Duration.zero);
    _packageNameIndex.add(doc.package);
    _nameTokenIndex.add(doc.package, doc.package);

    await Future.delayed(Duration.zero);
    _descrIndex.add(doc.package, doc.description);

    await Future.delayed(Duration.zero);
    _readmeIndex.add(doc.package, doc.readme);

    for (ApiDocPage page in doc.apiDocPages ?? const []) {
      final pageId = _apiDocPageId(doc.package, page);
      if (page.symbols != null && page.symbols.isNotEmpty) {
        await Future.delayed(Duration.zero);
        _apiSymbolIndex.add(pageId, page.symbols.join(' '));
      }
      if (page.textBlocks != null && page.textBlocks.isNotEmpty) {
        await Future.delayed(Duration.zero);
        _apiDartdocIndex.add(pageId, page.textBlocks.join(' '));
      }
    }

    await Future.delayed(Duration.zero);
    final String allText = [doc.package, doc.description, doc.readme]
        .where((s) => s != null)
        .join(' ');

    await Future.delayed(Duration.zero);
    _normalizedPackageText[doc.package] = normalizeBeforeIndexing(allText);

    await Future.delayed(Duration.zero);
    _internPool.checkUnboundGrowth();
    _lastUpdated = DateTime.now().toUtc();
  }

  @override
  Future<void> addPackages(Iterable<PackageDocument> documents) async {
    for (PackageDocument doc in documents) {
      await addPackage(doc);
    }
  }

  @override
  Future<void> removePackage(String package) async {
    final PackageDocument doc = _packages.remove(package);
    if (doc == null) return;
    _packageNameIndex.remove(package);
    _nameTokenIndex.remove(package);
    _descrIndex.remove(package);
    _readmeIndex.remove(package);
    _normalizedPackageText.remove(package);
    for (ApiDocPage page in doc.apiDocPages ?? const []) {
      final pageId = _apiDocPageId(doc.package, page);
      _apiSymbolIndex.remove(pageId);
      _apiDartdocIndex.remove(pageId);
    }
    _lastUpdated = DateTime.now().toUtc();
  }

  @override
  Future<PackageSearchResult> search(SearchQuery query) async {
    final Set<String> packages = Set.from(_packages.keys);

    // filter on package prefix
    if (query.parsedQuery?.packagePrefix != null) {
      final String prefix = query.parsedQuery.packagePrefix.toLowerCase();
      packages.removeWhere(
        (package) =>
            !_packages[package].package.toLowerCase().startsWith(prefix),
      );
    }

    // rank on query scope (e.g. SDK)
    Map<String, double> scopeSpecificity;
    if (query.sdk != null) {
      scopeSpecificity = <String, double>{};
      packages.forEach((String package) {
        final PackageDocument doc = _packages[package];
        scopeSpecificity[package] = scoreScopeSpecificity(query.sdk, doc.tags);
      });
    }

    // filter on tags
    final combinedTagsPredicate =
        query.tagsPredicate.appendPredicate(query.parsedQuery.tagsPredicate);
    if (combinedTagsPredicate.isNotEmpty) {
      packages.retainWhere(
          (package) => combinedTagsPredicate.matches(_packages[package].tags));
    }

    // filter on dependency
    if (query.parsedQuery.hasAnyDependency) {
      packages.removeWhere((package) {
        final doc = _packages[package];
        if (doc.dependencies == null) return true;
        for (String dependency in query.parsedQuery.allDependencies) {
          if (!doc.dependencies.containsKey(dependency)) return true;
        }
        for (String dependency in query.parsedQuery.refDependencies) {
          final String type = doc.dependencies[dependency];
          if (type == null || type == DependencyTypes.transitive) return true;
        }
        return false;
      });
    }

    // filter on owners
    if (query.uploaderOrPublishers != null) {
      assert(query.uploaderOrPublishers.isNotEmpty);

      packages.removeWhere((package) {
        final doc = _packages[package];
        if (doc.publisherId != null) {
          return !query.uploaderOrPublishers.contains(doc.publisherId);
        }
        if (doc.uploaderEmails == null) {
          return true; // turn this into an error in the future.
        }
        return !query.uploaderOrPublishers.any(doc.uploaderEmails.contains);
      });
    }

    // filter on publisher
    if (query.publisherId != null || query.parsedQuery.publisher != null) {
      final publisherId = query.publisherId ?? query.parsedQuery.publisher;
      packages.removeWhere((package) {
        final doc = _packages[package];
        return doc.publisherId != publisherId;
      });
    }

    // filter on email
    if (query.parsedQuery.emails.isNotEmpty) {
      packages.removeWhere((package) {
        final doc = _packages[package];
        if (doc?.uploaderEmails == null) {
          return true;
        }
        for (String email in query.parsedQuery.emails) {
          if (doc.uploaderEmails.contains(email)) {
            return false;
          }
        }
        return true;
      });
    }

    // Remove legacy packages, if not included in the query.
    // TODO: use TagsPredicate instead of SearchQuery.includeLegacy
    if (!query.includeLegacy) {
      packages.removeWhere(
          (p) => _packages[p].tags.contains(PackageVersionTags.isLegacy));
    }

    // do text matching
    final textResults = _searchText(packages, query.parsedQuery.text);

    // filter packages that doesn't match text query
    if (textResults != null) {
      final keys = textResults.pkgScore.getKeys();
      packages.removeWhere((x) => !keys.contains(x));
    }

    List<PackageScore> results;
    switch (query.order ?? SearchOrder.top) {
      case SearchOrder.top:
        final List<Score> scores = [
          _getOverallScore(packages),
        ];
        if (query.order == null && textResults != null) {
          scores.add(textResults.pkgScore);
        }
        if (query.order == null && scopeSpecificity != null) {
          scores.add(Score(scopeSpecificity));
        }
        Score overallScore = Score.multiply(scores);
        // If there is an exact match for a package name, promote it to the top position.
        final queryText = query?.parsedQuery?.text;
        final matchingPackage = queryText == null
            ? null
            : (_packages[queryText] ?? _packages[queryText.toLowerCase()]);
        if (matchingPackage != null &&
            matchingPackage.maintenance != null &&
            matchingPackage.maintenance > 0.0 &&
            packages.contains(matchingPackage.package)) {
          final double maxValue = overallScore.getMaxValue();
          final map = Map<String, double>.from(
              overallScore.map((key, value) => value * 0.99).getValues());
          map[matchingPackage.package] = maxValue;
          overallScore = Score(map);
        }
        results = _rankWithValues(overallScore.getValues());
        break;
      case SearchOrder.text:
        results = _rankWithValues(textResults.pkgScore.getValues());
        break;
      case SearchOrder.created:
        results = _rankWithComparator(packages, _compareCreated);
        break;
      case SearchOrder.updated:
        results = _rankWithComparator(packages, _compareUpdated);
        break;
      case SearchOrder.popularity:
        results = _rankWithValues(getPopularityScore(packages));
        break;
      case SearchOrder.health:
        results = _rankWithValues(getHealthScore(packages));
        break;
      case SearchOrder.maintenance:
        results = _rankWithValues(getMaintenanceScore(packages));
        break;
      case SearchOrder.like:
        results = _rankWithValues(getLikeScore(packages));
        break;
    }

    // bound by offset and limit (or randomize items)
    int totalCount;
    if (query.randomize) {
      final limit = math.max(10, query.limit ?? 0);
      final sublist = boundedList(results, offset: 0, limit: limit * 10);
      sublist.shuffle(_random);
      results = sublist.take(limit).map((sr) => sr.onlyPackageName()).toList();
      totalCount = results.length;
    } else {
      totalCount = results.length;
      results = boundedList(results, offset: query.offset, limit: query.limit);
    }

    if (textResults != null &&
        textResults.topApiPages != null &&
        textResults.topApiPages.isNotEmpty) {
      results = results.map((ps) {
        final apiPages = textResults.topApiPages[ps.package]
            // TODO: extract title for the page
            ?.map((String page) => ApiPageRef(path: page))
            ?.toList();
        return ps.change(apiPages: apiPages);
      }).toList();
    }

    if (_isSdkIndex) {
      results = results.map((ps) {
        String url = _urlPrefix;
        final doc = _packages[ps.package];
        final description = doc.description ?? ps.package;
        if (doc.apiDocPages != null && doc.apiDocPages.isNotEmpty) {
          final libPage = doc.apiDocPages.firstWhere(
            (dp) => dp.relativePath.endsWith('-library.html'),
            orElse: () => doc.apiDocPages.first,
          );
          url = p.join(_urlPrefix, libPage.relativePath);
        }
        final apiPages = ps.apiPages
            ?.map((ref) => ref.change(url: p.join(_urlPrefix, ref.path)))
            ?.toList();
        return ps.change(
          url: url,
          version: doc.version,
          description: description,
          apiPages: apiPages,
        );
      }).toList();
    }

    return PackageSearchResult(
      totalCount: totalCount,
      indexUpdated: _lastUpdated?.toIso8601String(),
      packages: results,
    );
  }

  @visibleForTesting
  Map<String, double> getHealthScore(Iterable<String> packages) {
    return Map.fromIterable(
      packages,
      value: (package) => (_packages[package].health ?? 0.0),
    );
  }

  @visibleForTesting
  Map<String, double> getPopularityScore(Iterable<String> packages) {
    return Map.fromIterable(
      packages,
      value: (package) => _packages[package].popularity ?? 0.0,
    );
  }

  @visibleForTesting
  Map<String, double> getMaintenanceScore(Iterable<String> packages) {
    return Map.fromIterable(
      packages,
      value: (package) => (_packages[package].maintenance ?? 0.0),
    );
  }

  @visibleForTesting
  Map<String, double> getLikeScore(Iterable<String> packages) {
    return Map.fromIterable(
      packages,
      value: (package) => (_packages[package].likeCount?.toDouble() ?? 0.0),
    );
  }

  Score _getOverallScore(Iterable<String> packages) {
    final Map<String, double> values =
        Map.fromIterable(packages, value: (package) {
      final doc = _packages[package];
      final double overall = calculateOverallScore(
        popularity: doc.popularity ?? 0.0,
        health: doc.health ?? 0.0,
        maintenance: doc.maintenance ?? 0.0,
      );
      // don't multiply with zero.
      return 0.3 + 0.7 * overall;
    });
    return Score(values);
  }

  _TextResults _searchText(Set<String> packages, String text) {
    final sw = Stopwatch()..start();
    if (text != null && text.isNotEmpty) {
      final words = splitForQuery(text);
      final wordCount = words.length;
      final pkgScores = <Score>[];
      final apiPagesScores = <Score>[];
      bool aborted = false;

      for (String word in words) {
        if (packages.isEmpty) break;
        if (sw.elapsedMilliseconds > 500) {
          aborted = true;
          _logger.info(
              '[pub-aborted-search-query] Aborted word lookup after ${pkgScores.length} words and ${sw.elapsedMilliseconds} ms.');
          break;
        }

        final nameTokens = _nameTokenIndex.lookupTokens(word);
        final descrTokens = _descrIndex.lookupTokens(word);
        final readmeTokens = _readmeIndex.lookupTokens(word);

        final name = Score(_nameTokenIndex.scoreDocs(nameTokens,
            weight: 1.00, wordCount: wordCount, limitToIds: packages));
        final descr = Score(_descrIndex.scoreDocs(descrTokens,
            weight: 0.90, wordCount: wordCount, limitToIds: packages));
        final readme = Score(_readmeIndex.scoreDocs(readmeTokens,
            weight: 0.75, wordCount: wordCount, limitToIds: packages));

        final apiSymbolTokens = _apiSymbolIndex.lookupTokens(word);
        final apiDartdocTokens = _apiDartdocIndex.lookupTokens(word);
        final symbolPages = Score(_apiSymbolIndex.scoreDocs(apiSymbolTokens,
            weight: 0.70, wordCount: wordCount));
        final dartdocPages = Score(_apiDartdocIndex.scoreDocs(apiDartdocTokens,
            weight: 0.40, wordCount: wordCount));
        final apiPages = Score.max([symbolPages, dartdocPages]);
        apiPagesScores.add(apiPages);

        final apiPackages = <String, double>{};
        for (String key in apiPages.getKeys()) {
          final pkg = _apiDocPkg(key);
          if (!packages.contains(pkg)) continue;
          final value = apiPages[key];
          apiPackages[pkg] = math.max(value, apiPackages[pkg] ?? 0.0);
        }
        final apiScore = Score(apiPackages);

        final score = Score.max([name, descr, readme, apiScore]);
        pkgScores.add(score);

        // Restrict the next round of `scoreDocs` to fewer documents, as the
        // packages with zero won't be part of the result anyway.
        packages = score.getKeys(where: packages.contains).toSet();
      }
      final nameScore =
          _packageNameIndex.searchWords(words, packages: packages);
      final fuzzyScore = Score.multiply(pkgScores)
          .project(packages)
          .removeLowValues(fraction: 0.01, minValue: 0.001);
      Score score = Score.max([nameScore, fuzzyScore]);

      // filter results based on exact phrases
      final phrases =
          extractExactPhrases(text).map(normalizeBeforeIndexing).toList();
      if (!aborted && phrases.isNotEmpty) {
        final Map<String, double> matched = <String, double>{};
        for (String package in score.getKeys()) {
          final allText = _normalizedPackageText[package];
          final bool matchedAllPhrases =
              phrases.every((phrase) => allText.contains(phrase));
          if (matchedAllPhrases) {
            matched[package] = score[package];
          }
        }
        score = Score(matched);
      }

      final apiDocScore = Score.multiply(apiPagesScores);
      final apiDocKeys = apiDocScore.getKeys().toList()
        ..sort((a, b) => -apiDocScore[a].compareTo(apiDocScore[b]));
      final topApiPages = <String, List<String>>{};
      for (String key in apiDocKeys) {
        final pkg = _apiDocPkg(key);
        final pages = topApiPages.putIfAbsent(pkg, () => []);
        if (pages.length < 3) {
          final page = _apiDocPath(key);
          pages.add(page);
        }
      }

      return _TextResults(score, topApiPages);
    }
    return null;
  }

  List<PackageScore> _rankWithValues(Map<String, double> values) {
    final List<PackageScore> list = values.keys
        .map((package) {
          final score = values[package];
          return PackageScore(package: package, score: score);
        })
        .where((ps) => ps != null)
        .toList();
    list.sort((a, b) {
      final int scoreCompare = -a.score.compareTo(b.score);
      if (scoreCompare != 0) return scoreCompare;
      // if two packages got the same score, order by last updated
      return _compareUpdated(_packages[a.package], _packages[b.package]);
    });
    return list;
  }

  List<PackageScore> _rankWithComparator(Set<String> packages,
      int Function(PackageDocument a, PackageDocument b) compare) {
    final List<PackageScore> list = packages
        .map((package) => PackageScore(package: _packages[package].package))
        .toList();
    list.sort((a, b) => compare(_packages[a.package], _packages[b.package]));
    return list;
  }

  int _compareCreated(PackageDocument a, PackageDocument b) {
    if (a.created == null) return -1;
    if (b.created == null) return 1;
    return -a.created.compareTo(b.created);
  }

  int _compareUpdated(PackageDocument a, PackageDocument b) {
    if (a.updated == null) return -1;
    if (b.updated == null) return 1;
    return -a.updated.compareTo(b.updated);
  }

  String _apiDocPageId(String package, ApiDocPage page) {
    return '$package::${page.relativePath}';
  }

  String _apiDocPkg(String id) {
    return id.split('::').first;
  }

  String _apiDocPath(String id) {
    return id.split('::').last;
  }
}

class _TextResults {
  final Score pkgScore;
  final Map<String, List<String>> topApiPages;

  _TextResults(this.pkgScore, this.topApiPages);
}

/// A simple (non-inverted) index designed for package name lookup.
class _PackageNameIndex {
  /// Maps package name to a reduced form of the same name.
  final _collapsedNames = <String, String>{};

  /// Add a new [package] to the index.
  void add(String package) {
    _collapsedNames[package] = splitForQuery(package).join('');
  }

  /// Remove a [package] from the index.
  void remove(String package) {
    _collapsedNames.remove(package);
  }

  /// Search [text] and return the matching packages with scores.
  Score search(String text) {
    return searchWords(splitForQuery(text));
  }

  /// Search using the parsed [words] and return the match packages with scores.
  Score searchWords(List<String> words, {Set<String> packages}) {
    final pkgNamesToCheck = packages ?? _collapsedNames.keys;
    final values = <String, double>{};
    for (final pkg in pkgNamesToCheck) {
      final collapsed = _collapsedNames[pkg];
      // all words must be found inside the collapsed name
      // returns null if any of them is missing,
      // otherwise returns the unmatched substrings joined by `_`
      final unmatched = words.fold<String>(collapsed, (c, word) {
        if (c == null) return null;
        if (collapsed.contains(word)) {
          return c.replaceFirst(word, '_');
        }
        return null;
      })?.replaceAll('_', '');
      if (unmatched == null) continue;
      final score = (collapsed.length - unmatched.length) / collapsed.length;
      values[pkg] = score;
    }
    return Score(values);
  }
}
