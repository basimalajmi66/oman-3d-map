import 'package:material_ui/material_ui.dart';

import '../../l10n/strings.dart';

/// First launch on a phone / tablet: run the analysis on this device, or use the computer's engine.
class ModeChoiceScreen extends StatelessWidget {
  const ModeChoiceScreen({super.key, required this.onChosen, this.lang = 'ar'});
  final ValueChanged<String> onChosen;
  final String lang;

  @override
  Widget build(BuildContext context) {
    String t(String k) => tr(lang, k);
    Widget option(String mode, IconData icon, String title, String hint, {bool recommended = false}) => Card(
          child: ListTile(
            key: Key('mode_$mode'),
            contentPadding: const EdgeInsets.all(16),
            leading: Icon(icon, size: 36),
            title: Text(recommended ? '$title  ·  ${t('mode_recommended')}' : title),
            subtitle: Text(hint),
            onTap: () => onChosen(mode),
          ),
        );
    return Directionality(
      textDirection: lang == 'ar' ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        appBar: AppBar(title: Text(t('mode_choose_title'))),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          option('local', Icons.smartphone, t('mode_local'), t('mode_local_hint'), recommended: true),
          const SizedBox(height: 8),
          option('remote', Icons.computer, t('mode_computer'), t('mode_computer_hint')),
          const SizedBox(height: 16),
          Text(t('manual_only'), textAlign: TextAlign.center),
        ]),
      ),
    );
  }
}
