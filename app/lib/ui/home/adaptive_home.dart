import 'package:material_ui/material_ui.dart';

import '../../state/app_state.dart';
import '../panel/floating_panel.dart';

/// Chooses the layout for the device:
/// * desktop          → compact floating panel window (screens open by expanding it)
/// * phone (< 600 dp) → full-screen panel, screens pushed on top
/// * tablet (≥ 600)   → navigation rail; from 1000 dp the panel stays pinned
///                      beside the selected screen
class AdaptiveHome extends StatelessWidget {
  const AdaptiveHome({super.key});

  static const tabletBreakpoint = 600.0;
  static const pinnedPanelBreakpoint = 1000.0;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    if (app.window.isDesktop) return const FloatingPanel();
    return LayoutBuilder(
      builder: (context, c) => c.maxWidth >= tabletBreakpoint ? TabletShell(width: c.maxWidth) : const FloatingPanel(),
    );
  }
}

class TabletShell extends StatefulWidget {
  const TabletShell({super.key, required this.width});
  final double width;
  @override
  State<TabletShell> createState() => _TabletShellState();
}

class _TabletShellState extends State<TabletShell> {
  PanelDestination? _dest; // null = panel

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final pinned = widget.width >= AdaptiveHome.pinnedPanelBreakpoint;
    // with a pinned panel there is always a screen beside it (library by default)
    final shown = pinned ? (_dest ?? (app.has('knowledge') ? PanelDestination.library : PanelDestination.log)) : _dest;
    final destinations = <(PanelDestination?, IconData, String)>[
      if (!pinned) (null, Icons.dashboard_outlined, app.t('panel')),
      if (app.has('knowledge')) (PanelDestination.library, Icons.menu_book_outlined, app.t('library')),
      (PanelDestination.log, Icons.receipt_long_outlined, app.t('log')),
      (PanelDestination.training, Icons.school_outlined, app.t('training')),
      (PanelDestination.settings, Icons.settings_outlined, app.t('settings')),
    ];
    final selected = destinations.indexWhere((d) => d.$1 == shown);

    return Scaffold(
      body: SafeArea(
        child: Row(children: [
          NavigationRail(
            key: const Key('tablet_rail'),
            selectedIndex: selected < 0 ? 0 : selected,
            labelType: NavigationRailLabelType.all,
            onDestinationSelected: app.connected || destinations[0].$1 == null
                ? (i) => setState(() => _dest = destinations[i].$1)
                : null,
            destinations: [
              for (final d in destinations) NavigationRailDestination(icon: Icon(d.$2), label: Text(d.$3)),
            ],
          ),
          const VerticalDivider(width: 1),
          if (pinned) ...[
            SizedBox(
              key: const Key('pinned_panel'),
              width: 380,
              child: FloatingPanel(onNavigate: (d) => setState(() => _dest = d)),
            ),
            const VerticalDivider(width: 1),
          ],
          Expanded(
            child: shown == null
                ? FloatingPanel(onNavigate: (d) => setState(() => _dest = d))
                : KeyedSubtree(key: ValueKey(shown), child: screenFor(shown)),
          ),
        ]),
      ),
    );
  }
}
