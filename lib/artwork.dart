import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core.dart';

Color museColor(dynamic value, [Color fallback = Colors.white]) {
  var s = colorHex(value).replaceAll('#', '');
  if (s.length == 6) s += 'ff';
  final n = int.tryParse(s, radix: 16);
  return s.length != 8 || n == null
      ? fallback
      : Color(((n & 255) << 24) | (n >> 8));
}

Offset point(dynamic v, [Offset fallback = Offset.zero]) =>
    v is List && v.length >= 2 ? Offset(numv(v[0]), numv(v[1])) : fallback;

class Affine {
  final double a, b, c, d, x, y;
  const Affine([
    this.a = 1,
    this.b = 0,
    this.c = 0,
    this.d = 1,
    this.x = 0,
    this.y = 0,
  ]);
  factory Affine.transform(Offset p, double r, Offset s, [double skew = 0]) =>
      Affine(
        math.cos(r) * s.dx,
        math.sin(r) * s.dx,
        -math.sin(r + skew) * s.dy,
        math.cos(r + skew) * s.dy,
        p.dx,
        p.dy,
      );
  factory Affine.move(Offset p) => Affine(1, 0, 0, 1, p.dx, p.dy);
  Affine operator *(Affine q) => Affine(
    a * q.a + c * q.b,
    b * q.a + d * q.b,
    a * q.c + c * q.d,
    b * q.c + d * q.d,
    a * q.x + c * q.y + x,
    b * q.x + d * q.y + y,
  );
  Float64List get matrix =>
      Float64List.fromList([a, b, 0, 0, c, d, 0, 0, 0, 0, 1, 0, x, y, 0, 1]);
}

class SpriteLayer {
  final String uid, type, name, key;
  final ui.Image image;
  final Affine matrix;
  final Color color;
  final double z;
  SpriteLayer? mask;
  SpriteLayer(
    this.uid,
    this.type,
    this.name,
    this.key,
    this.image,
    this.matrix,
    this.color,
    this.z,
  );
}

class MuseFrame {
  final List<SpriteLayer> layers;
  final List<String> missing;
  MuseFrame(this.layers, this.missing);
  Set<String> get keys => layers.map((x) => x.key).toSet();
}

class Artwork {
  final MuseData db;
  final MuseStore store;
  final LinkedHashMap<String, ui.Image> _cache = LinkedHashMap();
  final Map<String, Future<ui.Image?>> _pending = {};
  int busy = 0;
  bool _closed = false;
  Artwork(this.db, this.store);
  Future<ui.Image?> image(String key) async {
    if (_closed || key.isEmpty) return null;
    final cached = _cache.remove(key);
    if (cached != null) {
      _cache[key] = cached;
      return cached;
    }
    if (_pending.containsKey(key)) return _pending[key];
    final future = _load(key);
    _pending[key] = future;
    try {
      return await future;
    } finally {
      _pending.remove(key);
    }
  }

  Future<ui.Image?> _load(String key) async {
    try {
      Uint8List bytes;
      if (key.startsWith('user://')) {
        bytes = await File(store.localPath(key)).readAsBytes();
      } else {
        final path = str(obj(db.art[key])['asset']);
        if (path.isEmpty) return null;
        final data = await rootBundle.load(path);
        bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      }
      final codec = await ui.instantiateImageCodec(bytes),
          frame = await codec.getNextFrame();
      codec.dispose();
      if (_closed) {
        frame.image.dispose();
        return null;
      }
      _cache[key] = frame.image;
      return frame.image;
    } catch (_) {
      return null;
    }
  }

  void trim(Set<String> active) {
    if (busy > 0) return;
    var bytes = _cache.values.fold<int>(
      0,
      (sum, i) => sum + i.width * i.height * 4,
    );
    for (final key in _cache.keys.toList()) {
      if (bytes <= 96 * 1024 * 1024) break;
      if (active.contains(key)) continue;
      final i = _cache.remove(key)!;
      bytes -= i.width * i.height * 4;
      i.dispose();
    }
  }

  void dispose() {
    _closed = true;
    for (final image in _cache.values) {
      image.dispose();
    }
    _cache.clear();
  }

  Future<MuseFrame> build(Json data, {bool studio = false}) async {
    busy++;
    final result = <SpriteLayer>[], missing = <String>[];
    try {
      if (studio) {
        for (final raw in arr(data['actors'])) {
          final actor = obj(raw),
              s = numv(raw['scale'], .65).clamp(.1, 3.0).toDouble();
          result.addAll(
            await _character(
              obj(actor['character']),
              Affine.transform(
                Offset(numv(actor['x']), numv(actor['y'])),
                numv(actor['rotation']) * math.pi / 180,
                Offset(s, s),
              ),
              missing,
            ),
          );
        }
      } else {
        result.addAll(await _character(data, const Affine(), missing));
      }
      return MuseFrame(result, missing);
    } finally {
      busy--;
    }
  }

  Affine _home(Json n) => Affine.transform(
    point(n['position']),
    numv(n['rotation']),
    point(n['scale'], const Offset(1, 1)),
    numv(n['skew']),
  );
  Affine _core(Json i) => Affine.transform(
    Offset.zero,
    numv(i['rot']) * math.pi / 180 + numv(i['skew_v']),
    Offset(
      numv(i['scale_x'], 1) * (flag(i['flip_h']) ? -1 : 1),
      numv(i['scale_y'], 1) * (flag(i['flip_v']) ? -1 : 1),
    ),
    numv(i['skew']) - numv(i['skew_v']),
  );
  Affine _local(Json n, Json i) {
    final s = point(n['scale'], const Offset(1, 1));
    return Affine.transform(
      point(n['position']) + Offset(numv(i['pos_x']), numv(i['pos_y'])),
      numv(n['rotation']) + numv(i['rot']) * math.pi / 180 + numv(i['skew_v']),
      Offset(
        s.dx * numv(i['scale_x'], 1) * (flag(i['flip_h']) ? -1 : 1),
        s.dy * numv(i['scale_y'], 1) * (flag(i['flip_v']) ? -1 : 1),
      ),
      numv(n['skew']) + numv(i['skew']) - numv(i['skew_v']),
    );
  }

  Future<List<SpriteLayer>> _character(
    Json data,
    Affine stage,
    List<String> missing,
  ) async {
    final items = arr(data['items']).map(obj).toList(), live = <String, Json>{};
    for (final i in items) {
      live.putIfAbsent(str(i['unique_id']), () => i);
    }
    final cache = <String, Affine>{},
        resolving = <String>{},
        templateResolving = <String>{};
    var anchor = const Affine();
    for (final torso in items) {
      if (torso['base_type'] == 'Torso' && str(torso['managed_by']).isEmpty) {
        final home = db.templates['Torso'];
        if (home != null) {
          final p = point(home['position']);
          anchor =
              Affine.move(
                p + Offset(numv(torso['pos_x']), numv(torso['pos_y'])),
              ) *
              _core(torso) *
              Affine.move(-p);
        }
        break;
      }
    }
    late Affine Function(String) template;
    template = (name) {
      final n = db.templates[name];
      if (n == null || !templateResolving.add(name)) return anchor;
      final par = str(n['parent']).split('/').last,
          result = (par == '.' ? anchor : template(par)) * _home(n);
      templateResolving.remove(name);
      return result;
    };
    late Affine Function(Json) world;
    world = (i) {
      final id = str(i['unique_id']);
      if (cache[id] != null) return cache[id]!;
      if (!resolving.add(id)) return const Affine();
      final n = db.templates[str(i['base_type'])] ?? <String, dynamic>{},
          par = str(n['parent'], '.').split('/').last,
          parent = live['${par}_1'];
      final p = par == '.'
          ? anchor
          : parent != null
          ? world(parent)
          : template(par);
      resolving.remove(id);
      return cache[id] =
          p * (i['base_type'] == 'Torso' ? _home(n) : _local(n, i));
    };
    final result = <SpriteLayer>[],
        height = numv(data['height_scale'], .95).clamp(.1, 3.0).toDouble(),
        all = stage * Affine.transform(Offset.zero, 0, Offset(height, height));
    for (final it in items) {
      final type = str(it['base_type']),
          id = str(it['unique_id']),
          pre = str(it['prefix']);
      if (pre.isEmpty || flag(it['hidden'])) continue;
      final n = db.templates[type],
          slots = db.layers[str(n?['path'])] ?? <Json>[],
          base = pre.split('/').last;
      final order = arr(
        obj(db.constants['EMOTIVE_DRAW_ORDER'])[base] ??
            obj(db.constants['TOP_LAYER_DRAW_ORDER'])[base] ??
            ['c1', 'c2', 'c3', 'c4', 'c5', 'c6', 'c7', 'c8', 'lineart'],
      );
      var sequence = 0;
      for (final raw in order) {
        final name = str(raw),
            key = db.resolve(pre, name, flag(data['is_chest_active']));
        if (key.isEmpty) continue;
        final img = await image(key);
        if (img == null) {
          missing.add(key);
          continue;
        }
        Json slot = {};
        for (final s in slots) {
          if (s['name'] == name) {
            slot = s;
            break;
          }
        }
        var off = point(slot['offset']) + point(slot['position']);
        final crop = arr(obj(db.root['sprite_rects'])[key]);
        if (crop.length >= 4) {
          final x = math.max(0.0, numv(crop[0]) - 2),
              y = math.max(0.0, numv(crop[1]) - 2),
              r = math.min(1120.0, numv(crop[0]) + numv(crop[2]) + 2),
              b = math.min(1180.0, numv(crop[1]) + numv(crop[3]) + 2);
          if ((img.width - r + x).abs() < 1 && (img.height - b + y).abs() < 1) {
            off += Offset((x + r) / 2 - 560, (y + b) / 2 - 590);
          }
        }
        final lo = obj(obj(it['layer_offsets'])[name]);
        off += Offset(numv(lo['x']), numv(lo['y']));
        var color = museColor(it[name == 'lineart' ? 'c_line' : name]);
        if (type.startsWith('Eyeshape') &&
            obj(db.constants['EMOTIVE_DRAW_ORDER'])[base] != null) {
          color = Colors.white;
        }
        final tint = museColor(data['tint_colour']),
            strength = numv(data['tint_strength']).clamp(0.0, 1.0).toDouble();
        color = Color.lerp(
          color,
          Color.from(
            alpha: color.a,
            red: color.r * tint.r,
            green: color.g * tint.g,
            blue: color.b * tint.b,
          ),
          strength,
        )!;
        result.add(
          SpriteLayer(
            id,
            type,
            name,
            key,
            img,
            all * world(it) * Affine.move(off),
            color,
            numv(it['custom_z'], db.z(type)) * 10 + sequence++,
          ),
        );
      }
    }
    result.sort((a, b) => a.z.compareTo(b.z));
    for (final layer in result) {
      final clip = str(obj(data['clips'])[layer.uid]);
      if (clip.isNotEmpty) {
        for (final m in result) {
          if (m.uid == clip && m.name == 'c1') {
            layer.mask = m;
            break;
          }
        }
      }
      if (layer.mask == null &&
          (layer.type.startsWith('Iris') || layer.type.startsWith('Pupil'))) {
        final eye =
            'Eyeshape ${layer.type.contains('Right') ? 'Right' : 'Left'}';
        for (final m in result) {
          final sclera = str(
            obj(db.constants['EYE_SCLERA_LAYER'])[m.key
                .split('/')
                .last
                .split('_')
                .first],
            'c1',
          );
          if (m.type == eye && m.name == sclera) {
            layer.mask = m;
            break;
          }
        }
      }
    }
    return result;
  }
}

class MusePainter extends CustomPainter {
  final MuseFrame frame;
  final Color background;
  final double zoom;
  MusePainter(
    this.frame, {
    this.background = const Color(0xffeee7fa),
    this.zoom = 1,
  });
  void _draw(Canvas c, SpriteLayer layer, {bool mask = false}) {
    c.save();
    c.transform(layer.matrix.matrix);
    final w = layer.image.width.toDouble(),
        h = layer.image.height.toDouble(),
        paint = Paint()..filterQuality = FilterQuality.medium;
    if (!mask) {
      paint.colorFilter = ColorFilter.mode(layer.color, BlendMode.modulate);
    }
    c.drawImageRect(
      layer.image,
      Rect.fromLTWH(0, 0, w, h),
      Rect.fromLTWH(-w / 2, -h / 2, w, h),
      paint,
    );
    c.restore();
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = background);
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.translate(size.width / 2, size.height / 2);
    final scale =
        math.min(size.width / (1200 * 900 / 1100), size.height / 1200) * zoom;
    canvas.scale(scale);
    final bounds = Rect.fromCenter(
      center: Offset.zero,
      width: size.width / scale,
      height: size.height / scale,
    );
    for (final l in frame.layers) {
      if (l.mask == null) {
        _draw(canvas, l);
      } else {
        canvas.saveLayer(bounds, Paint());
        _draw(canvas, l);
        canvas.saveLayer(bounds, Paint()..blendMode = BlendMode.dstIn);
        _draw(canvas, l.mask!, mask: true);
        canvas.restore();
        canvas.restore();
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(MusePainter old) =>
      frame != old.frame || background != old.background || zoom != old.zoom;
  Future<Uint8List> png() async {
    final recorder = ui.PictureRecorder();
    paint(Canvas(recorder), const Size(900, 1100));
    final picture = recorder.endRecording(),
        image = await picture.toImage(900, 1100);
    picture.dispose();
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }
}

class CharacterView extends StatefulWidget {
  final Artwork artwork;
  final Json data;
  final bool studio;
  final int revision;
  final double zoom;
  const CharacterView({
    super.key,
    required this.artwork,
    required this.data,
    required this.revision,
    this.studio = false,
    this.zoom = 1,
  });
  @override
  State<CharacterView> createState() => _CharacterViewState();
}

class _CharacterViewState extends State<CharacterView> {
  MuseFrame? frame;
  String? error;
  int generation = 0;
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void didUpdateWidget(CharacterView old) {
    super.didUpdateWidget(old);
    if (old.revision != widget.revision || old.studio != widget.studio) load();
  }

  Future<void> load() async {
    final token = ++generation;
    try {
      final next = await widget.artwork.build(
        clone(widget.data),
        studio: widget.studio,
      );
      if (!mounted || token != generation) return;
      setState(() {
        frame = next;
        error = null;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && token == generation) widget.artwork.trim(next.keys);
      });
    } catch (e) {
      if (mounted && token == generation) setState(() => error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (error != null) {
      return Center(child: Text('Artwork could not load: $error'));
    }
    if (frame == null) return const Center(child: CircularProgressIndicator());
    return CustomPaint(
      painter: MusePainter(
        frame!,
        zoom: widget.zoom,
        background: widget.studio
            ? museColor(widget.data['background'])
            : const Color(0xffeee7fa),
      ),
      child: const SizedBox.expand(),
    );
  }
}
