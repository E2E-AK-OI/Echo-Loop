/// PodcastDiscoveryScreen 纯端侧测试：搜索、链接解析与基础渲染。
library;

import 'package:echo_loop/features/podcast/podcast_models.dart';
import 'package:echo_loop/features/podcast/podcast_preview_provider.dart';
import 'package:echo_loop/features/podcast/podcast_search_provider.dart';
import 'package:echo_loop/features/podcast/podcast_search_service.dart';
import 'package:echo_loop/features/podcast/screens/podcast_discovery_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/mock_providers.dart';
import '../../helpers/test_app.dart';

class _FakeSearchService extends PodcastSearchService {
  _FakeSearchService(this.results);

  final List<PodcastSearchResult> results;
  String? lastTerm;

  @override
  Future<List<PodcastSearchResult>> search(
    String term, {
    int limit = 25,
  }) async {
    lastTerm = term;
    return results;
  }
}

void main() {
  testWidgets('进入页面时搜索框不会自动聚焦', (tester) async {
    await tester.pumpWidget(createTestApp(const PodcastDiscoveryScreen()));
    await tester.pumpAndSettle();

    final editableText = tester.widget<EditableText>(find.byType(EditableText));
    expect(editableText.focusNode.hasFocus, isFalse);
  });

  testWidgets('输入关键词展示 Apple 搜索结果', (tester) async {
    final fakeSearch = _FakeSearchService([
      const PodcastSearchResult(
        id: 's1',
        title: 'BBC Global News',
        author: 'BBC',
        feedUrl: 'https://feeds.bbc.co.uk/news.xml',
      ),
    ]);
    await tester.pumpWidget(
      createTestApp(
        const PodcastDiscoveryScreen(),
        overrides: dedupeOverrides([
          podcastSearchServiceProvider.overrideWithValue(fakeSearch),
        ]),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'bbc');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(find.text('BBC Global News'), findsOneWidget);
    expect(fakeSearch.lastTerm, 'bbc');
  });

  testWidgets('输入链接解析为可订阅 item', (tester) async {
    const url = 'https://example.com/feed.xml';
    await tester.pumpWidget(
      createTestApp(
        const PodcastDiscoveryScreen(),
        overrides: dedupeOverrides([
          podcastPreviewProvider(url).overrideWith(
            (ref) async => const PodcastPreviewData(
              meta: PodcastFeedMeta(
                title: 'Example Cast',
                feedUrl: url,
                author: 'Example Author',
              ),
              episodes: [],
            ),
          ),
        ]),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), url);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(find.text('Example Cast'), findsOneWidget);
    expect(find.text('Subscribe to this link'), findsNothing);
  });
}
