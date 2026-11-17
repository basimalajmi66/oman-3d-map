import 'package:material_ui/material_ui.dart';

import '../../core/engine_api.dart';
import '../../l10n/strings.dart';
import '../../state/app_state.dart';
import '../theme.dart';

/// What the system learned from each source, with candidate rules and conflicts.
/// Nothing here is used by the engine until you approve it.
class LearningReportsScreen extends StatefulWidget {
  const LearningReportsScreen({super.key});
  @override
  State<LearningReportsScreen> createState() => _LearningReportsScreenState();
}

class _LearningReportsScreenState extends State<LearningReportsScreen> {
  List<Json> _reports = [];
  bool _loading = true;

  AppState get app => AppScope.read(context);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  Future<void> _reload() async {
    await runWithFeedback(context, () async {
      final r = await app.engine.listReports(status: 'pending_review');
      if (mounted) setState(() => _reports = r);
    });
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _decide(Json r, String decision) async {
    await runWithFeedback(context, () => app.engine.decideReport(r['id'] as int, decision), successKey: 'saved');
    await _reload();
  }

  String _actions(List actions) => actions.map((a) => hasString('act_$a') ? app.t('act_$a') : '$a').join('، ');

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(app.t('learning_reports'))),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _reports.isEmpty
              ? Center(child: Text(app.t('no_reports'), key: const Key('no_reports')))
              : ListView(padding: const EdgeInsets.all(12), children: [
                  Text(app.t('report_note'), style: const TextStyle(fontSize: 12)),
                  const SizedBox(height: 8),
                  ..._reports.map(_card),
                ]),
    );
  }

  Widget _card(Json r) {
    final ex = (r['extracted'] as Map?)?.cast<String, dynamic>() ?? const {};
    final rules = ((ex['rules'] as List?) ?? const []).cast<Map>();
    final concepts = ((ex['concepts'] as List?) ?? const []).cast<String>();
    final conflicts = ((r['conflicts'] as List?) ?? const []).cast<Map>();
    return Card(
      key: Key('report_${r['id']}'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.auto_stories_outlined),
            const SizedBox(width: 8),
            Expanded(child: Text('${r['source_title'] ?? '—'}', style: const TextStyle(fontWeight: FontWeight.bold))),
            Chip(label: Text(app.t('report_pending')), backgroundColor: SignalColors.wait.withValues(alpha: 0.2)),
          ]),
          Text('${r['summary']}'),
          Text('${app.t('added_at')}: ${fmtDate(r['created_at'] as String?)}', style: const TextStyle(fontSize: 11)),
          if (concepts.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(app.t('concepts_found'), style: const TextStyle(fontWeight: FontWeight.w600)),
            Wrap(spacing: 4, runSpacing: 4, children: concepts.map((c) => Chip(label: Text(c), visualDensity: VisualDensity.compact)).toList()),
          ],
          if (rules.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text('${app.t('candidate_rules')} (${rules.length})', style: const TextStyle(fontWeight: FontWeight.w600)),
            ...rules.map((rule) => Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '• ${rule['text']}\n   → ${_actions(rule['actions'] as List)}'
                    '${(rule['conditions'] as List).isNotEmpty ? '  |  ${(rule['conditions'] as List).join(', ')}' : ''}'
                    '${rule['location'] != null ? '  |  ${app.t('location')}: ${rule['location']}' : ''}',
                    style: const TextStyle(fontSize: 12),
                  ),
                )),
          ],
          if (conflicts.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text('${app.t('conflicts')} (${conflicts.length})',
                key: Key('conflicts_${r['id']}'), style: const TextStyle(fontWeight: FontWeight.bold, color: SignalColors.sell)),
            ...conflicts.map((c) => Container(
                  margin: const EdgeInsets.only(top: 4),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    border: Border.all(color: SignalColors.sell),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    '${app.t('conflict_new')}: ${c['new_text']} → ${_actions(c['new_actions'] as List)}\n'
                    '${app.t('conflict_existing')}: ${c['existing_text']} → ${_actions(c['existing_actions'] as List)}',
                    style: const TextStyle(fontSize: 12),
                  ),
                )),
          ],
          const SizedBox(height: 8),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            TextButton(key: Key('report_reject_${r['id']}'), onPressed: () => _decide(r, 'reject'), child: Text(app.t('reject_all'))),
            const SizedBox(width: 8),
            FilledButton(key: Key('report_approve_${r['id']}'), onPressed: () => _decide(r, 'approve'), child: Text(app.t('approve_all'))),
          ]),
        ]),
      ),
    );
  }
}
