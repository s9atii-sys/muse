import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import 'core.dart';
import 'artwork.dart';
import 'ads.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MiniMusesApp());
}

class MiniMusesApp extends StatefulWidget {
  final MuseStore? store;
  final bool enableServices;
  const MiniMusesApp({super.key, this.store, this.enableServices = true});
  @override
  State<MiniMusesApp> createState() => _AppState();
}

class _AppState extends State<MiniMusesApp> {
  late Future<MuseStore> future;
  @override
  void initState() {
    super.initState();
    future = load();
  }

  Future<MuseStore> load() async =>
      widget.store ?? await MuseStore.open(await MuseData.load());
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'MiniMuses Play',
    theme: ThemeData(
      useMaterial3: true,
      fontFamily: 'Nunito',
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff7444aa)),
      scaffoldBackgroundColor: const Color(0xfff6f2fc),
      cardTheme: const CardThemeData(elevation: 0, margin: EdgeInsets.all(6)),
    ),
    home: FutureBuilder<MuseStore>(
      future: future,
      builder: (context, s) {
        if (s.hasData) {
          return MuseEditor(
            store: s.data!,
            enableServices: widget.enableServices,
          );
        }
        return Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.palette_outlined, size: 64),
                  const SizedBox(height: 16),
                  const Text(
                    'MINIMUSES / PLAY',
                    style: TextStyle(fontSize: 26),
                  ),
                  const SizedBox(height: 20),
                  if (s.hasError) ...[
                    Text('Could not load the project data.\n${s.error}'),
                    FilledButton(
                      onPressed: () => setState(() => future = load()),
                      child: const Text('Retry'),
                    ),
                  ] else ...[
                    const CircularProgressIndicator(),
                    const SizedBox(height: 14),
                    const Text('Opening your wardrobe…'),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    ),
  );
}

enum MuseTab { dress, layers, colors, poses, slots, studio, profile, settings }

const tabLabels = [
  'Dress',
  'Layers',
  'Colors',
  'Poses',
  'Slots',
  'Studio',
  'Profile',
  'Settings',
];

class MuseEditor extends StatefulWidget {
  final MuseStore store;
  final bool enableServices;
  const MuseEditor({
    super.key,
    required this.store,
    this.enableServices = true,
  });
  @override
  State<MuseEditor> createState() => _EditorState();
}

class _EditorState extends State<MuseEditor> with WidgetsBindingObserver {
  MuseStore get store => widget.store;
  MuseData get db => store.db;
  late final Artwork artwork;
  MuseAds? ads;
  AudioPlayer? music;
  MuseTab tab = MuseTab.dress;
  String category = 'Front Hair', selected = '', query = '';
  int page = 0, slotPage = 0, actor = 0, stageRevision = 0;
  double zoom = 1;
  bool exporting = false;
  Json stage = {
    'name': 'My studio',
    'background': 'eee7fa',
    'actors': <dynamic>[],
  };
  @override
  void initState() {
    super.initState();
    artwork = Artwork(db, store);
    store.addListener(changed);
    WidgetsBinding.instance.addObserver(this);
    if (!db.catalog.containsKey(category)) category = db.catalog.keys.first;
    startServices();
  }

  Future<void> startServices() async {
    final config = obj(
      jsonDecode(await rootBundle.loadString('assets/muse/ad-config.json')),
    );
    if (!mounted) return;
    ads = MuseAds(config);
    setState(() {});
    if (widget.enableServices) {
      music = AudioPlayer();
      unawaited(
        ads!.initialize().catchError((Object e) {
          toast('Ads unavailable: $e');
        }),
      );
      await playMusic();
    }
  }

  Future<void> playMusic() async {
    try {
      if (music == null) return;
      if (!flag(store.settings['music'], true)) {
        await music!.pause();
        return;
      }
      await music!.setReleaseMode(ReleaseMode.loop);
      await music!.setVolume(.3);
      final track = numv(store.settings['track'], 1).round().clamp(1, 4);
      await music!.play(AssetSource('muse/sound/track$track.m4a'));
    } catch (e) {
      toast('Music unavailable: $e');
    }
  }

  void changed() {
    if (mounted) setState(() {});
  }

  void toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 4)),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      store.save();
      music?.pause();
    } else if (flag(store.settings['music'], true)) {
      music?.resume();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    store.removeListener(changed);
    ads?.dispose();
    music?.dispose();
    artwork.dispose();
    super.dispose();
  }

  void navigate(MuseTab next) {
    if (tab == next) return;
    store.save();
    if (next == MuseTab.studio && arr(stage['actors']).isEmpty) addActor();
    setState(() {
      tab = next;
      page = 0;
    });
    ads?.naturalBreak();
  }

  Json? get chosen {
    var it = store.item(selected);
    if (it != null) return it;
    for (final raw in store.items) {
      if (raw['base_type'] == category) {
        selected = str(raw['unique_id']);
        return raw as Json;
      }
    }
    if (store.items.isEmpty) return null;
    it = store.items.first as Json;
    selected = str(it['unique_id']);
    return it;
  }

  void stageChange(void Function() fn) => setState(() {
    fn();
    stageRevision++;
  });
  Widget action(String text, IconData icon, VoidCallback? fn) =>
      OutlinedButton.icon(
        onPressed: fn,
        icon: Icon(icon, size: 18),
        label: Text(text),
      );
  Widget controls(List<Widget> children) => ListView(
    padding: const EdgeInsets.all(16),
    children: [...children, const SizedBox(height: 24)],
  );
  Widget heading(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Text(text, style: Theme.of(context).textTheme.titleLarge),
  );
  Widget step(
    String text,
    double value,
    double increment,
    void Function(double) change, {
    double? min,
    double? max,
  }) => Row(
    children: [
      Expanded(
        child: Text('$text  ${value.toStringAsFixed(increment < 1 ? 2 : 0)}'),
      ),
      IconButton(
        tooltip: 'Decrease $text',
        onPressed: () => change(
          (value - increment).clamp(min ?? -100000, max ?? 100000).toDouble(),
        ),
        icon: const Icon(Icons.remove_circle_outline),
      ),
      IconButton(
        tooltip: 'Increase $text',
        onPressed: () => change(
          (value + increment).clamp(min ?? -100000, max ?? 100000).toDouble(),
        ),
        icon: const Icon(Icons.add_circle_outline),
      ),
    ],
  );
  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width > 850;
    final preview = Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    tab == MuseTab.studio
                        ? str(stage['name'])
                        : str(store.character['profile_name'], 'Your muse'),
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  tooltip: 'Zoom out',
                  onPressed: () => setState(
                    () => zoom = (zoom - .15).clamp(.4, 3).toDouble(),
                  ),
                  icon: const Icon(Icons.zoom_out),
                ),
                TextButton(
                  onPressed: () => setState(() => zoom = 1),
                  child: const Text('Fit'),
                ),
                IconButton(
                  tooltip: 'Zoom in',
                  onPressed: () => setState(
                    () => zoom = (zoom + .15).clamp(.4, 3).toDouble(),
                  ),
                  icon: const Icon(Icons.zoom_in),
                ),
              ],
            ),
          ),
          Expanded(
            child: CharacterView(
              artwork: artwork,
              data: tab == MuseTab.studio ? stage : store.character,
              revision: store.revision + stageRevision,
              studio: tab == MuseTab.studio,
              zoom: zoom,
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  action(
                    exporting ? 'Exporting…' : 'Export PNG',
                    Icons.ios_share,
                    exporting ? null : exportImage,
                  ),
                  const SizedBox(width: 8),
                  action('Presets', Icons.face_retouching_natural, showPresets),
                  const SizedBox(width: 8),
                  action('Outfits', Icons.checkroom, showWardrobe),
                ],
              ),
            ),
          ),
        ],
      ),
    );
    return Scaffold(
      appBar: AppBar(
        title: const Text('MINIMUSES / PLAY', style: TextStyle(fontSize: 19)),
        actions: [
          IconButton(
            tooltip: 'Undo',
            onPressed: store.canUndo ? store.undo : null,
            icon: const Icon(Icons.undo),
          ),
          IconButton(
            tooltip: 'Redo',
            onPressed: store.canRedo ? store.redo : null,
            icon: const Icon(Icons.redo),
          ),
          IconButton(
            tooltip: 'Save character',
            onPressed: () async {
              await store.save();
              toast(store.saveError ?? 'Character saved.');
            },
            icon: const Icon(Icons.save_outlined),
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              switch (v) {
                case 'share':
                  shareCode();
                case 'import':
                  importCode();
                case 'image':
                  importImage();
                case 'recent':
                  recentCodes();
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'share',
                child: Text('Share character code'),
              ),
              PopupMenuItem(
                value: 'import',
                child: Text('Import character code'),
              ),
              PopupMenuItem(value: 'image', child: Text('Import custom image')),
              PopupMenuItem(value: 'recent', child: Text('Recent imports')),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                child: Row(
                  children: [
                    for (final t in MuseTab.values)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 3),
                        child: ChoiceChip(
                          label: Text(tabLabels[t.index]),
                          selected: tab == t,
                          onSelected: (_) => navigate(t),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (store.saveError != null)
              MaterialBanner(
                content: Text(store.saveError!),
                actions: [
                  TextButton(
                    onPressed: () => store.save(),
                    child: const Text('Retry save'),
                  ),
                ],
              ),
            Expanded(
              child: wide
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(flex: 4, child: preview),
                        Expanded(flex: 5, child: panel()),
                      ],
                    )
                  : LayoutBuilder(
                      builder: (context, c) {
                        if (c.maxHeight < 360) return panel();
                        return Column(
                          children: [
                            SizedBox(
                              height: (c.maxHeight * .46)
                                  .clamp(180, 360)
                                  .toDouble(),
                              child: preview,
                            ),
                            Expanded(child: panel()),
                          ],
                        );
                      },
                    ),
            ),
            rewardBar(),
          ],
        ),
      ),
    );
  }

  Widget rewardBar() {
    final service = ads;
    if (service == null) return const SizedBox(height: 30);
    return AnimatedBuilder(
      animation: service,
      builder: (context, _) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        child: Row(
          children: [
            Expanded(
              child: Text(
                'Slot ${store.slot} / 200 · ${store.items.length} layers',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
            Flexible(
              flex: 2,
              child: TextButton.icon(
                onPressed: service.rewardReady
                    ? () => service.showReward()
                    : null,
                icon: const Icon(Icons.card_giftcard, size: 18),
                label: Text(
                  service.clock.adFree > 0
                      ? 'Ad-free: ${service.clock.adFree.ceil()}s'
                      : service.rewardReady
                      ? 'Watch ad · 2 min ad-free'
                      : service.clock.rewardEligible
                      ? 'Reward ad unavailable'
                      : 'Reward offer in ${(service.clock.rewardSeconds - service.clock.sinceReward).clamp(0, 3600).ceil()}s',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget panel() => switch (tab) {
    MuseTab.dress => dress(),
    MuseTab.layers => layers(),
    MuseTab.colors => colors(),
    MuseTab.poses => poses(),
    MuseTab.slots => slots(),
    MuseTab.studio => studio(),
    MuseTab.profile => profile(),
    MuseTab.settings => settings(),
  };
  Widget dress() {
    final all =
            [
                  ...arr(db.catalog[category]),
                  ...store.customAssets.where((a) => a['type'] == category),
                ]
                .map(obj)
                .where(
                  (a) => '${a['name']} ${a['prefix']}'.toLowerCase().contains(
                    query.toLowerCase(),
                  ),
                )
                .toList(),
        pages = (all.length / 12).ceil().clamp(1, 10000);
    page = page.clamp(0, pages - 1);
    final visible = all.skip(page * 12).take(12).toList();
    return controls([
      heading('Dress your muse'),
      DropdownButtonFormField<String>(
        key: ValueKey(category),
        initialValue: category,
        isExpanded: true,
        decoration: const InputDecoration(
          labelText: 'Category',
          border: OutlineInputBorder(),
        ),
        items: db.catalog.keys
            .map((n) => DropdownMenuItem(value: n, child: Text(n)))
            .toList(),
        onChanged: (v) => setState(() {
          category = v!;
          page = 0;
          query = '';
        }),
      ),
      const SizedBox(height: 10),
      TextField(
        key: ValueKey('search-$category'),
        decoration: const InputDecoration(
          prefixIcon: Icon(Icons.search),
          hintText: 'Search this category',
          border: OutlineInputBorder(),
        ),
        onChanged: (v) => setState(() {
          query = v;
          page = 0;
        }),
      ),
      const SizedBox(height: 12),
      if (visible.isEmpty)
        const Padding(
          padding: EdgeInsets.all(24),
          child: Text('No matching items.'),
        ),
      LayoutBuilder(
        builder: (context, c) => GridView.count(
          crossAxisCount: c.maxWidth > 560 ? 4 : 3,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          childAspectRatio: .9,
          children: visible.map(catalogCard).toList(),
        ),
      ),
      Row(
        children: [
          IconButton(
            tooltip: 'Previous page',
            onPressed: page > 0 ? () => setState(() => page--) : null,
            icon: const Icon(Icons.chevron_left),
          ),
          Expanded(
            child: Text(
              '${all.length} items · ${page + 1} / $pages',
              textAlign: TextAlign.center,
            ),
          ),
          IconButton(
            tooltip: 'Next page',
            onPressed: page < pages - 1 ? () => setState(() => page++) : null,
            icon: const Icon(Icons.chevron_right),
          ),
        ],
      ),
    ]);
  }

  Widget catalogCard(Json asset) {
    final pre = str(asset['prefix']),
        key = db.thumbnail[pre],
        thumb = key == null ? null : str(obj(db.thumbs[key])['asset']),
        equipped = store.items.any((i) => i['prefix'] == pre);
    Widget image;
    if (pre.startsWith('user://')) {
      image = Image.file(
        File(store.localPath('${pre}_c1.png')),
        fit: BoxFit.contain,
        errorBuilder: (_, e, s) => const Icon(Icons.broken_image_outlined),
      );
    } else if (thumb != null && thumb.isNotEmpty) {
      image = Image.asset(
        thumb,
        fit: BoxFit.contain,
        color: const Color(0xff8c67b4),
        colorBlendMode: BlendMode.modulate,
        cacheWidth: 180,
        errorBuilder: (_, e, s) => const Icon(Icons.checkroom),
      );
    } else {
      image = const Icon(Icons.checkroom, size: 34);
    }
    return Material(
      color: equipped ? const Color(0xffdfc9f4) : Colors.white,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        key: ValueKey('equip-$pre'),
        borderRadius: BorderRadius.circular(14),
        onTap: () {
          selected = store.equip(category, asset);
          toast('Equipped ${asset['name']}');
        },
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            children: [
              Expanded(child: image),
              const SizedBox(height: 4),
              Text(
                str(asset['name']),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget itemPicker() {
    final it = chosen;
    return DropdownButtonFormField<String>(
      key: ValueKey('item-$selected-${store.items.length}'),
      initialValue: it?['unique_id'],
      isExpanded: true,
      decoration: const InputDecoration(
        labelText: 'Selected layer',
        border: OutlineInputBorder(),
      ),
      items: store.items
          .map(
            (i) => DropdownMenuItem<String>(
              value: str(i['unique_id']),
              child: Text(str(i['unique_id']), overflow: TextOverflow.ellipsis),
            ),
          )
          .toList(),
      onChanged: (v) => setState(() => selected = v!),
    );
  }

  Widget layers() {
    final it = chosen;
    if (it == null) return const Center(child: Text('Equip an item first.'));
    final fields = [
      ('pos_x', 'Horizontal', 5.0),
      ('pos_y', 'Vertical', 5.0),
      ('rot', 'Rotation', 5.0),
      ('scale_x', 'Width', .05),
      ('scale_y', 'Height', .05),
      ('custom_z', 'Layer order', 1.0),
      ('skew', 'Skew', .05),
    ];
    return controls([
      heading('Layers & transforms'),
      itemPicker(),
      const SizedBox(height: 12),
      for (final f in fields)
        step(
          f.$2,
          numv(it[f.$1], f.$1.startsWith('scale') ? 1 : 0),
          f.$3,
          (v) => store.edit(() {
            it[f.$1] = v;
            store.syncPieces(store.character);
          }),
          min: f.$1.startsWith('scale') ? 0.05 : null,
          max: f.$1.startsWith('scale') ? 6 : null,
        ),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          action(
            'Flip H',
            Icons.flip,
            () => store.edit(() => it['flip_h'] = !flag(it['flip_h'])),
          ),
          action(
            'Flip V',
            Icons.flip_camera_android,
            () => store.edit(() => it['flip_v'] = !flag(it['flip_v'])),
          ),
          action(
            flag(it['hidden']) ? 'Show' : 'Hide',
            Icons.visibility_outlined,
            () => store.edit(() => it['hidden'] = !flag(it['hidden'])),
          ),
          action('Duplicate', Icons.copy, () => store.duplicate(selected)),
          action(
            'Remove',
            Icons.delete_outline,
            () => confirm('Remove this layer?', () => store.remove(selected)),
          ),
          action('Clip to layer', Icons.crop, () => chooseLink(it, true)),
          action(
            'Reset transform',
            Icons.restart_alt,
            () => store.edit(() {
              for (final k in ['pos_x', 'pos_y', 'rot', 'skew', 'skew_v']) {
                it[k] = 0;
              }
              it['scale_x'] = 1;
              it['scale_y'] = 1;
              it['flip_h'] = false;
              it['flip_v'] = false;
            }),
          ),
        ],
      ),
    ]);
  }

  Widget colors() {
    final it = chosen;
    if (it == null) return const Center(child: Text('Equip an item first.'));
    return controls([
      heading('Layer colors'),
      itemPicker(),
      const SizedBox(height: 12),
      for (final key in colorKeys)
        ListTile(
          leading: CircleAvatar(backgroundColor: museColor(it[key])),
          title: Text(key == 'c_line' ? 'Line art' : key.toUpperCase()),
          subtitle: Text(str(it[key], 'ffffffff')),
          trailing: const Icon(Icons.colorize),
          onTap: () => pickColor(
            str(it[key], 'ffffffff'),
            (hex) => store.edit(() {
              it[key] = hex;
              store.copyLinked(selected);
            }),
          ),
        ),
      action(
        'Link colors with another layer',
        Icons.link,
        () => chooseLink(it, false),
      ),
      const Divider(),
      step(
        'Character tint',
        numv(store.character['tint_strength']),
        .1,
        (v) => store.edit(() => store.character['tint_strength'] = v),
        min: 0,
        max: 1,
      ),
      action(
        'Tint color',
        Icons.palette_outlined,
        () => pickColor(
          str(store.character['tint_colour'], 'ffffff'),
          (hex) => store.edit(() => store.character['tint_colour'] = hex),
        ),
      ),
    ]);
  }

  Widget poses() {
    final all = {...obj(db.constants['POSE_DEFS']), ...store.poses};
    return controls([
      heading('Poses'),
      action('Save current pose', Icons.add, () async {
        final name = await prompt('Pose name', 'My pose');
        if (name != null) {
          store.edit(
            () => store.poses[name] = store.capturePose(),
            undo: false,
          );
        }
      }),
      const SizedBox(height: 12),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final e in all.entries)
            ActionChip(
              label: Text(e.key),
              onPressed: () => store.applyPose(obj(e.value)),
            ),
        ],
      ),
    ]);
  }

  Widget slots() => controls([
    heading('Character slots'),
    const Text('Changes are saved automatically in the selected slot.'),
    const SizedBox(height: 12),
    GridView.count(
      crossAxisCount: 4,
      childAspectRatio: 1.35,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      children: [
        for (int i = slotPage * 20 + 1; i <= slotPage * 20 + 20; i++)
          Card(
            color: i == store.slot ? const Color(0xffdfc9f4) : Colors.white,
            child: InkWell(
              onTap: () {
                selected = '';
                store.loadSlot(i);
              },
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text('$i', style: const TextStyle(fontSize: 20)),
                    Text(
                      str(store.peek(i)['profile_name'], 'Empty'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 10),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    ),
    Row(
      children: [
        IconButton(
          tooltip: 'Previous slots',
          onPressed: slotPage > 0 ? () => setState(() => slotPage--) : null,
          icon: const Icon(Icons.chevron_left),
        ),
        Expanded(
          child: Text('${slotPage + 1} / 10', textAlign: TextAlign.center),
        ),
        IconButton(
          tooltip: 'Next slots',
          onPressed: slotPage < 9 ? () => setState(() => slotPage++) : null,
          icon: const Icon(Icons.chevron_right),
        ),
      ],
    ),
  ]);
  void addActor() {
    if (arr(stage['actors']).length >= 12) {
      toast('Maximum 12 actors.');
      return;
    }
    stageChange(() {
      arr(stage['actors']).add({
        'character': clone(store.character),
        'x': 0,
        'y': 50,
        'scale': .65,
        'rotation': 0,
      });
      actor = arr(stage['actors']).length - 1;
    });
  }

  Widget studio() {
    final actors = arr(stage['actors']);
    actor = actor.clamp(0, (actors.length - 1).clamp(0, 12));
    final current = actors.isEmpty ? null : actors[actor] as Json;
    return controls([
      heading('Studio'),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          action('Add character', Icons.person_add_alt, addActor),
          action('Save studio', Icons.save_outlined, () async {
            final name = await prompt('Studio name', str(stage['name']));
            if (name == null) return;
            stage['name'] = name;
            store.edit(() {
              store.scenes.removeWhere((s) => s['name'] == name);
              store.scenes.add(clone(stage));
            }, undo: false);
            toast('Studio saved.');
          }),
          action('Open studio', Icons.folder_open, showStudios),
        ],
      ),
      const SizedBox(height: 12),
      if (current != null) ...[
        DropdownButtonFormField<int>(
          key: ValueKey('actor-$actor-${actors.length}'),
          initialValue: actor,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: 'Actor',
            border: OutlineInputBorder(),
          ),
          items: [
            for (int i = 0; i < actors.length; i++)
              DropdownMenuItem(
                value: i,
                child: Text(
                  '${i + 1} · ${obj(actors[i]['character'])['profile_name']}',
                ),
              ),
          ],
          onChanged: (v) => setState(() => actor = v!),
        ),
        for (final row in [
          ('x', 'Horizontal', 20.0),
          ('y', 'Vertical', 20.0),
          ('scale', 'Size', .05),
          ('rotation', 'Rotation', 5.0),
        ])
          step(
            row.$2,
            numv(current[row.$1]),
            row.$3,
            (v) => stageChange(() => current[row.$1] = v),
            min: row.$1 == 'scale' ? 0.1 : null,
            max: row.$1 == 'scale' ? 3 : null,
          ),
        Wrap(
          spacing: 8,
          children: [
            action(
              'Remove actor',
              Icons.person_remove_outlined,
              () => stageChange(() => actors.removeAt(actor)),
            ),
            action(
              'Bring to front',
              Icons.flip_to_front,
              () => stageChange(() {
                final a = actors.removeAt(actor);
                actors.add(a);
                actor = actors.length - 1;
              }),
            ),
          ],
        ),
      ],
      const Divider(),
      action(
        'Background color',
        Icons.palette_outlined,
        () => pickColor(
          str(stage['background']),
          (hex) => stageChange(() => stage['background'] = hex),
        ),
      ),
      action(
        'Clear studio',
        Icons.delete_sweep_outlined,
        () => confirm(
          'Remove all actors?',
          () => stageChange(() => stage['actors'] = <dynamic>[]),
        ),
      ),
    ]);
  }

  Widget profile() => controls([
    heading('Character profile'),
    for (final row in [
      ('profile_name', 'Name'),
      ('profile_pronouns', 'Pronouns'),
      ('profile_age', 'Age'),
      ('profile_gender', 'Gender'),
      ('profile_birthday', 'Birthday'),
      ('profile_creator', 'Creator'),
      ('profile_personality', 'Personality'),
      ('profile_likes', 'Likes'),
      ('profile_dislikes', 'Dislikes'),
      ('profile_fav_muse', 'Favorite muse'),
      ('profile_bio', 'Biography'),
    ])
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextFormField(
          key: ValueKey('${store.slot}-${row.$1}-${store.revision}'),
          initialValue: str(store.character[row.$1]),
          minLines: row.$1 == 'profile_bio' ? 3 : 1,
          maxLines: row.$1 == 'profile_bio' ? 5 : 1,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(
            labelText: row.$2,
            border: const OutlineInputBorder(),
          ),
          onTap: () => setState(store.snapshot),
          onChanged: (v) {
            store.character[row.$1] = v;
            store.save();
          },
          onFieldSubmitted: (v) =>
              store.edit(() => store.character[row.$1] = v, undo: false),
        ),
      ),
  ]);
  Widget settings() => controls([
    heading('Settings & credits'),
    SwitchListTile(
      title: const Text('Music'),
      value: flag(store.settings['music'], true),
      onChanged: (v) {
        store.edit(() => store.settings['music'] = v, undo: false);
        playMusic();
      },
    ),
    action(
      'Change track (${numv(store.settings['track'], 1).round()})',
      Icons.music_note,
      () {
        store.edit(
          () => store.settings['track'] =
              numv(store.settings['track'], 1).round() % 4 + 1,
          undo: false,
        );
        playMusic();
      },
    ),
    step(
      'Character height',
      numv(store.character['height_scale'], .95),
      .05,
      (v) => store.edit(() => store.character['height_scale'] = v),
      min: .3,
      max: 2,
    ),
    SwitchListTile(
      title: const Text('Chest variant'),
      value: flag(store.character['is_chest_active']),
      onChanged: (v) =>
          store.edit(() => store.character['is_chest_active'] = v),
    ),
    const Divider(),
    if (ads != null)
      AnimatedBuilder(
        animation: ads!,
        builder: (context, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(ads!.status),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                action(
                  'Privacy choices',
                  Icons.privacy_tip_outlined,
                  ads!.privacyRequired ? () => ads!.privacyOptions() : null,
                ),
                action('Retry ads', Icons.refresh, () => ads!.retry()),
              ],
            ),
          ],
        ),
      ),
    const Padding(
      padding: EdgeInsets.symmetric(vertical: 16),
      child: Text(
        'Interstitials become eligible after 15 seconds and display at screen transitions. An optional reward offer becomes available after 60 seconds. Completing it grants 2 minutes without interstitials.',
      ),
    ),
    action('Original creators & supporters', Icons.favorite_border, credits),
    const SizedBox(height: 12),
    const Text(
      'Saves stay on this device. Export a character code for a backup. Imported custom images stay local and are not included in codes.',
    ),
  ]);
  Future<String?> prompt(
    String title,
    String value, {
    bool multi = false,
  }) async {
    final c = TextEditingController(text: value);
    final route = DialogRoute<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 500,
          child: TextField(
            controller: c,
            autofocus: true,
            minLines: multi ? 5 : 1,
            maxLines: multi ? 10 : 1,
            decoration: const InputDecoration(border: OutlineInputBorder()),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final s = c.text.trim();
              if (s.isNotEmpty) Navigator.pop(ctx, s);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    final result = await Navigator.of(context).push(route);
    await route.completed;
    c.dispose();
    return result;
  }

  Future<void> confirm(String text, VoidCallback yes) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(text),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) yes();
  }

  Future<void> choose(
    String title,
    List<(String, VoidCallback)> entries, {
    Widget? footer,
  }) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(ctx).height * .7,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(title, style: Theme.of(ctx).textTheme.titleLarge),
              ),
              Expanded(
                child: ListView(
                  children: [
                    for (final e in entries)
                      ListTile(
                        title: Text(e.$1),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () {
                          Navigator.pop(ctx);
                          e.$2();
                        },
                      ),
                  ],
                ),
              ),
              if (footer != null)
                Padding(padding: const EdgeInsets.all(12), child: footer),
            ],
          ),
        ),
      ),
    );
  }

  void showPresets() => choose(
    'Character presets',
    [
      for (final e in db.presets.entries)
        (
          str(obj(e.value)['profile_name'], e.key),
          () {
            selected = '';
            store.replace(obj(e.value));
          },
        ),
      for (final raw in store.presets)
        (
          str(raw['profile_name'], 'Custom preset'),
          () {
            selected = '';
            store.replace(obj(raw));
          },
        ),
    ],
    footer: action('Save current as preset', Icons.add, () {
      Navigator.pop(context);
      store.edit(() => store.presets.add(clone(store.character)), undo: false);
      toast('Preset saved.');
    }),
  );
  Set<String> get bodyTypes => arr(db.constants['POSE_LIMBS']).map((x) {
    final s = str(x), i = s.lastIndexOf('_');
    return i > 0 ? s.substring(0, i) : s;
  }).toSet();
  void showWardrobe() => choose(
    'Saved outfits',
    [
      for (final raw in store.wardrobe)
        (
          str(raw['name'], 'Outfit'),
          () => store.edit(() {
            store.items.removeWhere((i) => !bodyTypes.contains(i['base_type']));
            store.items.addAll(arr(raw['items']).map((i) => clone(obj(i))));
            store.normalize(store.character);
          }),
        ),
      for (final raw in store.wardrobe)
        (
          'Delete: ${raw['name']}',
          () => confirm(
            'Delete this outfit?',
            () => store.edit(() => store.wardrobe.remove(raw), undo: false),
          ),
        ),
    ],
    footer: action('Save this outfit', Icons.add, () async {
      Navigator.pop(context);
      final name = await prompt('Outfit name', 'My outfit');
      if (name != null) {
        store.edit(
          () => store.wardrobe.add({
            'name': name,
            'items': store.items
                .where((i) => !bodyTypes.contains(i['base_type']))
                .map((i) => clone(obj(i)))
                .toList(),
          }),
          undo: false,
        );
      }
    }),
  );
  void showStudios() => choose('Saved studios', [
    for (final raw in store.scenes)
      (
        str(raw['name'], 'Studio'),
        () => stageChange(() {
          stage = clone(obj(raw));
          actor = 0;
        }),
      ),
    for (final raw in store.scenes)
      (
        'Delete: ${raw['name']}',
        () => confirm(
          'Delete saved studio?',
          () => store.edit(() => store.scenes.remove(raw), undo: false),
        ),
      ),
  ]);
  void recentCodes() => choose('Recent imports', [
    for (final raw in store.recent)
      (
        str(raw['name'], 'Imported'),
        () {
          try {
            store.importCode(str(raw['code']));
          } catch (e) {
            toast('$e');
          }
        },
      ),
  ]);
  Future<void> shareCode() async {
    final code = store.exportCode();
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Character code'),
        content: SizedBox(
          width: 500,
          height: 240,
          child: SingleChildScrollView(child: SelectableText(code)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: code));
              toast('Code copied.');
            },
            child: const Text('Copy'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(ctx);
              final f = File('${store.folder.path}/Character.musecode');
              await f.writeAsString(code);
              await shareFile(f.path);
            },
            child: const Text('Share file'),
          ),
        ],
      ),
    );
  }

  Future<void> importCode() async {
    final code = await prompt('Import character code', '', multi: true);
    if (code == null) return;
    try {
      store.importCode(code);
      selected = '';
      toast('Character imported. Undo restores the previous character.');
    } catch (e) {
      toast('Import failed: $e');
    }
  }

  Future<void> chooseLink(Json it, bool clip) async {
    final id = str(it['unique_id']);
    await choose(clip ? 'Clip to layer' : 'Link colors', [
      if (clip)
        (
          'Remove clip',
          () => store.edit(() {
            final c = obj(store.character['clips']);
            c.remove(id);
            store.character['clips'] = c;
          }),
        ),
      if (!clip)
        (
          'Remove color links',
          () => store.edit(
            () => arr(
              store.character['linked_groups'],
            ).removeWhere((g) => arr(g).contains(id)),
          ),
        ),
      for (final raw in store.items.where((i) => i['unique_id'] != id))
        (
          str(raw['unique_id']),
          () => store.edit(() {
            if (clip) {
              final c = obj(store.character['clips']);
              c[id] = raw['unique_id'];
              store.character['clips'] = c;
            } else {
              final groups = arr(store.character['linked_groups']);
              groups.add([id, raw['unique_id']]);
              store.character['linked_groups'] = groups;
              store.copyLinked(id);
            }
          }),
        ),
    ]);
  }

  Future<void> pickColor(String initial, void Function(String) apply) async {
    final c = TextEditingController(text: initial),
        palette = [
          'ffffffff',
          '1f1832ff',
          '7b4fa8ff',
          'cbb6eaff',
          'f5bdd7ff',
          'f6d8b5ff',
          'fef3e9ff',
          'be8d73ff',
          '78554aff',
          '42302cff',
          'ff7d8aff',
          'ffc56dff',
          'fff09bff',
          'a7dba6ff',
          '8edce0ff',
          '85aaf2ff',
          '6b69baff',
          'b88cc7ff',
        ];
    String? error;
    final route = DialogRoute<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: const Text('Color'),
          content: SizedBox(
            width: 340,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final p in palette)
                      InkWell(
                        onTap: () => Navigator.pop(ctx, p),
                        child: Container(
                          width: 42,
                          height: 42,
                          decoration: BoxDecoration(
                            color: museColor(p),
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.black12),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: c,
                  decoration: InputDecoration(
                    labelText: 'RGB or RGBA hex',
                    errorText: error,
                    border: const OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                var s = c.text.replaceAll('#', '').trim();
                if (!RegExp(
                  r'^(?:[a-fA-F0-9]{6}|[a-fA-F0-9]{8})$',
                ).hasMatch(s)) {
                  set(() => error = 'Enter 6 or 8 hexadecimal digits.');
                  return;
                }
                if (s.length == 6) s += 'ff';
                Navigator.pop(ctx, s);
              },
              child: const Text('Apply'),
            ),
          ],
        ),
      ),
    );
    final result = await Navigator.of(context).push(route);
    await route.completed;
    c.dispose();
    if (result != null && mounted) apply(result);
  }

  Future<void> importImage() async {
    try {
      final type = category,
          picked = await FilePicker.pickFile(
            type: FileType.custom,
            allowedExtensions: ['png', 'jpg', 'jpeg'],
          );
      if (picked == null) return;
      final file = picked;
      if (file.path == null || await File(file.path!).length() > 25000000) {
        throw const FormatException('Choose an image under 25 MB.');
      }
      final bytes = await File(file.path!).readAsBytes(),
          buffer = await ui.ImmutableBuffer.fromUint8List(bytes),
          descriptor = await ui.ImageDescriptor.encoded(buffer);
      if (descriptor.width > 4096 || descriptor.height > 4096) {
        descriptor.dispose();
        buffer.dispose();
        throw const FormatException('Maximum image size: 4096 × 4096.');
      }
      final codec = await descriptor.instantiateCodec(),
          image = (await codec.getNextFrame()).image,
          png = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      codec.dispose();
      descriptor.dispose();
      buffer.dispose();
      final id = DateTime.now().microsecondsSinceEpoch.toString(),
          pre = 'user://custom/$id',
          target = File(store.localPath('${pre}_c1.png'));
      await target.parent.create(recursive: true);
      await target.writeAsBytes(
        png!.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
        flush: true,
      );
      if (!mounted) return;
      final asset = <String, dynamic>{
        'name': 'Custom ${store.customAssets.length + 1}',
        'prefix': pre,
        'type': type,
        'colors': {'c1': 'ffffffff'},
      };
      store.customAssets.add(asset);
      selected = store.equip(type, asset);
      toast('Custom image added to $type.');
    } catch (e) {
      toast('Import failed: $e');
    }
  }

  Future<void> exportImage() async {
    setState(() => exporting = true);
    try {
      final studio = tab == MuseTab.studio,
          frame = await artwork.build(
            clone(studio ? stage : store.character),
            studio: studio,
          ),
          bytes = await MusePainter(
            frame,
            background: studio
                ? museColor(stage['background'])
                : Colors.transparent,
            zoom: zoom,
          ).png();
      final f = File(
        '${store.folder.path}/${studio ? 'Studio' : 'Character'}-${DateTime.now().millisecondsSinceEpoch}.png',
      );
      await f.writeAsBytes(bytes, flush: true);
      if (mounted) await shareFile(f.path);
    } catch (e) {
      toast('Export failed: $e');
    } finally {
      if (mounted) setState(() => exporting = false);
    }
  }

  Future<void> shareFile(String path) async {
    if (!mounted) return;
    final box = context.findRenderObject() as RenderBox?,
        origin = box == null
            ? const Rect.fromLTWH(0, 0, 1, 1)
            : box.localToGlobal(Offset.zero) & box.size;
    try {
      await SharePlus.instance.share(
        ShareParams(files: [XFile(path)], sharePositionOrigin: origin),
      );
    } catch (e) {
      toast('File saved in the app folder. Sharing failed: $e');
    }
  }

  void credits() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Original creators & supporters'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Text(
              obj(db.root['credits']).entries
                  .map(
                    (e) =>
                        '${e.key}\n${e.value is List ? (e.value as List).join(', ') : e.value}',
                  )
                  .join('\n\n'),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}
