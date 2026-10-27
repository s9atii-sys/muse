import 'dart:convert';
import 'dart:io';
import 'package:mini_muses/core.dart';

Future<MuseData> fixture() async => MuseData(
  obj(jsonDecode(await File('assets/muse/database.json').readAsString())),
  obj(jsonDecode(await File('assets/muse/art-index.json').readAsString())),
  obj(jsonDecode(await File('assets/muse/thumb-index.json').readAsString())),
);
