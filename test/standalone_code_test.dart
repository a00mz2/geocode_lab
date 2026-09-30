// ════════════════════════════════════════════════════════════════════════════
//  اختبار المطابقة للكود المولَّد
//
//  الكود الذي ينسخه زر </> يجب أن يعمل في أي مشروع لا يعرف شيئاً عن هذا
//  التطبيق، وأن يعطي ناتج المعاينة حرفياً. لذلك لا نكتفي بفحص نصّه:
//   1) نولّد قالباً لكل مفتاح في `fields` + كل القوالب الافتراضية + توليفات
//      الفاصل وحذف التكرار والبادئات العدائية،
//   2) نكتبها كلها في ملف Dart مؤقت خارج المشروع (بلا pubspec ولا package)،
//   3) نشغّل `dart analyze --fatal-infos` ثم `dart run` عليه فعلاً،
//   4) ونقارن كل ناتج بـ `AddressTemplate.render()` على نفس المدخلات.
// ════════════════════════════════════════════════════════════════════════════

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:geocode_lab/main.dart';

// ─────────────────────────── العيّنات ───────────────────────────

Map<String, dynamic> _r(List<List<dynamic>> comps, List<String> types) => {
      'types': types,
      'address_components': [
        for (final c in comps)
          {'long_name': c[0], 'short_name': c[0], 'types': c[1]},
      ],
    };

class _Scenario {
  const _Scenario(
    this.id,
    this.body, {
    required this.lat,
    required this.lng,
    this.poi,
    this.areaHint,
    this.areaHintSource,
  });

  final String id;
  final Map<String, dynamic> body;
  final double lat;
  final double lng;
  final String? poi;
  final String? areaHint;
  final String? areaHintSource;

  /// نفس الأنواع التي يراها الكود المولَّد بعد jsonDecode (int مقابل double…).
  Map<String, dynamic> get roundTripped =>
      jsonDecode(jsonEncode(body)) as Map<String, dynamic>;

  PlaceLocation get place => PlaceLocation.fromGeocoding(
        roundTripped,
        lat: lat,
        lng: lng,
        poi: poi,
        areaHint: areaHint,
        areaHintSource: areaHintSource,
      );
}

List<_Scenario> _scenarios() {
  final jihad = <String, dynamic>{
    'status': 'OK',
    'plus_code': {'compound_code': '77PX+QH بغداد، العراق'},
    'results': [
      _r([
        ['77PX+MXQ', ['plus_code']],
        ['حي الجهاد', ['political', 'sublocality', 'sublocality_level_1']],
        ['بغداد', ['locality', 'political']],
        ['الرشيد', ['administrative_area_level_2', 'political']],
        ['بغداد محافظة', ['administrative_area_level_1', 'political']],
        ['العراق', ['country', 'political']],
      ], ['establishment', 'point_of_interest']),
      _r([
        ['881-63', ['route']],
        ['حي الجهاد', ['political', 'sublocality', 'sublocality_level_1']],
        ['بغداد', ['locality', 'political']],
      ], ['route']),
      _r([
        ['الجهاد', ['neighborhood', 'political']],
        ['حي الجهاد', ['political', 'sublocality', 'sublocality_level_1']],
        ['بغداد', ['locality', 'political']],
      ], ['neighborhood', 'political']),
    ],
  };

  // مدينة الصدر: geometry + place_id + short_name مختلف + global_code
  final sadr = <String, dynamic>{
    'status': 'OK',
    'plus_code': {
      'compound_code': '9FV5+87 بغداد، العراق',
      'global_code': '8H569FV5+87',
    },
    'results': [
      {
        'types': ['premise', 'street_address'],
        'formatted_address': '9FV5+867، بغداد، بغداد محافظة، العراق',
        'place_id': 'ChIJIfArB7-cVxURa_uPG0RPtno',
        'geometry': {
          'location_type': 'ROOFTOP',
          'location': {'lat': 33.3932727, 'lng': 44.4579897},
        },
        'plus_code': {'compound_code': '9FV5+867 بغداد، العراق'},
        'address_components': [
          {
            'long_name': '9FV5+867',
            'short_name': '9FV5+867',
            'types': ['plus_code']
          },
          {
            'long_name': 'مدينة الصدر',
            'short_name': 'مدينة الصدر',
            'types': ['political', 'sublocality', 'sublocality_level_1']
          },
          {
            'long_name': 'العراق',
            'short_name': 'IQ',
            'types': ['country', 'political']
          },
        ],
      },
      {
        'types': ['route'],
        'formatted_address': '544-4، بغداد، بغداد محافظة، العراق',
        'place_id': 'ChIJQyzfVL6cVxURrL0rc7ZAlys',
        'geometry': {
          'location_type': 'GEOMETRIC_CENTER',
          // أعداد صحيحة عمداً: JSON قد يرجّع int لا double
          'location': {'lat': 33, 'lng': 44},
        },
        'address_components': [
          {'long_name': '544-4', 'short_name': '544-4', 'types': ['route']},
        ],
      },
      {
        'types': ['neighborhood', 'political'],
        'formatted_address': 'قطاع 32، بغداد، بغداد محافظة، العراق',
        'place_id': 'ChIJ9TKD_76cVxURv1HuQlKL_h8',
        'geometry': {
          'location_type': 'APPROXIMATE',
          'location': {'lat': 33.3935472, 'lng': 44.4588834},
        },
        'address_components': [
          {
            'long_name': 'قطاع 32',
            'short_name': 'قطاع 32',
            'types': ['neighborhood', 'political']
          },
        ],
      },
      // نتيجة ثانية من نفس النوع ⇒ مفاتيح fmt:route#2 …؛ ونوع political فقط
      {
        'types': ['route'],
        'formatted_address': 'شارع آخر، بغداد',
        'place_id': 'ChIJ_second_route',
        'geometry': {'location_type': 'GEOMETRIC_CENTER'},
        'address_components': [
          {'long_name': 'شارع آخر', 'short_name': 'ش آخر', 'types': ['route']},
        ],
      },
      {
        'types': ['political'],
        'formatted_address': 'سياسي فقط',
        'address_components': <dynamic>[],
      },
      {
        'types': <String>[],
        'formatted_address': 'بلا أنواع',
        'address_components': <dynamic>[],
      },
    ],
  };

  // نقطة بلا حي ولا منطقة، والشارع ملوّث بذيل إداري
  final noArea = <String, dynamic>{
    'status': 'OK',
    'results': [
      _r([
        ['شارع الشهداء - بغداد - الرشيد', ['route']],
        ['بغداد', ['locality']],
        ['الرشيد', ['administrative_area_level_2']],
      ], ['route']),
    ],
  };

  // أسماء لاتينية رغم language=ar
  final ainkawa = <String, dynamic>{
    'status': 'OK',
    'results': [
      _r([
        ['Ainkawa', ['neighborhood']],
        ['Erbil', ['locality']],
      ], ['neighborhood']),
    ],
  };

  final ainkawaMixed = <String, dynamic>{
    'status': 'OK',
    'results': [
      _r([
        ['Unnamed Road', ['route']],
        ['Ainkawa', ['neighborhood']],
        ['أربيل', ['locality']],
      ], ['route']),
    ],
  };

  // رد بلا نتائج مع كود بلس جذري فقط
  final emptyWithPlus = <String, dynamic>{
    'status': 'ZERO_RESULTS',
    'plus_code': {'compound_code': '9FV5+87 بغداد، العراق'},
    'results': <dynamic>[],
  };

  // رد شبه خالٍ: البلد فقط
  final bare = <String, dynamic>{
    'status': 'OK',
    'results': [
      _r([['العراق', ['country']]], ['country']),
    ],
  };

  // قيمتان متناقضتان لنفس النوع ⇒ مفاتيح #2
  final variants = <String, dynamic>{
    'status': 'OK',
    'results': [
      _r([
        ['حي الجهاد', ['sublocality', 'sublocality_level_1']],
        ['الرشيد', ['administrative_area_level_2']],
      ], ['premise']),
      _r([
        ['حي الجهاد', ['sublocality', 'sublocality_level_1']],
        ['المنصور', ['administrative_area_level_2']],
      ], ['sublocality_level_1']),
    ],
  };

  // لا results إطلاقاً (رد خاطئ) — يجب ألا ينهار
  final noResultsKey = <String, dynamic>{'status': 'REQUEST_DENIED'};

  return [
    _Scenario('jihad', jihad, lat: 33.28, lng: 44.29),
    _Scenario('jihad+poi', jihad, lat: 33.28, lng: 44.29, poi: 'جامع مصطفى'),
    _Scenario('sadr', sadr, lat: 33.393267, lng: 44.458212),
    _Scenario('noArea', noArea, lat: 33.25, lng: 44.31),
    _Scenario('noArea+poi', noArea,
        lat: 33.25, lng: 44.31, poi: 'متوسطة البحتري للبنين'),
    _Scenario('noArea+poi+hint', noArea,
        lat: 33.25,
        lng: 44.31,
        poi: 'متوسطة البحتري للبنين',
        areaHint: 'حي ميسلون',
        areaHintSource: '250م'),
    _Scenario('noArea+hintNoSrc', noArea,
        lat: 33.25, lng: 44.31, areaHint: 'حي ميسلون'),
    _Scenario('ainkawa', ainkawa, lat: 36.2, lng: 44.0),
    _Scenario('ainkawaMixed', ainkawaMixed, lat: 36.2, lng: 44.0),
    _Scenario('emptyWithPlus', emptyWithPlus, lat: 33.3, lng: 44.4),
    _Scenario('emptyWithPlus+poi', emptyWithPlus,
        lat: 33.3, lng: 44.4, poi: 'جامع مصطفى'),
    _Scenario('bare', bare, lat: 0, lng: 0),
    _Scenario('variants', variants, lat: 33.28, lng: 44.29),
    _Scenario('noResultsKey', noResultsKey, lat: 1.5, lng: 2.5),
  ];
}

// ─────────────────────────── القوالب ───────────────────────────

List<AddressTemplate> _templates(List<_Scenario> scenarios) {
  final out = <AddressTemplate>[];

  // (أ) قالب لكل مفتاح فريد يظهر في أي سيناريو — يثبت أن المساعد ≡ fields
  final keys = <String>{};
  for (final s in scenarios) {
    keys.addAll(s.place.fields.keys);
  }
  for (final k in keys) {
    out.add(AddressTemplate(
        name: 'key $k', dedupe: false, parts: [TemplatePart(key: k)]));
  }

  // (ب) القوالب الافتراضية مع حذف التكرار ومن دونه
  for (final d in [true, false]) {
    for (final t in AddressTemplate.defaults()) {
      out.add(t..dedupe = d);
    }
  }

  // (ج) كل فاصل
  for (final sep in ['، ', ' - ', '  ', ' | ']) {
    out.add(AddressTemplate(name: 'sep', separator: sep, parts: [
      TemplatePart(key: 'route'),
      TemplatePart(key: 'neighborhood'),
      TemplatePart(key: 'sublocality_level_1'),
      TemplatePart(key: 'locality'),
    ]));
  }

  // (د) بادئة عدائية: علامة اقتباس، دولار، شرطة مائلة، اقتباس مزدوج، tab، سطر
  out.add(AddressTemplate(name: 'prefix', parts: [
    TemplatePart(key: 'route', prefix: "it's \$x \\ \"q\"\t\n"),
    TemplatePart(key: 'neighborhood', prefix: 'قرب '),
    TemplatePart(key: 'poi', prefix: r'$ '),
  ]));

  // (هـ) الاحتواء بالاتجاهين: الأشمل أولاً ثم الأضيق، وبالعكس
  out.add(AddressTemplate(name: 'contain 1', parts: [
    TemplatePart(key: 'neighborhood'),
    TemplatePart(key: 'sublocality_level_1'),
    TemplatePart(key: 'locality'),
  ]));
  out.add(AddressTemplate(name: 'contain 2', parts: [
    TemplatePart(key: 'sublocality_level_1'),
    TemplatePart(key: 'neighborhood'),
    TemplatePart(key: 'nb', prefix: 'X '),
  ]));

  // (و) جزء مطفأ + مفتاح غير موجود في أي رد
  out.add(AddressTemplate(name: 'off', parts: [
    TemplatePart(key: 'route', enabled: false),
    TemplatePart(key: 'airport'),
    TemplatePart(key: 'neighborhood'),
  ]));

  // (ز) إحداثية الاستعلام مع مفاتيح أخرى
  out.add(AddressTemplate(name: 'coords', separator: ' | ', parts: [
    TemplatePart(key: 'q:lat'),
    TemplatePart(key: 'q:lng'),
    TemplatePart(key: 'route'),
  ]));

  // (ح) كل المدخلات الإضافية معاً
  out.add(AddressTemplate(name: 'all inputs', parts: [
    TemplatePart(key: 'area_nearby'),
    TemplatePart(key: 'area_nearby_src', prefix: '@'),
    TemplatePart(key: 'best_line'),
    TemplatePart(key: 'poi', prefix: 'قرب '),
    TemplatePart(key: 'land'),
    TemplatePart(key: 'q:lat'),
  ]));

  // (ط) قالب فارغ
  out.add(AddressTemplate(name: 'empty'));

  return out;
}

// ─────────────────────────── ملف الاختبار المولَّد ───────────────────────────

String _nullable(String? s) => s == null ? 'null' : dartStr(s);

/// عيّنات Places Nearby لاختبار تطابق pickBestPoi.
final List<({String id, List<dynamic> list, double lat, double lng})>
    _poiFixtures = [
  (
    id: 'mixed',
    lat: 33.28,
    lng: 44.29,
    list: [
      {
        'name': 'Ainkawa Mall',
        'types': ['shopping_mall'],
        'geometry': {
          'location': {'lat': 33.2805, 'lng': 44.29}
        },
      },
      {
        'name': 'جامع مصطفى',
        'types': ['mosque'],
        'geometry': {
          'location': {'lat': 33.282, 'lng': 44.29}
        },
      },
      {
        'name': 'مطعم بغداد',
        'types': ['restaurant'],
        'geometry': {
          'location': {'lat': 33.2801, 'lng': 44.29}
        },
      },
      {
        'name': 'صالون',
        'types': ['hair_care'],
        'geometry': {
          'location': {'lat': 33.28001, 'lng': 44.29001}
        },
      },
      {'name': '9FV5+867', 'types': ['premise']},
      {'name': 'Unnamed Road'},
    ],
  ),
  (
    id: 'latinOnly',
    lat: 36.2,
    lng: 44.0,
    list: [
      {
        'name': 'Family Mall',
        'types': ['shopping_mall'],
        'geometry': {
          'location': {'lat': 36.203, 'lng': 44.0}
        },
      },
      {
        'name': 'Cafe X',
        'types': ['cafe'],
        'geometry': {
          'location': {'lat': 36.2001, 'lng': 44.0}
        },
      },
      {'name': 'Somewhere', 'types': ['point_of_interest']},
    ],
  ),
  (id: 'junkOnly', lat: 0, lng: 0, list: [
    {'name': 'Unnamed Road'},
    {'name': '544-4'},
  ]),
  (id: 'empty', lat: 0, lng: 0, list: <dynamic>[]),
];

String _harness(List<AddressTemplate> templates, List<_Scenario> scenarios) {
  final b = StringBuffer()
    ..writeln(standaloneFetchImports)
    ..writeln(standaloneHelperSource('_GeoFields'))
    ..writeln()
    ..writeln(standaloneFetchSupportSource('_GeoFields'));

  for (var i = 0; i < templates.length; i++) {
    b
      ..writeln(templates[i].standaloneFunction(functionName: 't$i'))
      ..writeln()
      // دوال الجلب تُترجَم وتُحلَّل فقط — لا شبكة في الاختبار
      ..writeln(templates[i].standaloneFetchFunction(
          functionName: 't$i', fetchPoi: true, fetchArea: true))
      ..writeln();
  }

  b.writeln('void _run(String id, Map<String, dynamic> body, double lat, '
      'double lng, String? poi, String? areaHint, String? areaHintSource) {');
  for (var i = 0; i < templates.length; i++) {
    final n = templates[i].standaloneNeeds;
    final args = <String>[
      'body',
      if (n.poi) 'poi: poi',
      if (n.area) 'areaHint: areaHint',
      if (n.area) 'areaHintSource: areaHintSource',
      if (n.coords) 'lat: lat',
      if (n.coords) 'lng: lng',
    ];
    // الناتج يُرمَّز base64 حتى لا يعتمد على ترميز الطرفية في Windows
    b.writeln("  print(base64Encode(utf8.encode(jsonEncode(['t$i', id, "
        't$i(${args.join(', ')})]))));');
  }
  b
    ..writeln("  print(base64Encode(utf8.encode(jsonEncode(['hasLocalArea', id, "
        '_GeoFields(body).hasLocalArea.toString()]))));')
    ..writeln('}')
    ..writeln()
    ..writeln('void main() {');
  for (final s in scenarios) {
    b.writeln('  _run(${dartStr(s.id)}, '
        'jsonDecode(${dartStr(jsonEncode(s.body))}) as Map<String, dynamic>, '
        '${s.lat}, ${s.lng}, ${_nullable(s.poi)}, ${_nullable(s.areaHint)}, '
        '${_nullable(s.areaHintSource)});');
  }
  for (final f in _poiFixtures) {
    b.writeln("  print(base64Encode(utf8.encode(jsonEncode(['poi', "
        '${dartStr(f.id)}, pickBestPoi(jsonDecode(${dartStr(jsonEncode(f.list))}) '
        "as List, ${f.lat}, ${f.lng}) ?? '']))));");
  }
  b.writeln('}');
  return b.toString();
}

// ─────────────────────────── تحديد dart ───────────────────────────

String? _probe(String dir) {
  final ext = Platform.isWindows ? '.exe' : '';
  for (final rel in ['dart-sdk/bin/dart', 'bin/cache/dart-sdk/bin/dart']) {
    final p = [dir, ...rel.split('/')].join(Platform.pathSeparator) + ext;
    if (File(p).existsSync()) return p;
  }
  return null;
}

/// تحت `flutter test` يكون Platform.resolvedExecutable هو flutter_tester
/// لا dart، فنمشي في أسلافه حتى نجد dart-sdk.
({String exe, bool shell}) _findDart(List<String> tried) {
  final env = Platform.environment['DART_EXE'];
  if (env != null && env.isNotEmpty) {
    if (File(env).existsSync()) return (exe: env, shell: false);
    tried.add('DART_EXE=$env');
  }

  var dir = File(Platform.resolvedExecutable).parent;
  for (var i = 0; i < 10; i++) {
    final p = _probe(dir.path);
    if (p != null) return (exe: p, shell: false);
    tried.add(dir.path);
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }

  final root = Platform.environment['FLUTTER_ROOT'];
  if (root != null && root.isNotEmpty) {
    final p = _probe(root);
    if (p != null) return (exe: p, shell: false);
    tried.add('FLUTTER_ROOT=$root');
  }

  // dart.bat على Windows لا يُطلق إلا عبر cmd
  return (exe: 'dart', shell: Platform.isWindows);
}

Future<ProcessResult> _dart(
  ({String exe, bool shell}) d,
  List<String> args,
  String cwd,
  List<String> tried,
) async {
  try {
    return await Process.run(
      d.exe,
      args,
      runInShell: d.shell,
      workingDirectory: cwd,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
  } on ProcessException catch (e) {
    fail('لم يُوجد dart لتشغيل الكود المولَّد (${e.message}).\n'
        'المسارات المجرَّبة:\n  ${tried.join('\n  ')}\n'
        'ضع DART_EXE=<مسار dart.exe> في البيئة إن لزم.');
  }
}

// ═══════════════════════════════════════════════════════════════════════════

void main() {
  final scenarios = _scenarios();
  late List<AddressTemplate> templates;
  late Directory tmp;
  late File gen;
  late ({String exe, bool shell}) dart;
  final tried = <String>[];

  setUpAll(() {
    templates = _templates(scenarios);
    tmp = Directory.systemTemp.createTempSync('geocode_lab_gen_');
    gen = File('${tmp.path}${Platform.pathSeparator}gen.dart')
      ..writeAsStringSync(_harness(templates, scenarios));
    dart = _findDart(tried);
  });

  tearDownAll(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('الكود المستقل — ترجمة وتشغيل حقيقيان', () {
    test('يغطّي كل مفتاح في fields وكل القوالب الافتراضية', () {
      final keys = <String>{};
      for (final s in scenarios) {
        keys.addAll(s.place.fields.keys);
      }
      for (final k in [
        'best', 'best_line', 'best_src', 'best_lang', //
        'area_nearby', 'area_nearby_src', //
        'st', 'nb', 'sub', 'city', 'land', 'poi', //
        'route', 'route#2', 'neighborhood', 'sublocality_level_1', //
        'administrative_area_level_2#2', 'short:country', //
        'fmt:route', 'fmt:route#2', 'acc:premise', 'id:route', 'types:premise',
        'lat:route', 'lng:neighborhood', 'plus:premise', //
        'fmt:political', 'fmt:result', //
        'plus:compound', 'plus:global', 'q:lat', 'q:lng',
      ]) {
        expect(keys, contains(k), reason: 'المفتاح $k غير مغطّى بأي سيناريو');
      }
      expect(templates.length, greaterThan(keys.length + 10));
    });

    test(
      'يمرّ dart analyze --fatal-infos بلا أي ملاحظة',
      () async {
        final res = await _dart(
            dart, ['analyze', '--fatal-infos', gen.path], tmp.path, tried);
        expect(
          res.exitCode,
          0,
          reason: 'dart analyze فشل على ${gen.path}\n'
              '${res.stdout}\n${res.stderr}',
        );
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    test(
      'يُشغَّل ويطابق المعاينة حرفياً على كل مفتاح وسيناريو',
      () async {
        final res = await _dart(dart, ['run', gen.path], tmp.path, tried);
        expect(
          res.exitCode,
          0,
          reason: 'dart run فشل على ${gen.path}\n${res.stdout}\n${res.stderr}',
        );

        final byId = {for (final s in scenarios) s.id: s};
        final places = {for (final s in scenarios) s.id: s.place};
        var seen = 0;
        var extra = 0;
        for (final line in LineSplitter.split(res.stdout as String)) {
          if (line.trim().isEmpty) continue;
          final row = jsonDecode(utf8.decode(base64Decode(line.trim()))) as List;
          final sid = row[1] as String;
          final actual = row[2] as String;
          if (row[0] == 'hasLocalArea') {
            expect(actual, places[sid]!.hasLocalArea.toString(),
                reason: 'hasLocalArea على السيناريو «$sid»');
            extra++;
            continue;
          }
          if (row[0] == 'poi') {
            final f = _poiFixtures.singleWhere((e) => e.id == sid);
            final rt = jsonDecode(jsonEncode(f.list)) as List;
            expect(actual, pickBestPoi(rt, f.lat, f.lng) ?? '',
                reason: 'pickBestPoi على عيّنة «$sid»');
            extra++;
            continue;
          }
          final i = int.parse((row[0] as String).substring(1));
          final t = templates[i];
          final s = byId[sid]!;
          final expected = t.render(places[sid]!);
          expect(
            actual,
            expected,
            reason: 'قالب «${t.name}» (t$i) على السيناريو «${s.id}»\n'
                'المفاتيح: ${t.activeKeys}  فاصل: ${jsonEncode(t.separator)}  '
                'dedupe: ${t.dedupe}',
          );
          seen++;
        }
        expect(seen, templates.length * scenarios.length,
            reason: 'عدد النواتج لا يساوي القوالب × السيناريوهات');
        expect(extra, scenarios.length + _poiFixtures.length,
            reason: 'فحوص hasLocalArea و pickBestPoi ناقصة');
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  });

  group('الكود المستقل — بنية', () {
    test('dartStr يهرّب كل ما يكسر نصّ Dart', () {
      expect(dartStr('a'), "'a'");
      expect(dartStr("a'b"), r"'a\'b'");
      expect(dartStr(r'$x'), r"'\$x'");
      expect(dartStr('a\\b'), r"'a\\b'");
      expect(dartStr('a\nb\tc\rd'), r"'a\nb\tc\rd'");
      expect(dartStr('قرب '), "'قرب '");
    });

    test('dartIdentifier يعطي معرّفاً صالحاً دائماً', () {
      expect(dartIdentifier('driver line'), 'driverLine');
      expect(dartIdentifier('Driver  Line!'), 'driverLine');
      expect(dartIdentifier('2 lines'), 'address2Lines');
      expect(dartIdentifier('class'), 'classLine');
      expect(dartIdentifier('سطر السائق'), 'formatAddress');
      expect(dartIdentifier(''), 'formatAddress');
      expect(dartIdentifier('x', fallback: 'y'), 'x');
    });

    test('المعاملات الإضافية تظهر فقط عند الحاجة', () {
      // اسم عربي ⇒ اسم الدالة الافتراضي formatAddress
      AddressTemplate t(List<String> keys) => AddressTemplate(
          name: 'قالب', parts: [for (final k in keys) TemplatePart(key: k)]);

      expect(t(['route']).standaloneNeeds,
          (poi: false, area: false, coords: false));
      expect(t(['poi']).standaloneNeeds,
          (poi: true, area: false, coords: false));
      expect(t(['land']).standaloneNeeds,
          (poi: true, area: false, coords: false));
      expect(t(['best_line']).standaloneNeeds,
          (poi: true, area: true, coords: false));
      expect(t(['area_nearby']).standaloneNeeds,
          (poi: false, area: true, coords: false));
      expect(t(['q:lng']).standaloneNeeds,
          (poi: false, area: false, coords: true));

      final plain = t(['route', 'neighborhood']).standaloneFunction();
      expect(plain, contains('String formatAddress(Map<String, dynamic> body) {'));
      expect(plain, isNot(contains('poi')));
      expect(plain, isNot(contains('required double lat')));

      final coords = t(['q:lat']).standaloneFunction();
      expect(coords,
          contains('{required double lat, required double lng}'));
      expect(coords, contains('_GeoFields(body, lat: lat, lng: lng)'));
    });

    test('لا اعتماد على هذا التطبيق في أي قالب افتراضي', () {
      for (final t in AddressTemplate.defaults()) {
        final code = t.standaloneCode();
        expect(code, isNot(matches(RegExp(r'^import\b', multiLine: true))),
            reason: t.name);
        expect(code, isNot(contains('PlaceLocation')), reason: t.name);
        expect(code, isNot(contains('place.')), reason: t.name);
        expect(code, isNot(contains('package:')), reason: t.name);
        expect(code, contains('class _GeoFields'), reason: t.name);
        expect(code, contains('String formatAddress('), reason: t.name);
      }
    });

    test('includeHelper=false يعطي الدالة وحدها، وأسماء مخصّصة تُحترم', () {
      final t = AddressTemplate.defaults().first;
      final only = t.standaloneCode(
          functionName: 'myLine', helperName: '_Geo', includeHelper: false);
      expect(only, contains('String myLine('));
      expect(only, contains('final f = _Geo(body'));
      expect(only, isNot(contains('class ')));
      expect(standaloneHelperSource('_Geo'), contains('class _Geo {'));
      expect(standaloneHelperSource('_Geo'), isNot(contains('__CLASS__')));
    });

    test('كتلة الجلب تُضمَّن فقط عند تفعيل POI/جوار وحاجة القالب لهما', () {
      final best = AddressTemplate.defaults().first; // best_line
      final plain =
          AddressTemplate(name: 'plain', parts: [TemplatePart(key: 'route')]);

      // مطفآن ⇒ لا استيراد ولا جلب
      final off = best.standaloneCode();
      expect(off, isNot(contains("import 'dart:io'")));
      expect(off, isNot(contains('fetchFormatAddress')));
      expect(off, isNot(contains('_googleJson')));

      // POI فقط
      final poiOnly = best.standaloneCode(fetchPoi: true);
      expect(poiOnly, startsWith('// ═'));
      expect(poiOnly, contains("import 'dart:io';"));
      expect(poiOnly, contains('Future<String> fetchFormatAddress('));
      expect(poiOnly, contains('final poi = await fetchNearbyPoi('));
      expect(poiOnly, isNot(contains('fetchNearbyArea(lat')));
      expect(poiOnly, contains('return formatAddress(body, poi: poi);'));
      expect(poiOnly, contains('String? pickBestPoi('));

      // POI + جوار
      final both = best.standaloneCode(fetchPoi: true, fetchArea: true);
      expect(both, contains('if (!_GeoFields(body).hasLocalArea) {'));
      expect(both, contains('await fetchNearbyArea(lat, lng,'));
      expect(
          both,
          contains('return formatAddress(body, poi: poi, '
              'areaHint: areaHint, areaHintSource: areaHintSource);'));
      expect(both, contains("throw StateError("));

      // القالب لا يحتاج المعلم ⇒ تفعيل المفتاح لا يضيف شيئاً
      expect(plain.standaloneCode(fetchPoi: true, fetchArea: true),
          isNot(contains("import 'dart:io'")));

      // الاستعمال يتبع الحالة
      expect(best.usageCode(fetchPoi: true),
          contains("await fetchFormatAddress(lat, lng, apiKey: 'AIza...');"));
      expect(AddressTemplate.fetchNameFor('driverLine'), 'fetchDriverLine');
    });

    test('usageCode يذكر الدالة والمدخلات الإضافية', () {
      final t = AddressTemplate.defaults().first; // best_line
      expect(
          t.usageCode(), contains('formatAddress(body, poi: nearbyPlaceName'));
      expect(t.usageCode(), contains('areaHint'));
      final plain = AddressTemplate(
          name: 'plain', parts: [TemplatePart(key: 'route')]);
      expect(plain.usageCode(), contains('final line = plain(body);'));
      expect(plain.usageCode(), isNot(contains('poi')));

      final empty = AddressTemplate(name: 'empty');
      expect(empty.standaloneFunction(), contains("return '';"));
      expect(empty.standaloneFunction(), isNot(contains('_GeoFields(')));
    });
  });
}
