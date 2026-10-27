import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

typedef Json = Map<String, dynamic>;
Json obj(dynamic x) =>
    x is Map ? Map<String, dynamic>.from(x) : <String, dynamic>{};
List<dynamic> arr(dynamic x) => x is List ? x : <dynamic>[];
String str(dynamic x, [String fallback = '']) =>
    x == null ? fallback : x.toString();
double numv(dynamic x, [double fallback = 0]) =>
    x is num ? x.toDouble() : double.tryParse(str(x)) ?? fallback;
bool flag(dynamic x, [bool fallback = false]) => x is bool ? x : fallback;
Json clone(Json value) => obj(jsonDecode(jsonEncode(value)));
const colorKeys = ['c1', 'c2', 'c3', 'c4', 'c5', 'c6', 'c7', 'c8', 'c_line'];
String colorHex(dynamic x, [String fallback = 'ffffffff']) {
  if (x is List && x.length >= 3) {
    return List.generate(
      4,
      (i) => (i < x.length ? (numv(x[i]) * 255).round().clamp(0, 255) : 255)
          .toRadixString(16)
          .padLeft(2, '0'),
    ).join();
  }
  return str(x, fallback);
}

class MuseData {
  final Json root, art, thumbs;
  final Map<String, Json> templates = {};
  final Map<String, List<Json>> layers = {};
  final Map<String, String> thumbnail = {};
  MuseData(this.root, this.art, this.thumbs) {
    for (final raw in arr(root['rig'])) {
      final n = obj(raw), name = str(raw['name']), parent = str(raw['parent']);
      n['path'] = parent == '.' ? name : '$parent/$name';
      if (n['type'] == 'Node2D' && name != 'Character') templates[name] = n;
      if (n['type'] == 'Sprite2D') (layers[parent] ??= []).add(n);
    }
    for (final key in thumbs.keys) {
      thumbnail.putIfAbsent(
        key.replaceFirst(RegExp(r'_(?:c[1-8]|line)\.png$'), ''),
        () => key,
      );
    }
  }
  Json get constants => obj(root['constants']);
  Json get catalog => obj(root['catalog']);
  Json get presets => obj(constants['premade_presets']);
  Json defaultCharacter() => clone(obj(constants['INTERN_BASE']));
  double z(String type) =>
      numv(obj(obj(root['render_order'])['types'])[type], 100);
  String resolve(String prefix, String layer, [bool chest = false]) {
    final suffix = layer == 'lineart' ? '_line.png' : '_$layer.png';
    for (final path in [
      '$prefix${chest ? '_chest' : '_flat'}$suffix',
      '$prefix$suffix',
    ]) {
      if (art.containsKey(path)) return path;
    }
    return prefix.startsWith('user://') && layer == 'c1'
        ? '${prefix}_c1.png'
        : '';
  }

  static Future<MuseData> load() async {
    final texts = await Future.wait(
      [
        'database',
        'art-index',
        'thumb-index',
      ].map((n) => rootBundle.loadString('assets/muse/$n.json')),
    );
    final maps = await compute(_parse, texts);
    return MuseData(maps[0], maps[1], maps[2]);
  }

  static List<Json> _parse(List<String> texts) =>
      texts.map((s) => obj(jsonDecode(s))).toList();
}

class MuseStore extends ChangeNotifier {
  final MuseData db;
  final Directory folder;
  Json character = {}, settings = {}, poses = {};
  List<dynamic> wardrobe = [],
      presets = [],
      customAssets = [],
      scenes = [],
      recent = [];
  final Map<int, Json> slots = {};
  final List<String> _undo = [], _redo = [];
  Future<void> _writes = Future.value();
  int slot = 1, revision = 0;
  String? saveError;
  MuseStore(this.db, this.folder);
  static Future<MuseStore> open(MuseData db, {Directory? directory}) async {
    final dir =
        directory ??
        Directory(
          '${(await getApplicationSupportDirectory()).path}/MiniMusesFlutter',
        );
    await dir.create(recursive: true);
    final s = MuseStore(db, dir);
    await s._load();
    return s;
  }

  Future<dynamic> _read(String name, dynamic fallback) async {
    for (final suffix in ['', '.backup']) {
      try {
        final f = File('${folder.path}/$name$suffix');
        if (await f.exists()) return jsonDecode(await f.readAsString());
      } catch (_) {
        saveError =
            'A saved file was damaged. A backup was used where available.';
      }
    }
    return fallback;
  }

  Future<void> _load() async {
    final data = obj(await _read('library.json', {}));
    settings = obj(data['settings']);
    poses = obj(data['poses']);
    wardrobe = arr(data['wardrobe']);
    presets = arr(data['presets']);
    customAssets = arr(data['customAssets']);
    scenes = arr(data['scenes']);
    recent = arr(data['recent']);
    for (final e in obj(data['slots']).entries) {
      final n = int.tryParse(e.key);
      if (n != null && n >= 1 && n <= 200) slots[n] = obj(e.value);
    }
    slot = numv(settings['slot'], 1).round().clamp(1, 200);
    character = peek(slot);
    normalize(character);
  }

  Json peek(int n) {
    if (slots[n] != null) return clone(slots[n]!);
    final starter = str(obj(db.constants['STARTER_SLOTS'])['$n']);
    return db.presets[starter] is Map
        ? clone(obj(db.presets[starter]))
        : db.defaultCharacter();
  }

  List<dynamic> get items => arr(character['items']);
  Json? item(String id) {
    for (final i in items) {
      if (i['unique_id'] == id) return i as Json;
    }
    return null;
  }

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;
  void snapshot() {
    _undo.add(jsonEncode(character));
    if (_undo.length > 50) _undo.removeAt(0);
    _redo.clear();
  }

  void edit(void Function() action, {bool undo = true}) {
    if (undo) snapshot();
    action();
    save();
    revision++;
    notifyListeners();
  }

  void undo() {
    if (!canUndo) return;
    _redo.add(jsonEncode(character));
    character = obj(jsonDecode(_undo.removeLast()));
    save();
    revision++;
    notifyListeners();
  }

  void redo() {
    if (!canRedo) return;
    _undo.add(jsonEncode(character));
    character = obj(jsonDecode(_redo.removeLast()));
    save();
    revision++;
    notifyListeners();
  }

  void loadSlot(int n) {
    slots[slot] = clone(character);
    slot = n.clamp(1, 200);
    character = peek(slot);
    normalize(character);
    _undo.clear();
    _redo.clear();
    save();
    revision++;
    notifyListeners();
  }

  void replace(Json data) => edit(() {
    character = clone(data);
    normalize(character);
  });
  Future<void> save() {
    slots[slot] = clone(character);
    settings['slot'] = slot;
    final text = jsonEncode({
      'schema': 1,
      'slots': slots.map((k, v) => MapEntry('$k', v)),
      'settings': settings,
      'poses': poses,
      'wardrobe': wardrobe,
      'presets': presets,
      'customAssets': customAssets,
      'scenes': scenes,
      'recent': recent,
    });
    _writes = _writes.then((_) async {
      try {
        final f = File('${folder.path}/library.json'),
            tmp = File('${folder.path}/library.json.tmp');
        await tmp.writeAsString(text, flush: true);
        if (await f.exists()) await f.copy('${f.path}.backup');
        await tmp.rename(f.path);
        saveError = null;
      } catch (e) {
        saveError = 'Saving failed: $e';
        notifyListeners();
      }
    });
    return _writes;
  }

  void normalize(Json data) {
    final items = arr(data['items']);
    data['items'] = items;
    final ren = obj(db.constants['LEGACY_TYPE_RENAMES']), ids = <String>{};
    for (final raw in items) {
      final it = raw as Json,
          type = str(raw['base_type']),
          newer = str(ren[type], type);
      it['base_type'] = newer;
      var id = str(it['unique_id'], '${newer}_1');
      if (newer != type && id.startsWith('${type}_')) {
        id = newer + id.substring(type.length);
      }
      var n = 1;
      while (ids.contains(id)) {
        id = '${newer}_${++n}';
      }
      it['unique_id'] = id;
      ids.add(id);
      it.putIfAbsent('scale_x', () => 1);
      it.putIfAbsent('scale_y', () => 1);
    }
    syncPieces(data);
    data['schema_version'] = 4;
  }

  String equip(String type, Json asset) {
    var id = '';
    edit(() {
      Json? it;
      for (final raw in items) {
        if (raw['base_type'] == type && str(raw['managed_by']).isEmpty) {
          it = raw as Json;
          break;
        }
      }
      if (it == null) {
        var n = 1;
        while (item('${type}_$n') != null) {
          n++;
        }
        it = {
          'unique_id': '${type}_$n',
          'base_type': type,
          'scale_x': 1,
          'scale_y': 1,
          'custom_z': items.isEmpty
              ? db.z(type)
              : items.map((i) => numv(i['custom_z'])).reduce(math.max) + 10,
        };
        items.add(it);
      }
      it['prefix'] = asset['prefix'];
      id = str(it['unique_id']);
      for (final c in colorKeys) {
        it.putIfAbsent(
          c,
          () => colorHex(
            obj(asset['colors'])[c],
            c == 'c_line' ? '2e1660ff' : 'b9a8e6ff',
          ),
        );
      }
      syncPieces(character);
    });
    return id;
  }

  void remove(String id) => edit(() {
    items.removeWhere((i) => i['unique_id'] == id || i['managed_by'] == id);
    final clips = obj(character['clips']);
    clips.removeWhere((k, v) => k == id || v == id);
    character['clips'] = clips;
  });
  void duplicate(String id) => edit(() {
    final it = item(id);
    if (it == null) return;
    final copy = clone(it);
    copy['unique_id'] =
        '${copy['base_type']}_${DateTime.now().microsecondsSinceEpoch}';
    copy.remove('managed_by');
    copy['custom_z'] = numv(copy['custom_z']) + 1;
    items.add(copy);
  });
  void copyLinked(String id) {
    final source = item(id);
    if (source == null) return;
    for (final group in arr(character['linked_groups'])) {
      if (!arr(group).contains(id)) continue;
      for (final key in arr(group)) {
        final target = item(str(key));
        if (target != null) {
          for (final c in colorKeys) {
            target[c] = source[c];
          }
        }
      }
    }
    syncPieces(character);
  }

  void syncPieces(Json data) {
    final items = arr(data['items']);
    for (final family in ['PANTS', 'SLEEVES', 'SOCKS', 'GLOVES']) {
      final own = obj(db.constants['${family}_OWNERSHIP']),
          suffix = obj(db.constants['${family}_PIECE_SUFFIX']);
      for (final raw
          in items.where((i) => own[i['base_type']] is List).toList()) {
        final marker = raw as Json,
            id = str(raw['unique_id']),
            pre = str(raw['prefix']);
        var offset = 0;
        for (final t in arr(own[marker['base_type']])) {
          final type = str(t);
          var pp = pre + str(suffix[type]);
          if (family == 'GLOVES' && type.contains('Hand')) {
            var handType = 1;
            for (final h in items) {
              if (h['base_type'] ==
                  (type.contains('Right') ? 'Hand Right' : 'Hand Left')) {
                handType =
                    int.tryParse(
                      RegExp(r'\d+$').firstMatch(str(h['prefix']))?.group(0) ??
                          '1',
                    ) ??
                    1;
              }
            }
            final variant = '${pre}_hand${math.max(handType, 1)}';
            if (db.resolve(variant, 'c1').isNotEmpty) pp = variant;
          }
          Json? piece;
          for (final i in items) {
            if (i['managed_by'] == id && i['base_type'] == type) {
              piece = i as Json;
              break;
            }
          }
          if (db.resolve(pp, 'c1').isEmpty &&
              db.resolve(pp, 'lineart').isEmpty) {
            if (piece != null) items.remove(piece);
            continue;
          }
          piece ??= {
            'unique_id':
                '${type}_${id.split('_').last}_${id.replaceAll(' ', '')}',
            'base_type': type,
            'managed_by': id,
            'scale_x': 1,
            'scale_y': 1,
            'custom_z': numv(marker['custom_z'], db.z(type)) + offset,
          };
          if (!items.contains(piece)) items.add(piece);
          piece['prefix'] = pp;
          for (final c in colorKeys) {
            piece[c] = marker[c] ?? (c == 'c_line' ? '2e1660ff' : 'ffffffff');
          }
          offset++;
        }
      }
    }
  }

  void applyPose(Json pose) => edit(() {
    for (final raw in arr(db.constants['POSE_LIMBS'])) {
      final it = item(str(raw));
      if (it == null) continue;
      final p = pose[raw], m = obj(p);
      it['rot'] = p is Map ? numv(m['rot']) : numv(p);
      for (final k in ['pos_x', 'pos_y']) {
        it[k] = numv(m[k]);
      }
      for (final k in ['flip_h', 'flip_v']) {
        it[k] = flag(m[k]);
      }
      if (m['z'] != null) it['custom_z'] = m['z'];
    }
  });
  Json capturePose() => {
    for (final id in arr(db.constants['POSE_LIMBS']))
      if (item(str(id)) != null)
        str(id): {
          for (final k in ['rot', 'pos_x', 'pos_y', 'flip_h', 'flip_v'])
            k: item(str(id))![k],
        },
  };
  String exportCode() =>
      base64Encode(gzip.encode(utf8.encode(jsonEncode(character))));
  void importCode(String code) {
    if (code.length > 6000000) {
      throw const FormatException('Code exceeds 6 MB.');
    }
    var text = code.trim();
    Json data;
    if (text.startsWith('{')) {
      data = obj(jsonDecode(text));
    } else {
      final mm = text.startsWith('MM2.');
      if (mm) {
        text = text.substring(4).replaceAll('-', '+').replaceAll('_', '/');
      }
      text = text.replaceAll(RegExp(r'\s'), '');
      text = text.padRight((text.length + 3) ~/ 4 * 4, '=');
      final output = BoundedBytes(4000000),
          sink = (mm ? ZLibDecoder() : gzip.decoder).startChunkedConversion(
            output,
          );
      sink.add(base64Decode(text));
      sink.close();
      data = obj(jsonDecode(utf8.decode(output.bytes)));
      if (mm) {
        final converted = <dynamic>[];
        for (final raw in arr(data['i'])) {
          final row = obj(raw), id = str(raw['u']);
          Json it = {};
          for (final base in arr(db.defaultCharacter()['items'])) {
            if (base['unique_id'] == id) it = clone(obj(base));
          }
          it.addAll(row);
          it.remove('u');
          it['unique_id'] = id;
          final cut = id.lastIndexOf('_');
          it['base_type'] = cut > 0 ? id.substring(0, cut) : id;
          final pre = str(it['prefix']);
          if (!pre.startsWith('res://') && !pre.startsWith('user://')) {
            it['prefix'] = 'res://sprites/$pre';
          }
          converted.add(it);
        }
        data.remove('i');
        data['items'] = converted;
      }
    }
    validateCharacter(data);
    replace(data);
    recent.insert(0, {
      'name': str(data['profile_name'], 'Imported'),
      'code': code,
    });
    if (recent.length > 30) recent.removeRange(30, recent.length);
    save();
  }

  void validateCharacter(Json data) {
    if (data['items'] is! List || arr(data['items']).length > 500) {
      throw const FormatException('Invalid character data.');
    }
    for (final raw in arr(data['items'])) {
      if (raw is! Map || str(raw['base_type']).trim().isEmpty) {
        throw const FormatException('An item is missing its type.');
      }
      final p = str(raw['prefix']);
      if (p.isNotEmpty && !p.startsWith('res://') && !p.startsWith('user://')) {
        throw const FormatException('Unsupported asset path.');
      }
      if (p.startsWith('user://')) localPath(p);
      for (final key in [
        'pos_x',
        'pos_y',
        'rot',
        'scale_x',
        'scale_y',
        'skew',
        'skew_v',
        'custom_z',
      ]) {
        final v = numv(raw[key]);
        if (!v.isFinite || v.abs() > 100000) {
          throw const FormatException('Invalid transform.');
        }
      }
    }
  }

  String localPath(String uri) {
    if (!RegExp(r'^user://custom/[A-Za-z0-9_-]+(?:_c1\.png)?$').hasMatch(uri)) {
      throw const FormatException('Invalid custom image path.');
    }
    return '${folder.path}/${uri.substring(7)}';
  }
}

class BoundedBytes implements Sink<List<int>> {
  final int limit;
  final List<int> bytes = [];
  BoundedBytes(this.limit);
  @override
  void add(List<int> data) {
    if (bytes.length + data.length > limit) {
      throw const FormatException('Decoded character exceeds 4 MB.');
    }
    bytes.addAll(data);
  }

  @override
  void close() {}
}
