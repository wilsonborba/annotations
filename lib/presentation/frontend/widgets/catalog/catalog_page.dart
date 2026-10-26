import 'dart:async';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../../domain/models/content.dart';
import '../../components/scope.dart';
import '../../components/shell.dart';
import '../../components/post_card.dart';
import '../../handlers/content_handler.dart';

class CatalogPage extends StatefulWidget {
  final String query, topic, channel;
  const CatalogPage({
    super.key,
    this.query = '',
    this.topic = '',
    this.channel = '',
  });
  @override
  State<CatalogPage> createState() => _CatalogPageState();
}

class _CatalogPageState extends State<CatalogPage> {
  late final search = TextEditingController(text: widget.query);
  Timer? debounce;
  Future<List<Data>>? data;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    data ??= load();
  }

  @override
  void didUpdateWidget(CatalogPage old) {
    super.didUpdateWidget(old);
    if (old.query != widget.query ||
        old.topic != widget.topic ||
        old.channel != widget.channel) {
      search.text = widget.query;
      data = load();
    }
  }

  Future<List<Data>> load() {
    final handler = ContentHandler(AppScope.of(context).service);
    return Future.wait([
      handler.catalog(),
      handler.articles(
        query: widget.query,
        topic: widget.topic,
        channel: widget.channel,
      ),
    ]);
  }

  void navigate({String? query, String? topic, String? channel}) {
    final parameters = {
      'q': query ?? widget.query,
      'topic': topic ?? widget.topic,
      'channel': channel ?? widget.channel,
    }..removeWhere((k, v) => v.isEmpty);
    context.go(Uri(path: '/v1/menu', queryParameters: parameters).toString());
  }

  @override
  void dispose() {
    search.dispose();
    debounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ContentWidth(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.tr('eyebrow'),
          style: TextStyle(
            letterSpacing: 1.7,
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
        const SizedBox(height: 18),
        Text(
          context.tr('browse'),
          style: Theme.of(context).textTheme.headlineLarge,
        ),
        const SizedBox(height: 28),
        TextField(
          key: const Key('catalog-search'),
          controller: search,
          decoration: InputDecoration(
            hintText: context.tr('search'),
            prefixIcon: const Icon(Icons.search_rounded),
          ),
          onChanged: (value) {
            debounce?.cancel();
            debounce = Timer(
              const Duration(milliseconds: 350),
              () => navigate(query: value),
            );
          },
          onSubmitted: (v) => navigate(query: v),
        ),
        const SizedBox(height: 22),
        FutureBuilder<List<Data>>(
          future: data,
          builder: (context, s) {
            if (s.hasError) {
              return LoadError(retry: () => setState(() => data = load()));
            }
            if (!s.hasData) {
              return const Padding(
                padding: EdgeInsets.all(50),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            final catalog = s.data![0];
            final articles = records(s.data![1]['items']);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 16,
                  runSpacing: 14,
                  children: [
                    SizedBox(
                      width: 260,
                      child: DropdownButtonFormField<String>(
                        isExpanded: true,
                        initialValue:
                            records(
                              catalog['topics'],
                            ).any((v) => v['id'] == widget.topic)
                            ? widget.topic
                            : '',
                        decoration: InputDecoration(
                          labelText: context.tr('topics'),
                        ),
                        items: [
                          DropdownMenuItem(
                            value: '',
                            child: Text(context.tr('allTopics')),
                          ),
                          ...records(catalog['topics']).map(
                            (t) => DropdownMenuItem(
                              value: t['id'].toString(),
                              child: Text(t['name'].toString()),
                            ),
                          ),
                        ],
                        onChanged: (v) => navigate(topic: v),
                      ),
                    ),
                    SizedBox(
                      width: 260,
                      child: DropdownButtonFormField<String>(
                        isExpanded: true,
                        initialValue:
                            records(
                              catalog['channels'],
                            ).any((v) => v['id'] == widget.channel)
                            ? widget.channel
                            : '',
                        decoration: InputDecoration(
                          labelText: context.tr('channels'),
                        ),
                        items: [
                          DropdownMenuItem(
                            value: '',
                            child: Text(context.tr('allChannels')),
                          ),
                          ...records(catalog['channels']).map(
                            (t) => DropdownMenuItem(
                              value: t['id'].toString(),
                              child: Text(t['name'].toString()),
                            ),
                          ),
                        ],
                        onChanged: (v) => navigate(channel: v),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 32),
                if (articles.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 50),
                    child: Text(context.tr('empty')),
                  )
                else
                  PostGrid(items: articles),
                if (articles.length == 24) const SizedBox(height: 20),
                if (articles.length == 24)
                  MoreNotes(
                    key: ValueKey(
                      [widget.query, widget.topic, widget.channel].join('|'),
                    ),
                    query: widget.query,
                    topic: widget.topic,
                    channel: widget.channel,
                  ),
              ],
            );
          },
        ),
      ],
    ),
  );
}

class MoreNotes extends StatefulWidget {
  final String query, topic, channel;
  const MoreNotes({
    super.key,
    required this.query,
    required this.topic,
    required this.channel,
  });
  @override
  State<MoreNotes> createState() => _MoreNotesState();
}

class _MoreNotesState extends State<MoreNotes> {
  final List<Data> extra = [];
  bool busy = false, done = false;
  String? error;
  Future<void> more() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = await ContentHandler(AppScope.of(context).service)
          .articles(
            query: widget.query,
            topic: widget.topic,
            channel: widget.channel,
            offset: 24 + extra.length,
          );
      if (!mounted) return;
      final items = records(result['items']);
      setState(() {
        extra.addAll(items);
        done = items.length < 24;
      });
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      PostGrid(items: extra),
      const SizedBox(height: 22),
      if (error != null) Text(error!),
      if (!done)
        OutlinedButton(
          onPressed: busy ? null : more,
          child: Text(context.tr('more')),
        ),
    ],
  );
}
