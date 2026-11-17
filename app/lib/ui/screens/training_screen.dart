import 'package:material_ui/material_ui.dart';

import '../../state/app_state.dart';
import '../theme.dart';

/// Training & backtesting. The engine (Phase 7) is not built yet, so this screen
/// shows the real, engine-reported component status instead of a fake UI.
class TrainingScreen extends StatelessWidget {
  const TrainingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final comps = (app.status['components'] as Map?)?.cast<String, dynamic>() ?? const {};
    return Scaffold(
      appBar: AppBar(title: Text(app.t('training_title'))),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text(app.t('training_unavailable')),
        const SizedBox(height: 12),
        ...comps.entries.map((e) {
          final ok = e.value == true;
          return ListTile(
            key: Key('comp_${e.key}'),
            leading: Icon(ok ? Icons.check_circle : Icons.pending_outlined,
                color: ok ? SignalColors.buy : SignalColors.wait),
            title: Text(app.t('comp_${e.key}')),
            trailing: Text(app.t(ok ? 'available' : 'not_available')),
          );
        }),
      ]),
    );
  }
}
