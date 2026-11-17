import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/engine_api.dart';
import '../../l10n/strings.dart';
import '../../state/app_state.dart';
import '../theme.dart';
import 'knowledge_screen.dart' show FilePickFn;

Future<UploadFile?> pickSubtitles() async {
  final f = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: const ['srt', 'vtt']);
  if (f == null) return null;
  return UploadFile(name: f.name, length: await f.length() ?? 0, openRead: f.readAsByteStream);
}

String _pct(num? v) => v == null ? '—' : '${(v * 100).round()}%';

/// List of educational videos and their analysis status.
class VideosScreen extends StatefulWidget {
  const VideosScreen({super.key});
  @override
  State<VideosScreen> createState() => _VideosScreenState();
}

class _VideosScreenState extends State<VideosScreen> {
  List<Json> _videos = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  Future<void> _reload() async {
    final app = AppScope.read(context);
    await runWithFeedback(context, () async {
      final v = await app.engine.listVideos();
      if (mounted) setState(() => _videos = v);
    });
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(app.t('videos'))),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _videos.isEmpty
              ? Center(child: Text(app.t('no_videos'), key: const Key('no_videos')))
              : ListView(
                  children: _videos
                      .map((v) => ListTile(
                            key: Key('video_${v['source_id']}'),
                            leading: const Icon(Icons.movie_outlined),
                            title: Text('${v['title']}'),
                            subtitle: Text('${app.t('vs_${v['status']}')}'
                                '${v['status'] == 'processing' ? ' ${_pct(v['progress'] as num?)}' : ''}'
                                '${v['report_status'] != null ? ' · ${app.t(v['report_status'] as String)}' : ''}'),
                            onTap: () async {
                              await Navigator.of(context).push(MaterialPageRoute<void>(
                                  builder: (_) => VideoPage(sourceId: v['source_id'] as int)));
                              await _reload();
                            },
                          ))
                      .toList(),
                ),
    );
  }
}

/// The video page: summary, strategy, rules with exact times and clarity, approval.
class VideoPage extends StatefulWidget {
  const VideoPage({super.key, required this.sourceId, this.pickSubtitlesFn = pickSubtitles, this.poll = true});
  final int sourceId;
  final FilePickFn pickSubtitlesFn;
  final bool poll;
  @override
  State<VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<VideoPage> {
  Json? _page;
  Timer? _timer;

  AppState get app => AppScope.read(context);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _reload() async {
    await runWithFeedback(context, () async {
      final p = await app.engine.videoPage(widget.sourceId);
      if (!mounted) return;
      setState(() => _page = p);
      final busy = p['status'] == 'queued' || p['status'] == 'processing';
      _timer?.cancel();
      if (busy && widget.poll) _timer = Timer(const Duration(seconds: 2), _reload);
    });
  }

  Future<void> _subtitles() async {
    final f = await widget.pickSubtitlesFn();
    if (f == null || !mounted) return;
    await runWithFeedback(context, () => app.engine.uploadSubtitles(widget.sourceId, f), successKey: 'saved');
    await _reload();
  }

  Future<void> _decide(String decision) async {
    final report = _page?['report'] as Map?;
    if (report == null) return;
    await runWithFeedback(context, () => app.engine.decideReport(report['id'] as int, decision), successKey: 'saved');
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final p = _page;
    return Scaffold(
      appBar: AppBar(title: Text(p == null ? app.t('videos') : '${p['title']}'), actions: [
        IconButton(key: const Key('btn_subtitles'), tooltip: app.t('add_subtitles'), icon: const Icon(Icons.subtitles_outlined),
            onPressed: p == null ? null : _subtitles),
        IconButton(key: const Key('btn_reanalyze'), tooltip: app.t('reanalyze'), icon: const Icon(Icons.refresh),
            onPressed: p == null
                ? null
                : () async {
                    await runWithFeedback(context, () => app.engine.reanalyzeVideo(widget.sourceId));
                    await _reload();
                  }),
      ]),
      body: p == null ? const Center(child: CircularProgressIndicator()) : _body(app, p),
    );
  }

  Widget _section(String title, List<Widget> children, {Key? key}) => Padding(
        key: key,
        padding: const EdgeInsets.only(top: 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          ...children,
        ]),
      );

  Widget _body(AppState app, Json p) {
    final status = p['status'] as String;
    final report = (p['report'] as Map?)?.cast<String, dynamic>();
    final strategy = (p['strategy'] as Map?)?.cast<String, dynamic>();
    List<Map> list(dynamic v) => ((v as List?) ?? const []).cast<Map>();
    final warnings = ((p['warnings'] as List?) ?? const []).cast<String>();
    String tw(String w) => hasString('w_$w') ? app.t('w_$w') : w;
    return ListView(padding: const EdgeInsets.all(16), children: [
      Row(children: [
        Chip(key: const Key('video_status'), label: Text(app.t('vs_$status'))),
        const SizedBox(width: 8),
        if (status == 'processing' || status == 'queued')
          Expanded(child: LinearProgressIndicator(value: (p['progress'] as num?)?.toDouble())),
      ]),
      if (p['error'] != null) Text('${p['error']}', style: const TextStyle(color: SignalColors.sell)),
      if (status == 'done') ...[
        Text('${app.t('transcript')}: ${app.t('ts_${p['transcript_source'] ?? 'none'}')}', key: const Key('transcript_source')),
        if (warnings.isNotEmpty)
          Text(warnings.map(tw).join(' · '), key: const Key('video_warnings'), style: const TextStyle(fontSize: 12, color: SignalColors.wait)),
        if (report != null)
          _section(app.t('approval_status'), [
            Text('${app.t(report['status'] as String)} — ${report['summary']}', key: const Key('video_report')),
            if (report['status'] == 'pending_review')
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                TextButton(key: const Key('video_reject'), onPressed: () => _decide('reject'), child: Text(app.t('reject_all'))),
                FilledButton(key: const Key('video_approve'), onPressed: () => _decide('approve'), child: Text(app.t('approve_all'))),
              ]),
          ]),
        _section(app.t('video_summary'), [
          ...list(p['summary']).map((s) => Text('[${s['time']}] ${s['text']}', style: const TextStyle(fontSize: 13))),
        ]),
        if (strategy != null)
          _section(app.t('extracted_strategy'), key: const Key('video_strategy'), [
            Text(app.t('strategy_draft_note'), style: const TextStyle(fontSize: 11, fontStyle: FontStyle.italic)),
            for (final k in ['entry_conditions', 'no_entry_conditions', 'exit_conditions']) ...[
              const SizedBox(height: 4),
              Text(app.t(k), style: const TextStyle(fontWeight: FontWeight.w600)),
              if (list(strategy[k]).isEmpty) Text(app.t('none'), style: const TextStyle(fontSize: 12)),
              ...list(strategy[k]).map((c) => Text(
                  '• [${c['time']}] ${c['text']}${c['clarity'] != null ? '  (${app.t('clarity')} ${_pct(c['clarity'] as num?)})' : ''}',
                  style: const TextStyle(fontSize: 12))),
            ],
          ]),
        _section(app.t('strategy_rules'), [
          ...list(p['rules']).map((r) => ListTile(
                key: Key('vrule_${r['id']}'),
                dense: true,
                leading: Text('${r['location']}', style: const TextStyle(fontWeight: FontWeight.bold)),
                title: Text('${r['content']}'),
                subtitle: Text('${app.t('clarity')}: ${_pct(r['clarity'] as num?)} · ${app.t(r['status'] as String)}'),
              )),
        ]),
        if (list(p['charts']).isNotEmpty)
          _section(app.t('chart_scenes'), [
            ...list(p['charts']).map((c) => Text(
                '• [${c['time']}] ${c['candles']} · ${app.t('trend')}: ${c['trend'] != null ? app.t('trend_dir_${c['trend']}') : '—'}'
                '${(c['patterns'] as List).isNotEmpty ? ' · ${(c['patterns'] as List).join(', ')}' : ''}',
                style: const TextStyle(fontSize: 12))),
          ]),
      ],
    ]);
  }
}
