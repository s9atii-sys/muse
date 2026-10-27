import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mini_muses/core.dart';
import 'package:mini_muses/main.dart';
import 'fixture.dart';

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 500; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 50));
    if (find.byType(CircularProgressIndicator).evaluate().isEmpty) {
      await tester.pump(const Duration(milliseconds: 400));
      return;
    }
  }
  throw StateError('The character preview did not finish loading.');
}

void main() {
  testWidgets('wardrobe, colors, slots, studio and responsive navigation', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      await (FontLoader(
        'Nunito',
      )..addFont(rootBundle.load('assets/muse/fonts/Nunito-Bold.ttf'))).load();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    });
    final db = await tester.runAsync(fixture);
    late Directory dir;
    late MuseStore store;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('muse-ui-');
      store = await MuseStore.open(db!, directory: dir);
    });
    final capture = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: capture,
        child: MiniMusesApp(store: store, enableServices: false),
      ),
    );
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 2)),
    );
    await settle(tester);
    expect(find.text('Dress your muse'), findsOneWidget);
    expect(tester.takeException(), isNull);
    final asset = obj(arr(db!.catalog['Front Hair']).first);
    await tester.tap(find.byKey(ValueKey('equip-${asset['prefix']}')));
    await settle(tester);
    expect(store.items.any((i) => i['prefix'] == asset['prefix']), true);
    await tester.tap(find.text('Colors').first);
    await settle(tester);
    expect(find.text('Layer colors'), findsOneWidget);
    await tester.tap(find.text('C1'));
    await settle(tester);
    expect(find.text('Color'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await settle(tester);
    await tester.tap(find.text('Layers').first);
    await settle(tester);
    expect(find.text('Layers & transforms'), findsOneWidget);
    await tester.tap(find.text('Slots').first);
    await settle(tester);
    await tester.tap(find.text('2').first);
    await settle(tester);
    expect(store.slot, 2);
    await tester.tap(find.text('Studio').first);
    await settle(tester);
    expect(find.text('Add character'), findsOneWidget);
    await tester.tap(find.text('Add character'));
    await settle(tester);
    await tester.tap(find.text('Save studio'));
    await settle(tester);
    await tester.enterText(find.byType(TextField).last, 'UI studio');
    await tester.tap(find.text('Save').last);
    await settle(tester);
    expect(store.scenes.last['name'], 'UI studio');
    expect(arr(store.scenes.last['actors']).length, 2);
    await tester.tap(find.text('Dress').first);
    await settle(tester);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 2)),
    );
    await settle(tester);
    await tester.runAsync(() async {
      final image =
              await (capture.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage(),
          bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory('test-output').create();
      await File(
        'test-output/Flutter-landscape.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
    tester.view.physicalSize = const Size(390, 844);
    await settle(tester);
    expect(tester.takeException(), isNull);
    await tester.runAsync(() async {
      final image =
              await (capture.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage(),
          bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(
        'test-output/Flutter-portrait.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await store.save();
      store.dispose();
      await dir.delete(recursive: true);
    });
  }, timeout: const Timeout(Duration(minutes: 5)));
}
