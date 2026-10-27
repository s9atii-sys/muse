import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mini_muses/artwork.dart';
import 'package:mini_muses/core.dart';
import 'fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('all presets render and studio keeps actor ordering', () async {
    final db = await fixture(),
        dir = await Directory.systemTemp.createTemp('muse-render-'),
        store = await MuseStore.open(db, directory: dir),
        art = Artwork(db, store);
    await Directory('test-output').create();
    for (final e in db.presets.entries) {
      final data = clone(obj(e.value));
      store.normalize(data);
      final frame = await art.build(data);
      expect(frame.layers.length, greaterThan(20), reason: e.key);
      final bytes = await MusePainter(
        frame,
        background: Colors.transparent,
      ).png();
      expect(bytes.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
      await File('test-output/${e.key}.png').writeAsBytes(bytes);
      art.trim(frame.keys);
    }
    final first = clone(obj(db.presets.values.first)),
        second = clone(obj(db.presets.values.elementAt(1))),
        one = await art.build(first),
        two = await art.build(second),
        scene = await art.build({
          'actors': [
            {'character': first, 'scale': .65, 'x': -160, 'y': 50},
            {'character': second, 'scale': .65, 'x': 160, 'y': 50},
          ],
        }, studio: true);
    expect(scene.layers.length, one.layers.length + two.layers.length);
    expect(
      scene.layers.take(one.layers.length).map((x) => x.uid),
      one.layers.map((x) => x.uid),
    );
    await File(
      'test-output/Studio.png',
    ).writeAsBytes(await MusePainter(scene).png());
    art.dispose();
    await store.save();
    store.dispose();
    await dir.delete(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 5)));
}
