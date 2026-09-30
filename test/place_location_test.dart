import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:geocode_lab/main.dart';

/// اختصار لبناء نتيجة جيوكودنغ.
Map<String, dynamic> _r(List<List<dynamic>> comps, List<String> types) => {
      'types': types,
      'address_components': [
        for (final c in comps)
          {'long_name': c[0], 'short_name': c[0], 'types': c[1]},
      ],
    };

void main() {
  // رد حقيقي مختصر من حي الجهاد، بغداد.
  final jihadBody = <String, dynamic>{
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

  group('PlaceLocation.fromGeocoding', () {
    test('يلتقط neighborhood و route من نتائج غير results[0]', () {
      final p = PlaceLocation.fromGeocoding(jihadBody, lat: 33.28, lng: 44.29);

      expect(p.neighborhood, 'الجهاد');
      expect(p.subLocality, 'حي الجهاد');
      expect(p.route, 'شارع 881-63'); // رقم مجرّد ⇒ تُضاف «شارع»
      expect(p.locality, 'بغداد');
      expect(p.district, 'الرشيد');
    });

    test('يحذف البلد والمحافظة وكود بلس', () {
      final p = PlaceLocation.fromGeocoding(jihadBody, lat: 33.28, lng: 44.29);
      final line = p.fullAddress;

      expect(line.contains('العراق'), isFalse);
      expect(line.contains('محافظة'), isFalse);
      expect(line.contains('+'), isFalse);
    });

    test('يدمج التكرار بالاحتواء: الجهاد + حي الجهاد ⇒ حي الجهاد', () {
      final p = PlaceLocation.fromGeocoding(jihadBody, lat: 33.28, lng: 44.29);
      expect(p.fullAddress, 'شارع 881-63، حي الجهاد');
    });

    test('يضيف المعلم عند توفّره', () {
      final p = PlaceLocation.fromGeocoding(
        jihadBody,
        lat: 33.28,
        lng: 44.29,
        poi: 'جامع مصطفى',
      );
      expect(p.fullAddress, 'شارع 881-63، حي الجهاد  قرب جامع مصطفى');
    });

    test('لا يترك فواصل معلّقة عند غياب الحي والشارع', () {
      final sparse = <String, dynamic>{
        'status': 'OK',
        'results': [
          _r([
            ['بغداد', ['locality', 'political']],
            ['الرشيد', ['administrative_area_level_2', 'political']],
            ['العراق', ['country', 'political']],
          ], ['locality', 'political']),
        ],
      };
      final p = PlaceLocation.fromGeocoding(sparse, lat: 33.2, lng: 44.2);

      expect(p.fullAddress.startsWith('،'), isFalse);
      expect(p.fullAddress.endsWith('قرب'), isFalse);
      expect(p.fullAddress.isNotEmpty, isTrue);
      expect(p.fullAddress, 'الرشيد، بغداد');
    });
  });

  _templateTests(jihadBody);
  _variantTests();
  _allFieldsTests();
  _smartFieldsTests(jihadBody);
  _bestNameTests();
  _areaAlwaysTests();
}

// ── اختبارات بنّاء القوالب ──────────────────────────────────────────────
void _templateTests(Map<String, dynamic> body) {
  final p = PlaceLocation.fromGeocoding(body, lat: 33.28, lng: 44.29, poi: 'جامع مصطفى');

  group('AddressTemplate', () {
    test('يبني السطر حسب ترتيب الحقول المفعّلة', () {
      final t = AddressTemplate(name: 'x', dedupe: false, parts: [
        TemplatePart(key: 'route'),
        TemplatePart(key: 'neighborhood'),
      ]);
      expect(t.render(p), 'شارع 881-63، الجهاد');
    });

    test('يتجاهل الحقول المطفأة وغير المتوفرة بلا فواصل معلّقة', () {
      final t = AddressTemplate(name: 'x', parts: [
        TemplatePart(key: 'route', enabled: false),
        TemplatePart(key: 'neighborhood'),
        TemplatePart(key: 'airport'), // غير موجود في الرد
      ]);
      expect(t.render(p), 'الجهاد');
    });

    test('البادئة تُطبَّق على القيمة', () {
      final t = AddressTemplate(name: 'x', parts: [
        TemplatePart(key: 'neighborhood'),
        TemplatePart(key: 'poi', prefix: 'قرب '),
      ]);
      expect(t.render(p), 'الجهاد، قرب جامع مصطفى');
    });

    test('حذف التكرار بالاحتواء يعمل ويمكن إطفاؤه', () {
      final parts = [
        TemplatePart(key: 'neighborhood'),
        TemplatePart(key: 'sublocality_level_1'),
      ];
      expect(AddressTemplate(name: 'x', parts: parts).render(p), 'حي الجهاد');
      expect(
        AddressTemplate(name: 'x', dedupe: false, parts: parts).render(p),
        'الجهاد، حي الجهاد',
      );
    });

    test('الفاصل قابل للتغيير', () {
      final t = AddressTemplate(name: 'x', separator: ' - ', dedupe: false, parts: [
        TemplatePart(key: 'route'),
        TemplatePart(key: 'neighborhood'),
      ]);
      expect(t.render(p), 'شارع 881-63 - الجهاد');
    });

    test('absorb يضيف المفاتيح الجديدة مطفأة', () {
      final t = AddressTemplate(name: 'x', parts: [TemplatePart(key: 'route')]);
      t.absorb(p.fields.keys);
      expect(t.parts.length, greaterThan(1));
      expect(t.parts.where((e) => e.enabled).length, 1);
      expect(t.render(p), 'شارع 881-63');
    });

    test('يولّد كوداً مستقلاً لا يعتمد على PlaceLocation', () {
      final t = AddressTemplate(name: 'driver line', parts: [
        TemplatePart(key: 'route'),
        TemplatePart(key: 'poi', prefix: 'قرب '),
      ]);
      final code = t.standaloneCode();
      // المفاتيح تُقرأ كما هي من المساعد — لا تُترجَم إلى getters مختلفة،
      // وإلا خالف الكودُ المولَّد المعاينةَ.
      expect(code,
          contains('String driverLine(Map<String, dynamic> body, {String? poi})'));
      expect(code, contains("add(f['route']);"));
      expect(code, contains("add(f['poi'], 'قرب ');"));
      expect(code, contains('class _GeoFields'));
      expect(code, isNot(matches(RegExp(r'^import\b', multiLine: true))));
      expect(code, isNot(contains('PlaceLocation')));
      expect(code, isNot(contains('place.')));
    });

    test('يعبر التخزين ويعود كما هو', () {
      final t = AddressTemplate(name: 'x', separator: ' | ', dedupe: false, parts: [
        TemplatePart(key: 'route', prefix: 'ش '),
      ]);
      final back = AddressTemplate.fromJson(jsonDecode(jsonEncode(t.toJson())));
      expect(back.name, 'x');
      expect(back.separator, ' | ');
      expect(back.dedupe, isFalse);
      expect(back.parts.single.prefix, 'ش ');
    });
  });
}

// ── القيم البديلة: لا تضيع أي قيمة من الرد ──────────────────────────────

void _variantTests() {
  // الرد الحقيقي يعطي قيمتين متناقضتين لـ admin2: الرشيد ثم المنصور.
  final body = <String, dynamic>{
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

  group('القيم البديلة', () {
    final p = PlaceLocation.fromGeocoding(body, lat: 33.28, lng: 44.29);

    test('يحتفظ بكل القيم لا بالأولى فقط', () {
      expect(p.rawAll['administrative_area_level_2'], ['الرشيد', 'المنصور']);
    });

    test('يعرضها كمفاتيح بديلة #2', () {
      expect(p.value('administrative_area_level_2'), 'الرشيد');
      expect(p.value('administrative_area_level_2#2'), 'المنصور');
    });

    test('الحقل المسمّى يأخذ الأدق (الأول)', () {
      expect(p.district, 'الرشيد');
    });

    test('يحتفظ بكل النتائج كاملة', () {
      expect(p.results.length, 2);
      expect(p.results.first.types, ['premise']);
      expect(p.results.last.components.length, 2);
    });

    test('يمكن بناء قالب من قيمة بديلة', () {
      final t = AddressTemplate(name: 'alt', parts: [
        TemplatePart(key: 'administrative_area_level_2#2'),
      ]);
      expect(t.render(p), 'المنصور');
      expect(t.standaloneCode(),
          contains("add(f['administrative_area_level_2#2']);"));
    });
  });
}

// ── كل قيمة في الرد متاحة كمفتاح ────────────────────────────────────────
void _allFieldsTests() {
  // مقتطف من رد مدينة الصدر الحقيقي.
  final body = <String, dynamic>{
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
        'address_components': [
          {'long_name': '9FV5+867', 'short_name': '9FV5+867', 'types': ['plus_code']},
          {'long_name': 'مدينة الصدر', 'short_name': 'مدينة الصدر',
           'types': ['political', 'sublocality', 'sublocality_level_1']},
          {'long_name': 'العراق', 'short_name': 'IQ', 'types': ['country', 'political']},
        ],
      },
      {
        'types': ['route'],
        'formatted_address': '544-4، بغداد، بغداد محافظة، العراق',
        'place_id': 'ChIJQyzfVL6cVxURrL0rc7ZAlys',
        'geometry': {
          'location_type': 'GEOMETRIC_CENTER',
          'location': {'lat': 33.3932975, 'lng': 44.4583396},
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
          {'long_name': 'قطاع 32', 'short_name': 'قطاع 32',
           'types': ['neighborhood', 'political']},
        ],
      },
    ],
  };

  group('كل قيم الرد متاحة', () {
    final p = PlaceLocation.fromGeocoding(body, lat: 33.393267, lng: 44.458212);
    final f = p.fields;

    test('مكوّنات العنوان', () {
      expect(f['route'], 'شارع 544-4');
      expect(f['neighborhood'], 'قطاع 32');
      expect(f['sublocality_level_1'], 'مدينة الصدر');
      expect(f['country'], 'العراق');
      expect(f['plus_code'], '9FV5+867');
    });

    test('الاسم المختصر يظهر عند اختلافه فقط', () {
      expect(f['short:country'], 'IQ');
      expect(f.containsKey('short:neighborhood'), isFalse); // مطابق للطويل
    });

    test('formatted_address لكل نتيجة مسمّى بنوعها', () {
      expect(f['fmt:premise'], '9FV5+867، بغداد، بغداد محافظة، العراق');
      expect(f['fmt:route'], '544-4، بغداد، بغداد محافظة، العراق');
      expect(f['fmt:neighborhood'], 'قطاع 32، بغداد، بغداد محافظة، العراق');
    });

    test('دقة الموقع والمعرّف والأنواع', () {
      expect(f['acc:premise'], 'ROOFTOP');
      expect(f['acc:route'], 'GEOMETRIC_CENTER');
      expect(f['acc:neighborhood'], 'APPROXIMATE');
      expect(f['id:route'], 'ChIJQyzfVL6cVxURrL0rc7ZAlys');
      expect(f['types:premise'], 'premise/street_address');
    });

    test('إحداثيات كل نتيجة وإحداثية الاستعلام', () {
      expect(f['lat:route'], '33.3932975');
      expect(f['lng:route'], '44.4583396');
      expect(f['q:lat'], '33.3932670');
    });

    test('كود بلس من الجذر', () {
      expect(f['plus:compound'], '9FV5+87');
      expect(f['plus:global'], '8H569FV5+87');
    });

    test('المفاتيح التقنية موسومة بتحذير', () {
      expect(isDiscouraged('id:route'), isTrue);
      expect(isDiscouraged('fmt:route'), isTrue);
      expect(isDiscouraged('country'), isTrue);
      expect(isDiscouraged('neighborhood'), isFalse);
      expect(isDiscouraged('route'), isFalse);
    });

    test('يمكن بناء قالب من أي مفتاح جديد', () {
      final t = AddressTemplate(name: 'x', separator: ' - ', parts: [
        TemplatePart(key: 'neighborhood'),
        TemplatePart(key: 'acc:neighborhood', prefix: 'دقة '),
      ]);
      expect(t.render(p), 'قطاع 32 - دقة APPROXIMATE');
      expect(t.standaloneCode(),
          contains("add(f['acc:neighborhood'], 'دقة ');"));
    });

    test('absorb يلتقط كل المفاتيح الجديدة', () {
      final t = AddressTemplate(name: 'x', parts: [TemplatePart(key: 'route')]);
      t.absorb(f.keys);
      expect(t.parts.length, f.length);
      expect(t.activeKeys, ['route']); // الجديدة تُضاف مطفأة
    });
  });
}

// ── الحقول الذكية: st / nb / sub / city / land ──────────────────────────
void _smartFieldsTests(Map<String, dynamic> jihadBody) {
  group('الحقول الذكية', () {
    final p = PlaceLocation.fromGeocoding(jihadBody,
        lat: 33.28, lng: 44.29, poi: 'جامع مصطفى');

    test('متاحة كمفاتيح في بنّاء القالب', () {
      final f = p.fields;
      expect(f['st'], 'شارع 881-63');
      expect(f['nb'], 'الجهاد');
      expect(f['sub'], 'حي الجهاد');
      expect(f['city'], 'بغداد');
      expect(f['land'], 'جامع مصطفى');
    });

    test('nb يسقط إلى البديل التالي حين يغيب الحي', () {
      final noNb = <String, dynamic>{
        'status': 'OK',
        'results': [
          _r([
            ['حي الجهاد', ['sublocality', 'sublocality_level_1']],
            ['بغداد', ['locality']],
          ], ['sublocality_level_1']),
        ],
      };
      final q = PlaceLocation.fromGeocoding(noNb, lat: 33.2, lng: 44.2);
      expect(q.fields['neighborhood'], isNull); // المفتاح الخام غائب
      expect(q.fields['nb'], 'حي الجهاد'); // الذكي يسقط للبديل
    });

    test('nb لا يعود فارغاً حتى مع رد شبه خالٍ', () {
      final bare = <String, dynamic>{
        'status': 'OK',
        'results': [
          _r([['العراق', ['country']]], ['country']),
        ],
      };
      final q = PlaceLocation.fromGeocoding(bare, lat: 0, lng: 0);
      expect(q.fields['nb'], 'موقع على الخريطة');
    });

    test('القالب يعطي نموذج print الأصلي', () {
      final t = AddressTemplate(name: 'smart', dedupe: false, parts: [
        TemplatePart(key: 'st'),
        TemplatePart(key: 'nb'),
        TemplatePart(key: 'sub'),
        TemplatePart(key: 'land', prefix: 'قرب '),
      ]);
      expect(t.render(p), 'شارع 881-63، الجهاد، حي الجهاد، قرب جامع مصطفى');
    });

    test('الكود المولَّد يقرأ الحقول الذكية بمفاتيحها ويطلب poi', () {
      final t = AddressTemplate(name: 'smart line', parts: [
        TemplatePart(key: 'st'),
        TemplatePart(key: 'nb'),
        TemplatePart(key: 'land', prefix: 'قرب '),
      ]);
      final fn = t.standaloneFunction();
      expect(fn, contains('String smartLine(Map<String, dynamic> body, '
          '{String? poi})'));
      expect(fn, contains("add(f['st']);"));
      expect(fn, contains("add(f['nb']);"));
      expect(fn, contains("add(f['land'], 'قرب ');"));
    });
  });
}

// ── الاسم المضمون: لا فارغ، ولا لاتيني إن وُجد عربي ─────────────────────
void _bestNameTests() {
  group('الاسم المضمون', () {
    test('يرفض Unnamed Road ويأخذ البديل العربي', () {
      final body = <String, dynamic>{
        'status': 'OK',
        'results': [
          _r([
            ['Unnamed Road', ['route']],
            ['حي الجهاد', ['sublocality', 'sublocality_level_1']],
            ['بغداد', ['locality']],
          ], ['route']),
        ],
      };
      final p = PlaceLocation.fromGeocoding(body, lat: 33.2, lng: 44.2);

      expect(p.fields['route'], 'Unnamed Road'); // الخام يبقى كما هو
      expect(p.bestName, 'حي الجهاد'); // المضمون يتخطّاه
      expect(p.bestSource, 'sublocality_level_1');
      expect(p.bestIsArabic, isTrue);
    });

    test('يفضّل العربي على اللاتيني حتى لو كان اللاتيني أدق', () {
      final body = <String, dynamic>{
        'status': 'OK',
        'results': [
          _r([
            ['Ainkawa', ['neighborhood']],
            ['أربيل', ['locality']],
          ], ['neighborhood']),
        ],
      };
      final p = PlaceLocation.fromGeocoding(body, lat: 36.2, lng: 44.0);

      expect(p.nb, 'Ainkawa'); // الذكي البسيط يأخذ الأدق فقط
      expect(p.bestName, 'أربيل'); // المضمون يفضّل العربي
      expect(p.bestIsArabic, isTrue);
    });

    test('يقبل اللاتيني حين لا يوجد عربي إطلاقاً', () {
      final body = <String, dynamic>{
        'status': 'OK',
        'results': [
          _r([
            ['Ainkawa', ['neighborhood']],
            ['Erbil', ['locality']],
          ], ['neighborhood']),
        ],
      };
      final p = PlaceLocation.fromGeocoding(body, lat: 36.2, lng: 44.0);

      expect(p.bestName, 'Ainkawa'); // لاتيني خير من فارغ
      expect(p.bestIsArabic, isFalse); // موسوم ⚠ في الشريط
    });

    test('يرفض كود بلس كاسم', () {
      final body = <String, dynamic>{
        'status': 'OK',
        'plus_code': {'compound_code': '9FV5+87 بغداد، العراق'},
        'results': [
          _r([
            ['9FV5+867', ['plus_code']],
            ['بغداد', ['locality']],
          ], ['premise']),
        ],
      };
      final p = PlaceLocation.fromGeocoding(body, lat: 33.3, lng: 44.4);
      expect(p.bestName, 'بغداد');
    });

    test('لا يعود فارغاً حتى مع رد بلا أي اسم', () {
      final body = <String, dynamic>{
        'status': 'OK',
        'plus_code': {'compound_code': '9FV5+87 بغداد، العراق'},
        'results': <dynamic>[],
      };
      final p = PlaceLocation.fromGeocoding(body, lat: 33.3, lng: 44.4);

      expect(p.bestName.isNotEmpty, isTrue);
      expect(p.bestLine.isNotEmpty, isTrue);
      expect(p.fields['best_line']!.isNotEmpty, isTrue);
    });

    test('السطر المضمون يضيف سياقاً ومعلماً بلا تكرار', () {
      final body = <String, dynamic>{
        'status': 'OK',
        'results': [
          _r([
            ['قطاع 32', ['neighborhood']],
            ['مدينة الصدر', ['sublocality', 'sublocality_level_1']],
            ['بغداد', ['locality']],
          ], ['neighborhood']),
        ],
      };
      final p = PlaceLocation.fromGeocoding(body,
          lat: 33.39, lng: 44.45, poi: 'جامع مصطفى');

      expect(p.bestLine, 'قطاع 32، مدينة الصدر، قرب جامع مصطفى');
    });

    test('لا يكرّر المعلم إن كان هو الاسم نفسه', () {
      final body = <String, dynamic>{
        'status': 'OK',
        'results': [
          _r([['بغداد', ['locality']]], ['locality']),
        ],
      };
      final p = PlaceLocation.fromGeocoding(body,
          lat: 33.3, lng: 44.4, poi: 'جامع مصطفى');
      expect(p.bestName, 'جامع مصطفى'); // المعلم أدق من المدينة
      expect(p.bestLine, 'قرب جامع مصطفى، بغداد');
    });

    test('فحص النفاية', () {
      expect(isJunkName('Unnamed Road'), isTrue);
      expect(isJunkName('9FV5+867'), isTrue);
      expect(isJunkName('544-4'), isTrue); // أرقام بحتة
      expect(isJunkName(''), isTrue);
      expect(isJunkName(null), isTrue);
      expect(isJunkName('شارع 544-4'), isFalse);
      expect(isJunkName('Ainkawa'), isFalse);
    });
  });
}

// ── المنطقة دائماً: جوار أو «قرب» ───────────────────────────────────────
void _areaAlwaysTests() {
  // نقطة بلا حي ولا منطقة — مثل حالة «متوسطة البحتري» في التطبيق.
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

  group('المنطقة دائماً', () {
    test('يكشف أن النقطة بلا اسم منطقة', () {
      final p = PlaceLocation.fromGeocoding(noArea, lat: 33.25, lng: 44.31);
      expect(p.hasLocalArea, isFalse);
    });

    test('بلا جوار وبلا معلم: يرجع إلى المنطقة الإدارية', () {
      final p = PlaceLocation.fromGeocoding(noArea, lat: 33.25, lng: 44.31);
      // اسم الشارع يُنظَّف من المدينة والقضاء ثم يصلح رأساً للسطر
      expect(p.bestName, 'شارع الشهداء');
      expect(p.bestLine, 'شارع الشهداء، الرشيد');
    });

    test('المعلم يتصدّر بصيغة «قرب» لا كأنه اسم منطقة', () {
      final p = PlaceLocation.fromGeocoding(noArea,
          lat: 33.25, lng: 44.31, poi: 'متوسطة البحتري للبنين');
      // المعلم (78) أدق من القضاء (40) فيتصدّر — لكن بصيغة «قرب»
      expect(p.bestName, 'متوسطة البحتري للبنين');
      expect(p.bestLine, 'قرب متوسطة البحتري للبنين، الرشيد');
      expect(p.bestLine.startsWith('قرب '), isTrue);
    });

    test('اسم المنطقة من الجوار يتقدّم على المعلم', () {
      final p = PlaceLocation.fromGeocoding(
        noArea,
        lat: 33.25,
        lng: 44.31,
        poi: 'متوسطة البحتري للبنين',
        areaHint: 'حي ميسلون',
        areaHintSource: '250م',
      );
      expect(p.bestName, 'حي ميسلون');
      expect(p.bestSource, 'area_nearby');
      expect(p.bestLine, 'حي ميسلون، الرشيد، قرب متوسطة البحتري للبنين');
      expect(p.fields['area_nearby'], 'حي ميسلون');
      expect(p.fields['area_nearby_src'], '250م');
    });

    test('الحي المحلي يتقدّم على الجوار', () {
      final withArea = <String, dynamic>{
        'status': 'OK',
        'results': [
          _r([
            ['قطاع 32', ['neighborhood']],
            ['مدينة الصدر', ['sublocality', 'sublocality_level_1']],
          ], ['neighborhood']),
        ],
      };
      final p = PlaceLocation.fromGeocoding(withArea,
          lat: 33.39, lng: 44.45, areaHint: 'حي آخر');
      expect(p.hasLocalArea, isTrue);
      expect(p.bestName, 'قطاع 32');
    });

    test('السياق لا يأتي من اسم شارع فوضوي', () {
      final p = PlaceLocation.fromGeocoding(noArea,
          lat: 33.25, lng: 44.31, poi: 'متوسطة البحتري للبنين');
      // «شارع الشهداء - بغداد - الرشيد» اسم شارع، ليس منطقة
      expect(p.bestLine.contains('شارع الشهداء'), isFalse);
    });
  });
}
