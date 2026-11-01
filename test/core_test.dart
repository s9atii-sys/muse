import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:mini_muses/core.dart';
import 'package:mini_muses/ads.dart';
import 'fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MuseData db;
  late Directory dir;
  late MuseStore store;
  setUpAll(() async {
    db = await fixture();
  });
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('muse-test-');
    store = await MuseStore.open(db, directory: dir);
  });
  tearDown(() async {
    await store.save();
    store.dispose();
    await dir.delete(recursive: true);
  });
  test('catalog, presets and poses retained', () {
    expect(db.catalog.length, 92);
    expect(db.catalog.values.fold<int>(0, (n, v) => n + arr(v).length), 4942);
    expect(db.presets.length, 10);
    expect(obj(db.constants['POSE_DEFS']).length, 34);
    expect(db.art.length, 29186);
    expect(db.thumbs.length, 28463);
  });
  test('equip, undo, redo and saved slot round trip', () async {
    final before = jsonEncode(store.character),
        asset = obj(arr(db.catalog['Front Hair']).first),
        id = store.equip('Front Hair', asset);
    expect(store.item(id)!['prefix'], asset['prefix']);
    store.undo();
    expect(jsonEncode(store.character), before);
    store.redo();
    expect(store.item(id)!['prefix'], asset['prefix']);
    store.edit(() => store.character['profile_name'] = 'Saved one');
    store.loadSlot(2);
    store.edit(() => store.character['profile_name'] = 'Saved two');
    store.loadSlot(1);
    expect(store.character['profile_name'], 'Saved one');
    await store.save();
    final reopened = await MuseStore.open(db, directory: dir);
    expect(reopened.character['profile_name'], 'Saved one');
    reopened.loadSlot(2);
    expect(reopened.character['profile_name'], 'Saved two');
    await reopened.save();
    reopened.dispose();
  });
  test('legacy gzip and MM2 import', () {
    store.edit(() => store.character['profile_name'] = 'Code round trip');
    final before = jsonEncode(store.character), code = store.exportCode();
    store.replace(db.defaultCharacter());
    store.importCode(code);
    expect(jsonEncode(store.character), before);
    final first = obj(store.items.first),
        mm = {
          'profile_name': 'MM2 import',
          'i': [
            {
              'u': first['unique_id'],
              'prefix': first['prefix'],
              'c1': 'abcdef12',
            },
          ],
        };
    final text =
        'MM2.${base64UrlEncode(zlib.encode(utf8.encode(jsonEncode(mm)))).replaceAll('=', '')}';
    store.importCode(text);
    expect(store.character['profile_name'], 'MM2 import');
    expect(store.items.first['c1'], 'abcdef12');
  });
  test('invalid and oversized imports leave character intact', () {
    final before = jsonEncode(store.character);
    expect(
      () => store.importCode('not a character'),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => store.importCode(
        '{"items":[{"base_type":"Head","prefix":"user://custom/../../secret"}]}',
      ),
      throwsA(isA<FormatException>()),
    );
    final bomb = base64Encode(gzip.encode(utf8.encode('x' * 4000001)));
    expect(() => store.importCode(bomb), throwsA(isA<FormatException>()));
    expect(jsonEncode(store.character), before);
  });
  test('linked colors, duplicate and remove', () {
    final a = str(store.items[0]['unique_id']),
        b = str(store.items[1]['unique_id']);
    store.edit(() {
      store.character['linked_groups'] = [
        [a, b],
      ];
      store.item(a)!['c1'] = '12345678';
      store.copyLinked(a);
    });
    expect(store.item(b)!['c1'], '12345678');
    final count = store.items.length;
    store.duplicate(a);
    expect(store.items.length, count + 1);
    store.remove(str(store.items.last['unique_id']));
    expect(store.items.length, count);
  });
  test('poses and studio snapshots do not alias active character', () {
    store.applyPose(obj(obj(db.constants['POSE_DEFS']).values.first));
    expect(store.capturePose(), isNotEmpty);
    final copy = clone(store.character);
    store.scenes.add({
      'name': 'Scene',
      'actors': [
        {'character': copy},
      ],
    });
    store.edit(() => store.character['profile_name'] = 'Changed');
    expect(copy['profile_name'], isNot('Changed'));
  });
  test('CAS ad clock first/repeat thresholds, pause, overlap and earned reward', () {
    final c = AdClock();
    expect(c.interstitialEligible, false);
    c.tick(9);
    expect(c.interstitialEligible, false);
    c.tick(1);
    expect(c.interstitialEligible, true);
    c.tick(50);
    expect(c.rewardEligible, true);
    c.start();
    c.tick(30);
    expect(c.sinceReward, 60);
    expect(c.rewardEligible, false);
    c.finish(countInterstitial: true);
    expect(c.adFree, 0);
    expect(c.sinceInterstitial, 0);
    c.tick(29);
    expect(c.interstitialEligible, false);
    c.tick(1);
    expect(c.interstitialEligible, true);
    c.start();
    c.earned();
    c.finish();
    expect(c.adFree, 120);
    expect(c.rewardEligible, false);
    c.tick(119);
    expect(c.interstitialEligible, false);
    c.tick(1);
    expect(c.interstitialEligible, true);
    expect(c.rewardEligible, true);
  });
}
