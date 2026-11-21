/// Crop a chart image before analysis: drag the corners (or the whole frame) over the candles, leaving out
/// buttons, menus and panels. The last frame is remembered, so screenshots of the same platform need one tap.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/engine_api.dart';
import '../../core/image_prep.dart';
import '../../state/app_state.dart';

const _prefKey = 'last_chart_crop';
const _full = (0.0, 0.0, 1.0, 1.0);

/// The crop frame the user chose last time (used by live analysis over the trading app), or null.
Future<CropFrac?> loadLastCrop() => _loadLast();

Future<CropFrac?> _loadLast() async {
  try {
    final v = (await SharedPreferences.getInstance()).getStringList(_prefKey);
    if (v == null || v.length != 4) return null;
    final d = [for (final s in v) double.parse(s)];
    return (d[0], d[1], d[2], d[3]);
  } catch (_) {
    return null;
  }
}

Future<void> _saveLast(CropFrac c) async {
  try {
    await (await SharedPreferences.getInstance()).setStringList(_prefKey, ['${c.$1}', '${c.$2}', '${c.$3}', '${c.$4}']);
  } catch (_) {}
}

/// Reads the image once, shows the crop screen and returns the user's choice (null = cancelled).
Future<CropDecision?> askChartCrop(BuildContext context, AppState app, UploadFile f) async {
  final bytes = await readAllBytes(f);
  final last = await _loadLast();
  if (!context.mounted) return null;
  final choice = await Navigator.of(context).push<(bool, CropFrac?)>(MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => AppScope(state: app, child: CropScreen(bytes: bytes, initial: last ?? _full)),
  ));
  if (choice == null) return null;
  final image = UploadFile(name: f.name, length: bytes.length, openRead: () => Stream.value(bytes));
  if (choice.$2 != null) await _saveLast(choice.$2!);
  return CropDecision(image, choice.$2);
}

class CropScreen extends StatefulWidget {
  const CropScreen({super.key, required this.bytes, this.initial = _full});
  final Uint8List bytes;
  final CropFrac initial;
  @override
  State<CropScreen> createState() => _CropScreenState();
}

enum _Drag { none, move, tl, tr, bl, br }

class _CropScreenState extends State<CropScreen> {
  late double l = widget.initial.$1, t = widget.initial.$2, r = widget.initial.$3, b = widget.initial.$4;
  _Drag _drag = _Drag.none;
  static const _minFrac = 0.05;

  bool get _isFull => l <= 0.001 && t <= 0.001 && r >= 0.999 && b >= 0.999;

  void _start(Offset p, Rect img) {
    final pts = {
      _Drag.tl: Offset(img.left + l * img.width, img.top + t * img.height),
      _Drag.tr: Offset(img.left + r * img.width, img.top + t * img.height),
      _Drag.bl: Offset(img.left + l * img.width, img.top + b * img.height),
      _Drag.br: Offset(img.left + r * img.width, img.top + b * img.height),
    };
    for (final e in pts.entries) {
      if ((e.value - p).distance <= 36) {
        _drag = e.key;
        return;
      }
    }
    final frame = Rect.fromLTRB(img.left + l * img.width, img.top + t * img.height, img.left + r * img.width, img.top + b * img.height);
    _drag = frame.contains(p) ? _Drag.move : _Drag.none;
  }

  void _update(Offset delta, Rect img) {
    final dx = delta.dx / img.width, dy = delta.dy / img.height;
    setState(() {
      switch (_drag) {
        case _Drag.move:
          final w = r - l, h = b - t;
          l = (l + dx).clamp(0.0, 1.0 - w);
          t = (t + dy).clamp(0.0, 1.0 - h);
          r = l + w;
          b = t + h;
        case _Drag.tl:
          l = (l + dx).clamp(0.0, r - _minFrac);
          t = (t + dy).clamp(0.0, b - _minFrac);
        case _Drag.tr:
          r = (r + dx).clamp(l + _minFrac, 1.0);
          t = (t + dy).clamp(0.0, b - _minFrac);
        case _Drag.bl:
          l = (l + dx).clamp(0.0, r - _minFrac);
          b = (b + dy).clamp(t + _minFrac, 1.0);
        case _Drag.br:
          r = (r + dx).clamp(l + _minFrac, 1.0);
          b = (b + dy).clamp(t + _minFrac, 1.0);
        case _Drag.none:
          break;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(app.t('crop_title')),
        actions: [
          TextButton(
            key: const Key('crop_reset'),
            onPressed: () => setState(() {
              l = t = 0;
              r = b = 1;
            }),
            child: Text(app.t('crop_reset')),
          ),
        ],
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Text(app.t('crop_hint'), style: const TextStyle(color: Colors.white70), textAlign: TextAlign.center),
        ),
        Expanded(
          child: _ImageFrame(
            bytes: widget.bytes,
            builder: (img) => GestureDetector(
              key: const Key('crop_area'),
              behavior: HitTestBehavior.opaque,
              onPanStart: (d) => _start(d.localPosition, img),
              onPanUpdate: (d) => _update(d.delta, img),
              onPanEnd: (_) => _drag = _Drag.none,
              child: CustomPaint(painter: _CropPainter(img, Rect.fromLTRB(l, t, r, b)), size: Size.infinite),
            ),
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  key: const Key('crop_full'),
                  onPressed: () => Navigator.pop(context, (true, null)),
                  icon: const Icon(Icons.fullscreen),
                  label: Text(app.t('crop_full')),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  key: const Key('crop_ok'),
                  onPressed: () => Navigator.pop(context, (true, _isFull ? null : (l, t, r, b))),
                  icon: const Icon(Icons.crop),
                  label: Text(app.t('crop_analyze')),
                ),
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}

/// Lays the image out (contain) and hands the image's rectangle on screen to `builder`.
class _ImageFrame extends StatefulWidget {
  const _ImageFrame({required this.bytes, required this.builder});
  final Uint8List bytes;
  final Widget Function(Rect imageRect) builder;
  @override
  State<_ImageFrame> createState() => _ImageFrameState();
}

class _ImageFrameState extends State<_ImageFrame> {
  Size? _size;

  @override
  void initState() {
    super.initState();
    decodeImageFromList(widget.bytes).then((i) {
      if (mounted) setState(() => _size = Size(i.width.toDouble(), i.height.toDouble()));
    }, onError: (_) {
      if (mounted) setState(() => _size = const Size(1, 1));
    });
  }

  @override
  Widget build(BuildContext context) {
    final size = _size;
    if (size == null) return const Center(child: CircularProgressIndicator());
    return LayoutBuilder(builder: (context, c) {
      const pad = 16.0;
      final scale = math.min((c.maxWidth - 2 * pad) / size.width, (c.maxHeight - 2 * pad) / size.height);
      final w = size.width * scale, h = size.height * scale;
      final img = Rect.fromLTWH((c.maxWidth - w) / 2, (c.maxHeight - h) / 2, w, h);
      return Stack(children: [
        Positioned.fromRect(rect: img, child: Image.memory(widget.bytes, fit: BoxFit.fill, gaplessPlayback: true)),
        Positioned.fill(child: widget.builder(img)),
      ]);
    });
  }
}

class _CropPainter extends CustomPainter {
  _CropPainter(this.img, this.frac);
  final Rect img, frac;

  @override
  void paint(Canvas canvas, Size size) {
    final frame = Rect.fromLTRB(img.left + frac.left * img.width, img.top + frac.top * img.height,
        img.left + frac.right * img.width, img.top + frac.bottom * img.height);
    final shade = Paint()..color = Colors.black.withValues(alpha: 0.55);
    canvas.drawPath(Path.combine(PathOperation.difference, Path()..addRect(img), Path()..addRect(frame)), shade);
    canvas.drawRect(frame, Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2);
    final handle = Paint()..color = Colors.white;
    for (final p in [frame.topLeft, frame.topRight, frame.bottomLeft, frame.bottomRight]) {
      canvas.drawCircle(p, 9, handle);
    }
  }

  @override
  bool shouldRepaint(_CropPainter old) => old.img != img || old.frac != frac;
}
