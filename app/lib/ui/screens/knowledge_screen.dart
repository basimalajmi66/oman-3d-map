import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/engine_api.dart';
import '../../state/app_state.dart';
import '../theme.dart';
import 'learning_reports_screen.dart';
import 'videos_screen.dart';

/// Picks a file from the device. Replaceable in tests.
typedef FilePickFn = Future<UploadFile?> Function();

Future<UploadFile?> pickDeviceFile() async {
  final f = await FilePicker.pickFile(
    type: FileType.custom,
    allowedExtensions: const [
      'pdf', 'docx', 'xlsx', 'xlsm', 'txt', 'md', 'csv', //
      'png', 'jpg', 'jpeg', 'webp', 'bmp', 'mp4', 'mkv', 'mov', 'avi', 'webm',
    ],
  );
  if (f == null) return null;
  final len = await f.length() ?? 0;
  return UploadFile(name: f.name, length: len, openRead: f.readAsByteStream);
}

Future<UploadFile?> pickChartImage() async {
  final f = await FilePicker.pickFile(type: FileType.image);
  if (f == null) return null;
  return UploadFile(name: f.name, length: await f.length() ?? 0, openRead: f.readAsByteStream);
}

/// Knowledge library: add / search / categorise / delete sources and approve
/// or reject the knowledge extracted from them.
class KnowledgeScreen extends StatefulWidget {
  const KnowledgeScreen({super.key, this.pickFile = pickDeviceFile});
  final FilePickFn pickFile;

  @override
  State<KnowledgeScreen> createState() => _KnowledgeScreenState();
}

class _KnowledgeScreenState extends State<KnowledgeScreen> {
  List<Json> _sources = [];
  List<Json>? _hits;
  Json? _selected;
  bool _loading = true;
  final _search = TextEditingController();

  AppState get app => AppScope.read(context);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    await runWithFeedback(context, () async {
      final list = await app.engine.listSources();
      if (!mounted) return;
      setState(() {
        _sources = list;
        _loading = false;
      });
      if (_selected != null) await _select(_selected!['id'] as int);
    });
    if (mounted && _loading) setState(() => _loading = false);
  }

  Future<void> _select(int id) async {
    await runWithFeedback(context, () async {
      final s = await app.engine.getSource(id);
      if (mounted) setState(() => _selected = s);
    });
  }

  Future<void> _doSearch(String q) async {
    if (q.trim().isEmpty) {
      setState(() => _hits = null);
      return;
    }
    await runWithFeedback(context, () async {
      final r = await app.engine.search(q);
      if (mounted) setState(() => _hits = r);
    });
  }

  Future<void> _addNote() async {
    final r = await showDialog<Json>(context: context, builder: (_) => _NoteDialog(app: app));
    if (r == null || !mounted) return;
    await runWithFeedback(context, () async {
      final s = await app.engine.addNote(
          title: r['title'], content: r['content'], category: r['category'], tags: r['tags'], itemType: r['type']);
      _selected = s;
    }, successKey: 'saved');
    await _reload();
  }

  Future<void> _addUrl() async {
    final c = TextEditingController(), t = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(app.t('add_url')),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(key: const Key('url_field'), controller: c, decoration: const InputDecoration(labelText: 'URL')),
          const SizedBox(height: 8),
          TextField(controller: t, decoration: InputDecoration(labelText: app.t('title'))),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(app.t('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(app.t('save'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await runWithFeedback(context, () => app.engine.addUrl(url: c.text.trim(), title: t.text.trim().isEmpty ? null : t.text.trim()),
        successKey: 'saved');
    await _reload();
  }

  Future<void> _addFile() async {
    final f = await widget.pickFile();
    if (f == null || !mounted) return;
    await runWithFeedback(context, () async {
      try {
        _selected = await app.engine.uploadFile(f);
      } on EngineException catch (e) {
        if (e.statusCode == 409) throw EngineException(409, app.t('duplicate_file'));
        rethrow;
      }
    }, successKey: 'saved');
    await _reload();
  }

  Future<void> _delete(Json src) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(app.t('confirm_delete')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(app.t('cancel'))),
          FilledButton(
              key: const Key('confirm_delete'), onPressed: () => Navigator.pop(ctx, true), child: Text(app.t('delete'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await runWithFeedback(context, () => app.engine.deleteSource(src['id'] as int));
    setState(() => _selected = null);
    await _reload();
  }

  Future<void> _decide(Json item, String decision) async {
    await runWithFeedback(context, () => app.engine.decideItem(item['id'] as int, decision));
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(app.t('library')), actions: [
        IconButton(key: const Key('add_note'), tooltip: app.t('add_note'), icon: const Icon(Icons.note_add_outlined), onPressed: _addNote),
        IconButton(key: const Key('add_file'), tooltip: app.t('add_file'), icon: const Icon(Icons.upload_file), onPressed: _addFile),
        IconButton(key: const Key('add_url'), tooltip: app.t('add_url'), icon: const Icon(Icons.link), onPressed: _addUrl),
        IconButton(
          key: const Key('open_videos'),
          tooltip: app.t('videos'),
          icon: const Icon(Icons.video_library_outlined),
          onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const VideosScreen())),
        ),
        IconButton(
          key: const Key('open_reports'),
          tooltip: app.t('learning_reports'),
          icon: const Icon(Icons.fact_check_outlined),
          onPressed: () async {
            await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const LearningReportsScreen()));
            await _reload();
          },
        ),
      ]),
      body: LayoutBuilder(builder: (context, c) {
        final wide = c.maxWidth >= 760;
        final list = _buildList(app, wide);
        if (!wide) return _selected == null ? list : _buildDetail(app, onBack: () => setState(() => _selected = null));
        return Row(children: [
          SizedBox(width: 360, child: list),
          const VerticalDivider(width: 1),
          Expanded(child: _selected == null ? Center(child: Text(app.t('select_source'))) : _buildDetail(app)),
        ]);
      }),
    );
  }

  Widget _buildList(AppState app, bool wide) {
    return Column(children: [
      Padding(
        padding: const EdgeInsets.all(8),
        child: TextField(
          key: const Key('search_field'),
          controller: _search,
          decoration: InputDecoration(prefixIcon: const Icon(Icons.search), hintText: app.t('search')),
          onSubmitted: _doSearch,
          onChanged: (v) {
            if (v.isEmpty) _doSearch('');
          },
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Text(app.t('approval_note'), style: const TextStyle(fontSize: 11)),
      ),
      Expanded(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _hits != null
                ? _buildHits(app)
                : _sources.isEmpty
                    ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(app.t('empty_library'), textAlign: TextAlign.center)))
                    : ListView.builder(
                        itemCount: _sources.length,
                        itemBuilder: (_, i) {
                          final s = _sources[i];
                          final pending = s['pending_count'] as int? ?? 0;
                          return ListTile(
                            key: Key('source_${s['id']}'),
                            selected: _selected?['id'] == s['id'],
                            leading: Icon(_kindIcon(s['kind'] as String?)),
                            title: Text(s['title'] as String? ?? '', maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: Text('${s['category'] ?? s['kind']} · ${fmtDate(s['created_at'] as String?)}'),
                            trailing: pending > 0 ? Badge(label: Text('$pending'), backgroundColor: SignalColors.wait) : null,
                            onTap: () => _select(s['id'] as int),
                          );
                        },
                      ),
      ),
    ]);
  }

  Widget _buildHits(AppState app) {
    if (_hits!.isEmpty) return Center(child: Text(app.t('no_results')));
    return ListView(
      children: _hits!
          .map((h) => ListTile(
                title: Text(h['title'] as String? ?? ''),
                subtitle: Text(
                    '${h['snippet'] ?? ''}\n${app.t('source')}: ${h['source_title'] ?? '—'}'
                    '${h['location'] != null ? ' (${h['location']})' : ''} · ${app.t(h['status'] as String)}',
                    maxLines: 3),
                isThreeLine: true,
                onTap: h['source_id'] == null ? null : () => _select(h['source_id'] as int),
              ))
          .toList(),
    );
  }

  Widget _buildDetail(AppState app, {VoidCallback? onBack}) {
    final s = _selected!;
    final items = (s['items'] as List? ?? const []).cast<Map>().map((e) => e.cast<String, dynamic>()).toList();
    final tags = (s['tags'] as List? ?? const []).join(', ');
    return ListView(padding: const EdgeInsets.all(16), children: [
      Row(children: [
        if (onBack != null) IconButton(icon: const BackButtonIcon(), onPressed: onBack),
        Expanded(child: Text(s['title'] as String? ?? '', style: Theme.of(context).textTheme.titleLarge)),
        IconButton(key: const Key('delete_source'), tooltip: app.t('delete'), icon: const Icon(Icons.delete_outline), onPressed: () => _delete(s)),
      ]),
      Wrap(spacing: 16, runSpacing: 4, children: [
        Text('${app.t('type')}: ${s['kind']}'),
        Text('${app.t('category')}: ${s['category'] ?? '—'}'),
        if (tags.isNotEmpty) Text('${app.t('tags')}: $tags'),
        Text('${app.t('added_at')}: ${fmtDate(s['created_at'] as String?)}'),
        if (s['original_name'] != null) Text('${app.t('source')}: ${s['original_name']} (${fmtBytes(s['size_bytes'] as num?)})'),
        if (s['url'] != null) SelectableText('URL: ${s['url']}'),
        Text('${app.t('extraction')}: ${app.t('extraction_${s['extraction_status']}')}'),
        if (s['notes'] != null) Text('${s['notes']}', style: const TextStyle(fontSize: 12, color: SignalColors.wait)),
        if (s['kind'] == 'video')
          TextButton.icon(
            key: const Key('open_video_page'),
            icon: const Icon(Icons.movie_outlined),
            label: Text(app.t('videos')),
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute<void>(builder: (_) => VideoPage(sourceId: s['id'] as int))),
          ),
        if (s['report'] is Map) Text('${app.t('learning_reports')}: ${(s['report'] as Map)['summary']}',
            key: const Key('source_report_summary'), style: const TextStyle(fontSize: 12)),
      ]),
      const Divider(height: 24),
      Text(app.t('items'), style: Theme.of(context).textTheme.titleMedium),
      if (items.isEmpty) Padding(padding: const EdgeInsets.all(8), child: Text(app.t('none'))),
      ...items.map((it) => Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: Text(it['title'] as String? ?? '', style: const TextStyle(fontWeight: FontWeight.w600))),
                  Chip(
                    label: Text(app.t(it['status'] as String)),
                    backgroundColor: switch (it['status']) {
                      'approved' => SignalColors.buy.withValues(alpha: 0.2),
                      'rejected' => SignalColors.sell.withValues(alpha: 0.2),
                      _ => SignalColors.wait.withValues(alpha: 0.2),
                    },
                  ),
                ]),
                Text('${app.t('type')}: ${app.t('it_${it['item_type']}')}'
                    '${it['location'] != null ? '  ·  ${app.t('location')}: ${it['location']}' : ''}',
                    style: const TextStyle(fontSize: 12)),
                const SizedBox(height: 6),
                SelectableText(it['content'] as String? ?? ''),
                const SizedBox(height: 6),
                Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                  if (it['status'] != 'rejected')
                    TextButton(key: Key('reject_${it['id']}'), onPressed: () => _decide(it, 'reject'), child: Text(app.t('reject'))),
                  if (it['status'] != 'approved')
                    FilledButton(key: Key('approve_${it['id']}'), onPressed: () => _decide(it, 'approve'), child: Text(app.t('approve'))),
                ]),
              ]),
            ),
          )),
    ]);
  }

  IconData _kindIcon(String? kind) => switch (kind) {
        'note' => Icons.sticky_note_2_outlined,
        'pdf' => Icons.picture_as_pdf_outlined,
        'docx' => Icons.description_outlined,
        'xlsx' => Icons.table_chart_outlined,
        'image' => Icons.image_outlined,
        'video' => Icons.movie_outlined,
        'url' => Icons.link,
        _ => Icons.insert_drive_file_outlined,
      };
}

class _NoteDialog extends StatefulWidget {
  const _NoteDialog({required this.app});
  final AppState app;
  @override
  State<_NoteDialog> createState() => _NoteDialogState();
}

class _NoteDialogState extends State<_NoteDialog> {
  final _title = TextEditingController(), _content = TextEditingController();
  final _category = TextEditingController(), _tags = TextEditingController();
  String _type = 'note';

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final valid = _title.text.trim().isNotEmpty && _content.text.trim().isNotEmpty;
    return AlertDialog(
      title: Text(app.t('add_note')),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(key: const Key('note_title'), controller: _title, decoration: InputDecoration(labelText: app.t('title')), onChanged: (_) => setState(() {})),
            const SizedBox(height: 8),
            TextField(
                key: const Key('note_content'),
                controller: _content,
                minLines: 4,
                maxLines: 10,
                decoration: InputDecoration(labelText: app.t('content')),
                onChanged: (_) => setState(() {})),
            const SizedBox(height: 8),
            Row(children: [
              Text('${app.t('type')}: '),
              DropdownButton<String>(
                value: _type,
                items: const ['note', 'rule', 'strategy_fragment', 'example', 'definition']
                    .map((v) => DropdownMenuItem(value: v, child: Text(app.t('it_$v'))))
                    .toList(),
                onChanged: (v) => setState(() => _type = v ?? 'note'),
              ),
            ]),
            TextField(controller: _category, decoration: InputDecoration(labelText: app.t('category'))),
            const SizedBox(height: 8),
            TextField(controller: _tags, decoration: InputDecoration(labelText: app.t('tags'))),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(app.t('cancel'))),
        FilledButton(
          key: const Key('note_save'),
          onPressed: valid
              ? () => Navigator.pop(context, {
                    'title': _title.text.trim(),
                    'content': _content.text.trim(),
                    'category': _category.text.trim().isEmpty ? null : _category.text.trim(),
                    'tags': _tags.text.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList(),
                    'type': _type,
                  })
              : null,
          child: Text(app.t('save')),
        ),
      ],
    );
  }
}
