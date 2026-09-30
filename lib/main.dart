// ════════════════════════════════════════════════════════════════════════════
//  مختبر عناوين Google Geocoding  —  Geocode Lab
//
//  • خريطة تفاعلية: اسحب، انقر لنقل الدبوس، اضغط مطوّلاً للفحص الفوري.
//  • بنّاء قوالب: يعرض اسم كل مفتاح مع قيمته، تختار وتلغي وترتّب،
//    ثم تنسخ الناتج أو كود Dart، وتثبّت القالب ليُطبَّق على كل نقطة لاحقة.
//  • تبويب «الرد الكامل»: كل نتيجة بكل مكوّناتها بلا حذف.
//
//  كل شيء في ملف واحد.
// ════════════════════════════════════════════════════════════════════════════

import 'dart:convert';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart' as fm;
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:latlong2/latlong.dart' as ll;
import 'package:shared_preferences/shared_preferences.dart';

/// محرّك الخريطة المستعمَل لاختيار النقطة.
/// `osm` لا يحتاج أي مفتاح — استعمله إن فشل تصريح Maps SDK.
/// `google` يحتاج مفتاحاً مصرَّحاً لـ «Maps SDK for Android».
enum MapEngine { osm, google }

// ─────────────────────────── الإعدادات ───────────────────────────

/// قيمة حارسة فقط — لا تضع مفتاحك هنا، بل في defaultValue بالأسفل.
const String _kPlaceholder = 'PASTE_YOUR_KEY_HERE';

/// مفتاح Google Maps. يمكن تمريره أيضاً هكذا:
/// flutter run --dart-define=MAPS_KEY=AIza...
const String kMapsKey = String.fromEnvironment(
  'MAPS_KEY',
  defaultValue: 'AIzaSyCrnS3xygGKEmuOOFnvYMpX7w0WGplfK94',
);

/// نصف قطر البحث عن المعلم القريب (متر). 400 يكفي للمناطق المتفرّقة
/// حيث لا يوجد شيء داخل 150 متراً.
const int kPoiRadius = 400;

/// Dio منفصل تماماً — بلا Interceptors، حتى لا يُسرَّب توكن تطبيقك إلى Google.
final Dio googleDio = Dio(
  BaseOptions(
    connectTimeout: const Duration(seconds: 20),
    receiveTimeout: const Duration(seconds: 20),
  ),
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = await TemplateStore.load();
  runApp(GeocodeLabApp(store: store));
}

class GeocodeLabApp extends StatelessWidget {
  const GeocodeLabApp({super.key, required this.store});

  final TemplateStore store;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'مختبر العناوين',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1565C0)),
      ),
      builder: (context, child) => Directionality(
        textDirection: TextDirection.rtl,
        child: child!,
      ),
      home: kMapsKey == _kPlaceholder
          ? const SetupScreen()
          : HomeScreen(store: store),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
//  1) النموذج  (Model)
// ════════════════════════════════════════════════════════════════════════════

// ════════════════════════════════════════════════════════════════════════════
//  جودة الاسم — لماذا تظهر أسماء إنجليزية أو فارغة
//
//  Google لا يملك اسماً عربياً لكل معلم، فيرجّع مع `language=ar`:
//   • نصاً لاتينياً حيث لا ترجمة عربية (شائع في أربيل والسليمانية)
//   • "Unnamed Road" للشوارع بلا اسم
//   • كود بلس فقط حيث لا بيانات
//   • أو لا يرجّع الحقل إطلاقاً
//  لذلك لا يكفي أخذ حقل واحد — نجمع كل المرشّحين، نرفض النفاية،
//  ونفضّل العربي الأدق، مع ضمان ألا يعود السطر فارغاً أبداً.
// ════════════════════════════════════════════════════════════════════════════

/// يحتوي حرفاً عربياً واحداً على الأقل.
bool hasArabic(String s) => RegExp(r'[؀-ۿ]').hasMatch(s);

/// لاتيني بحت — لا حرف عربي فيه وفيه حروف لاتينية.
bool isLatinOnly(String s) =>
    !hasArabic(s) && RegExp(r'[A-Za-z]').hasMatch(s);

final RegExp _plusCodeRe =
    RegExp(r'^[23456789CFGHJMPQRVWX]{4,8}\+[23456789CFGHJMPQRVWX]{2,3}$');

/// قيمة لا تصلح اسماً يُعرض للراكب أو السائق.
bool isJunkName(String? v) {
  final s = v?.trim();
  if (s == null || s.isEmpty) return true;
  final low = s.toLowerCase();
  if (low.contains('unnamed')) return true; // Unnamed Road
  if (low == 'null' || low == 'n/a') return true;
  if (_plusCodeRe.hasMatch(s.split(RegExp(r'\s+')).first)) return true;
  // أرقام ورموز فقط بلا أي حرف
  if (!RegExp(r'[؀-ۿA-Za-z]').hasMatch(s)) return true;
  return false;
}

/// مفاتيح تصلح «منطقة» تعطي السياق — الشوارع والمباني ليست منها.
const Set<String> kAreaKeys = {
  'neighborhood',
  'sublocality_level_2',
  'sublocality_level_1',
  'area_nearby',
  'administrative_area_level_3',
  'administrative_area_level_2',
  'locality',
};

/// أفضل معلم من رد Places Nearby: العربي أولاً، ثم الأنواع المعروفة،
/// ثم الأقرب. **أي تغيير هنا يجب أن يُعكَس في [standaloneFetchSupportSource]**.
String? pickBestPoi(List<dynamic> list, double lat, double lng) {
  const knownTypes = {
    'mosque', 'place_of_worship', 'school', 'university', 'hospital',
    'pharmacy', 'supermarket', 'shopping_mall', 'restaurant', 'cafe',
    'gas_station', 'bank', 'park', 'stadium', 'bakery', 'police',
    'bus_station', 'store',
  };

  double score(Map<String, dynamic> r) {
    final name = (r['name'] ?? '').toString();
    if (isJunkName(name)) return -1e9;

    var s = 0.0;
    if (hasArabic(name)) s += 100000; // العربي يتقدّم دائماً
    final types = List<String>.from(r['types'] ?? const []);
    if (types.any(knownTypes.contains)) s += 20000;

    final loc = r['geometry']?['location'];
    if (loc != null) {
      // تقريب مستوٍ يكفي لمئات الأمتار
      final dy = ((loc['lat'] as num).toDouble() - lat) * 111000;
      final dx = ((loc['lng'] as num).toDouble() - lng) *
          111000 *
          math.cos(lat * math.pi / 180);
      s -= math.sqrt(dy * dy + dx * dx); // الأقرب أفضل
    }
    return s;
  }

  Map<String, dynamic>? best;
  var bestScore = -1e8;
  for (final r in list) {
    final m = Map<String, dynamic>.from(r as Map);
    final v = score(m);
    if (v > bestScore) {
      bestScore = v;
      best = m;
    }
  }
  final name = best?['name']?.toString();
  return isJunkName(name) ? null : name;
}

/// مرشّح لاسم المكان، مع درجة دقّته.
class NameCandidate {
  final String key;
  final String value;
  final int rank; // كلما زاد كان أدق

  const NameCandidate({
    required this.key,
    required this.value,
    required this.rank,
  });

  bool get arabic => hasArabic(value);
}

class AddressComponent {
  final String longName;
  final String shortName;
  final List<String> types;

  const AddressComponent({
    required this.longName,
    required this.shortName,
    required this.types,
  });

  factory AddressComponent.fromJson(Map<String, dynamic> json) =>
      AddressComponent(
        longName: (json['long_name'] ?? '').toString(),
        shortName: (json['short_name'] ?? '').toString(),
        types: List<String>.from(json['types'] ?? const []),
      );
}

/// نتيجة واحدة من `results` — محفوظة كاملة بلا حذف.
class GeoResult {
  final List<String> types;
  final String formattedAddress;
  final String placeId;
  final String locationType;
  final double? lat;
  final double? lng;
  final String compoundCode;
  final List<AddressComponent> components;

  const GeoResult({
    required this.types,
    required this.formattedAddress,
    required this.placeId,
    required this.locationType,
    required this.components,
    this.lat,
    this.lng,
    this.compoundCode = '',
  });

  factory GeoResult.fromJson(Map<String, dynamic> j) {
    final loc = j['geometry']?['location'];
    return GeoResult(
      types: List<String>.from(j['types'] ?? const []),
      formattedAddress: (j['formatted_address'] ?? '').toString(),
      placeId: (j['place_id'] ?? '').toString(),
      locationType: (j['geometry']?['location_type'] ?? '').toString(),
      lat: (loc?['lat'] as num?)?.toDouble(),
      lng: (loc?['lng'] as num?)?.toDouble(),
      compoundCode: (j['plus_code']?['compound_code'] ?? '').toString(),
      components: ((j['address_components'] as List?) ?? const [])
          .map((c) => AddressComponent.fromJson(Map<String, dynamic>.from(c)))
          .toList(),
    );
  }

  /// النوع المميّز للنتيجة — يُستعمل كاسم ثابت لمفاتيحها عبر كل النقاط.
  /// `political` وحده لا يميّز شيئاً فيُتخطّى.
  String get primaryType {
    for (final t in types) {
      if (t != 'political') return t;
    }
    return types.isEmpty ? 'result' : types.first;
  }
}

class PlaceLocation {
  final double lat;
  final double lng;

  /// **كل** القيم المتمايزة لكل نوع، مرتّبة من الأخص إلى الأعم.
  /// مثال: `administrative_area_level_2 → [الرشيد, المنصور]`
  final Map<String, List<String>> rawAll;

  /// الأسماء المختصرة لكل نوع (`IQ` مقابل `العراق`).
  final Map<String, String> shortAll;

  /// كل النتائج كما وردت — لتبويب «الرد الكامل».
  final List<GeoResult> results;

  /// من Places API فقط — Geocoding لا يرجّع أسماء معالم.
  final String? poi;
  final String? plusCode;
  final String globalCode;

  /// اسم منطقة التُقط من **نقطة مجاورة** حين لا تملك هذه النقطة اسم منطقة.
  final String? areaHint;

  /// المسافة التي وُجد عندها `areaHint` — مثل «250م».
  final String? areaHintSource;

  const PlaceLocation({
    required this.lat,
    required this.lng,
    required this.rawAll,
    required this.results,
    this.shortAll = const {},
    this.poi,
    this.plusCode,
    this.globalCode = '',
    this.areaHint,
    this.areaHintSource,
  });

  /// `political` بلا معنى للعرض، وكود بلس يُؤخذ من الجذر لا من المكوّنات.
  static const Set<String> skipTypes = {'political'};

  /// المفتاح: امسح **كل** النتائج لا `results[0]` فقط.
  /// النتائج مرتّبة من الأخص إلى الأعم، فأول قيمة لكل نوع هي الأدق،
  /// والقيم التالية تُحفظ كبدائل (`#2`, `#3`) بدل أن تُهمَل.
  factory PlaceLocation.fromGeocoding(
    Map<String, dynamic> body, {
    required double lat,
    required double lng,
    String? poi,
    String? areaHint,
    String? areaHintSource,
  }) {
    final rawResults = (body['results'] as List?) ?? const [];
    final parsed = rawResults
        .map((r) => GeoResult.fromJson(Map<String, dynamic>.from(r as Map)))
        .toList();

    final all = <String, List<String>>{};
    final shorts = <String, String>{};

    for (final r in parsed) {
      for (final comp in r.components) {
        final name = comp.longName.trim();
        if (name.isEmpty) continue;
        for (final t in comp.types) {
          if (skipTypes.contains(t)) continue;
          final list = all.putIfAbsent(t, () => <String>[]);
          if (!list.contains(name)) list.add(name);
          final s = comp.shortName.trim();
          if (s.isNotEmpty) shorts.putIfAbsent(t, () => s);
        }
      }
    }

    final compound = body['plus_code']?['compound_code'] as String?;

    return PlaceLocation(
      lat: lat,
      lng: lng,
      poi: poi,
      rawAll: all,
      shortAll: shorts,
      results: parsed,
      // "9FV5+87 بغداد، العراق" ⇒ الكود هو أول مقطع قبل المسافة
      plusCode: compound?.trim().split(RegExp(r'\s+')).first,
      globalCode: (body['plus_code']?['global_code'] ?? '').toString(),
      areaHint: areaHint,
      areaHintSource: areaHintSource,
    );
  }

  // ─────────────────────── الحقول المسمّاة ───────────────────────

  String? _first(String key) {
    final v = rawAll[key];
    return (v == null || v.isEmpty) ? null : v.first;
  }

  /// أول قيمة لكل نوع — للتوافق مع الكود المولَّد.
  Map<String, String> get raw =>
      {for (final e in rawAll.entries) e.key: e.value.first};

  String? get route {
    final v = cleanRoute(_first('route'));
    return v == null ? null : _stripAdminTail(v);
  }

  /// Google يرجّع أحياناً اسم شارع ملوّثاً بالإدارات:
  /// «شارع الشهداء - بغداد - الرشيد» ⇒ «شارع الشهداء».
  /// نحذف فقط المقاطع التي تطابق قيمة إدارية في نفس الرد،
  /// والفصل يشترط مسافة حول الشرطة حتى لا يُكسر «شارع 544-4».
  String _stripAdminTail(String v) {
    final admins = <String>{
      ...?rawAll['locality'],
      ...?rawAll['administrative_area_level_1'],
      ...?rawAll['administrative_area_level_2'],
      ...?rawAll['administrative_area_level_3'],
      ...?rawAll['country'],
    }.map((e) => e.trim()).where((e) => e.isNotEmpty).toSet();
    if (admins.isEmpty) return v;

    final parts = v.split(RegExp(r'\s+[-–—]\s+'));
    if (parts.length < 2) return v;

    final kept = parts.where((p) => !admins.contains(p.trim())).toList();
    return kept.isEmpty ? v : kept.join(' - ');
  }
  String? get neighborhood => _first('neighborhood');
  String? get subLocality =>
      _first('sublocality_level_1') ?? _first('sublocality');
  String? get locality => _first('locality');
  String? get district => _first('administrative_area_level_2');

  String? get formattedAddress =>
      results.isEmpty ? null : results.first.formattedAddress;
  String? get locationType =>
      results.isEmpty ? null : results.first.locationType;

  /// **كل** قيمة يوفّرها الرد، كمفتاح قابل للاختيار في بنّاء القالب:
  ///
  /// | الشكل | المصدر |
  /// |---|---|
  /// | `route` | `long_name` للمكوّن — أول ظهور (الأدق) |
  /// | `route#2` | القيمة البديلة التالية لنفس النوع |
  /// | `short:country` | `short_name` حين يختلف عن `long_name` (`IQ`) |
  /// | `fmt:route` | `formatted_address` لنتيجة نوعها route |
  /// | `acc:route` | `location_type` لتلك النتيجة |
  /// | `id:route` | `place_id` لتلك النتيجة |
  /// | `lat:route` / `lng:route` | إحداثية مركز تلك النتيجة |
  /// | `types:route` | قائمة أنواع تلك النتيجة |
  /// | `plus:compound` / `plus:global` | كود بلس من جذر الرد |
  /// | `q:lat` / `q:lng` | الإحداثية التي سألتَ عنها |
  ///
  /// أسماء النتائج مبنية على نوعها لا على ترتيبها، فتبقى القوالب صالحة
  /// عبر كل النقاط حتى لو تغيّر ترتيب النتائج.
  ///
  /// **أي تغيير هنا يجب أن يُعكَس في [standaloneHelperSource]** — الكود
  /// المولَّد نسخة حرفية من هذا المنطق، واختبار المطابقة يفرض التطابق.
  Map<String, String> get fields {
    final m = <String, String>{};

    // 0) الاسم المضمون — يرفض النفاية ويفضّل العربي ولا يعود فارغاً
    m['best'] = bestName;
    m['best_line'] = bestLine;
    m['best_src'] = bestSource;
    m['best_lang'] = bestIsArabic ? 'عربي' : 'لاتيني';
    if (areaHint != null && areaHint!.isNotEmpty) {
      m['area_nearby'] = areaHint!;
      m['area_nearby_src'] = areaHintSource ?? '';
    }

    // 0ب) الحقول الذكية: سلاسل بدائل بسيطة
    //     هي ما يقابل place.st / place.nb / place.sub / place.city / place.land
    if (st.isNotEmpty) m['st'] = st;
    m['nb'] = nb; // لا يعود فارغاً أبداً
    if (sub.isNotEmpty) m['sub'] = sub;
    if (city.isNotEmpty) m['city'] = city;
    if (land.isNotEmpty) m['land'] = land;

    if (poi != null && poi!.trim().isNotEmpty) m['poi'] = poi!.trim();

    // 1) مكوّنات العنوان + البدائل
    rawAll.forEach((k, vals) {
      for (var i = 0; i < vals.length; i++) {
        final key = i == 0 ? k : '$k#${i + 1}';
        m[key] = k == 'route' ? (cleanRoute(vals[i]) ?? vals[i]) : vals[i];
      }
    });

    // 2) الأسماء المختصرة حين تختلف فقط (وإلا كانت تكراراً بلا فائدة)
    shortAll.forEach((k, s) {
      if (rawAll[k]?.first != s) m['short:$k'] = s;
    });

    // 3) حقول كل نتيجة، مسمّاة بنوعها
    final used = <String, int>{};
    for (final r in results) {
      var t = r.primaryType;
      final n = (used[t] ?? 0) + 1;
      used[t] = n;
      if (n > 1) t = '$t#$n';

      void put(String field, String? v) {
        final s = v?.trim();
        if (s != null && s.isNotEmpty) m['$field:$t'] = s;
      }

      put('fmt', r.formattedAddress);
      put('acc', r.locationType);
      put('id', r.placeId);
      put('types', r.types.join('/'));
      if (r.lat != null) put('lat', r.lat!.toStringAsFixed(7));
      if (r.lng != null) put('lng', r.lng!.toStringAsFixed(7));
      put('plus', r.compoundCode);
    }

    // 4) كود بلس من الجذر
    if (plusCode != null && plusCode!.isNotEmpty) m['plus:compound'] = plusCode!;
    if (globalCode.isNotEmpty) m['plus:global'] = globalCode;

    // 5) الإحداثية المستعلَم عنها
    m['q:lat'] = lat.toStringAsFixed(7);
    m['q:lng'] = lng.toStringAsFixed(7);

    return m;
  }

  String? value(String key) => fields[key];

  /// "881-63" ليس اسماً مفهوماً للسائق ⇒ "شارع 881-63"
  static String? cleanRoute(String? v) {
    final s = v?.trim();
    if (s == null || s.isEmpty) return null;
    if (s.startsWith('شارع') || s.startsWith('طريق')) return s;
    if (RegExp(r'^[٠-٩0-9\-/ ]+$').hasMatch(s)) return 'شارع $s';
    return s;
  }

  // ─────────────── قيم جاهزة للـ Text (لا ترجع null أبداً) ───────────────

  // ═══════════ الاسم المضمون: لا يعود فارغاً ولا لاتينياً إن وُجد عربي ═══════════

  /// كل الأسماء الصالحة في هذه النقطة مرتّبة من الأدق إلى الأعم،
  /// بعد رفض «Unnamed Road» وأكواد بلس والقيم الرقمية البحتة.
  List<NameCandidate> get nameCandidates {
    final out = <NameCandidate>[];

    void add(String key, String? v, int rank) {
      final s = v?.trim();
      if (s == null || isJunkName(s)) return;
      // لا نكرّر القيمة نفسها، ولا صيغة محتواة في أخرى
      if (out.any((e) => e.value == s)) return;
      out.add(NameCandidate(key: key, value: s, rank: rank));
    }

    add('neighborhood', neighborhood, 90);
    add('sublocality_level_2', _first('sublocality_level_2'), 85);
    add('sublocality_level_1',
        _first('sublocality_level_1') ?? _first('sublocality'), 80);
    // منطقة من نقطة مجاورة: أفضل من تصدير المعلم كأنه اسم منطقة
    add('area_nearby', areaHint, 79);
    // المعلم دون أسماء المناطق: يتصدّر فقط حين لا اسم منطقة إطلاقاً،
    // وعندها يُعرض بصيغة «قرب …» لا كأنه اسم المنطقة.
    add('poi', poi, 78);
    add('premise', _first('premise'), 75);
    add('route', route, 70);
    add('administrative_area_level_3',
        _first('administrative_area_level_3'), 50);
    add('administrative_area_level_2', district, 40);
    add('locality', locality, 30);
    add('administrative_area_level_1',
        _first('administrative_area_level_1'), 10);

    out.sort((a, b) => b.rank.compareTo(a.rank));
    return out;
  }

  /// الأدق بين العربية؛ وإن لم يوجد عربي فالأدق مطلقاً (لاتيني خير من فارغ).
  NameCandidate? get bestCandidate {
    final c = nameCandidates;
    if (c.isEmpty) return null;
    final arabic = c.where((e) => e.arabic).toList();
    return (arabic.isNotEmpty ? arabic : c).first;
  }

  /// اسم المنطقة المضمون — لا يعود فارغاً أبداً.
  String get bestName =>
      bestCandidate?.value ?? (plusCode ?? 'موقع على الخريطة');

  /// من أي حقل جاء الاسم — للتشخيص.
  String get bestSource => bestCandidate?.key ?? 'plus_code';

  /// هل الاسم المختار عربي؟
  bool get bestIsArabic => bestCandidate?.arabic ?? false;

  /// هل تملك هذه النقطة اسم منطقة من بياناتها نفسها؟
  /// إن لم تملك، يُبحث عنه في الجوار بدل تصدير المعلم كأنه منطقة.
  bool get hasLocalArea {
    for (final v in [
      neighborhood,
      _first('sublocality_level_2'),
      _first('sublocality_level_1') ?? _first('sublocality'),
    ]) {
      if (v != null && !isJunkName(v)) return true;
    }
    return false;
  }

  /// السطر النهائي المضمون: منطقة + سياق أوسع + معلم.
  ///
  /// حين لا تملك النقطة اسم منطقة إطلاقاً — ولا جوارها — يتصدّر المعلم
  /// لكن بصيغة «قرب …» لا كأنه اسم منطقة.
  String get bestLine {
    final b = bestCandidate;
    if (b == null) return bestName;

    final head = b.key == 'poi' ? 'قرب ${b.value}' : b.value;
    final out = <String>[head];

    // السياق يأتي من **أنواع المناطق فقط** — لا من أسماء الشوارع،
    // وإلا ظهرت سطور مثل «… شارع الشهداء - بغداد - الرشيد».
    for (final c in nameCandidates) {
      if (c.key == b.key) continue;
      if (!kAreaKeys.contains(c.key)) continue;
      if (c.rank > b.rank) continue;
      if (b.arabic && !c.arabic) continue; // لا نخلط لاتينياً مع عربي
      if (c.value.contains(b.value) || b.value.contains(c.value)) continue;
      out.add(c.value);
      break;
    }

    // المعلم في الذيل، إلا إن كان هو الرأس أصلاً
    final l = poi?.trim();
    if (b.key != 'poi' &&
        l != null &&
        !isJunkName(l) &&
        !out.any((e) => e.contains(l) || l.contains(e))) {
      out.add('قرب $l');
    }
    return out.join('، ');
  }

  String get nb =>
      neighborhood ?? subLocality ?? district ?? locality ?? 'موقع على الخريطة';
  String get sub => subLocality ?? locality ?? district ?? '';
  String get city => locality ?? '';
  String get st => route ?? '';
  String get land => poi ?? '';

  // ─────────────────────── النماذج الجاهزة ───────────────────────

  String get areaName => nb;

  String get title => nb;

  String get subtitle {
    final s = joinParts([
      if (neighborhood != null) subLocality,
      if (neighborhood != null || subLocality != null) locality,
    ]);
    return s.isEmpty ? (plusCode ?? '') : s;
  }

  String get driverAddress {
    final s = joinParts([route, neighborhood, subLocality]);
    return s.isEmpty ? joinParts([areaName, locality]) : s;
  }

  String get landmarkAddress {
    final base = joinParts([neighborhood, subLocality]);
    if (land.isEmpty) return driverAddress;
    return base.isEmpty ? 'قرب $land' : 'قرب $land، $base';
  }

  String get fullAddress {
    var base = joinParts([route, neighborhood, subLocality]);
    if (base.isEmpty) base = joinParts([areaName, locality]); // شبكة أمان
    if (land.isEmpty) return base;
    return '$base  قرب $land';
  }

  /// يدمج الأجزاء ويحذف الفارغ والمكرر — بما فيه التكرار بالاحتواء
  /// ("الجهاد" مع "حي الجهاد" ⇒ تبقى الصيغة الأشمل فقط).
  static String joinParts(List<String?> parts) {
    final out = <String>[];
    for (final p in parts) {
      final v = p?.trim();
      if (v == null || v.isEmpty) continue;
      if (out.any((e) => e.contains(v))) continue;
      out.removeWhere((e) => v.contains(e));
      out.add(v);
    }
    return out.join('، ');
  }
}

// ════════════════════════════════════════════════════════════════════════════
//  2) القوالب  (Templates)
// ════════════════════════════════════════════════════════════════════════════

/// الاسم العربي لكل مفتاح — المفاتيح غير المعروفة تُعرض كما هي.
const Map<String, String> kFieldLabels = {
  // الاسم المضمون
  'best': 'الاسم المضمون ★',
  'best_line': 'السطر المضمون ★',
  'best_src': 'مصدر الاسم',
  'best_lang': 'لغة الاسم',
  'area_nearby': 'منطقة من الجوار ★',
  'area_nearby_src': 'مسافة الجوار',
  // الحقول الذكية (getters بسلسلة بدائل — لا تعود فارغة)
  'st': 'الشارع ⚡',
  'nb': 'اسم المنطقة ⚡',
  'sub': 'المنطقة الأوسع ⚡',
  'city': 'المدينة ⚡',
  'land': 'المعلم ⚡',
  // مفاتيح الرد
  'poi': 'معلم قريب',
  'route': 'الشارع',
  'street_number': 'رقم البناية',
  'neighborhood': 'الحي',
  'sublocality_level_1': 'المنطقة',
  'sublocality_level_2': 'منطقة فرعية',
  'sublocality': 'المنطقة',
  'locality': 'المدينة',
  'administrative_area_level_2': 'القضاء',
  'administrative_area_level_3': 'الناحية',
  'administrative_area_level_1': 'المحافظة',
  'country': 'البلد',
  'premise': 'المبنى',
  'subpremise': 'وحدة',
  'establishment': 'منشأة',
  'point_of_interest': 'معلم',
  'natural_feature': 'معلم طبيعي',
  'airport': 'مطار',
  'park': 'حديقة',
  'postal_code': 'رمز بريدي',
  'plus_code': 'كود بلس',
  'formatted_address': 'العنوان الكامل',
  'location_type': 'دقة الموقع',
};

/// مفاتيح يُنصح بعدم عرضها للمستخدم النهائي.
const Set<String> kDiscouragedBase = {
  'country',
  'administrative_area_level_1',
  'postal_code',
  'plus_code',
  'formatted_address',
  'location_type',
};

/// بادئات تقنية: مفيدة للتشخيص، لا تُعرض للراكب أو السائق.
const Set<String> kTechnicalPrefixes = {'id', 'types', 'acc', 'plus', 'q'};

bool isDiscouraged(String key) {
  final p = keyPrefix(key);
  if (p != null) {
    if (kTechnicalPrefixes.contains(p)) return true;
    // fmt: العنوان الكامل يحوي البلد والمحافظة دائماً
    if (p == 'fmt') return true;
    if (p == 'short') return kDiscouragedBase.contains(baseKey(keyRest(key)!));
    if (p == 'lat' || p == 'lng') return true;
  }
  return kDiscouragedBase.contains(baseKey(key));
}

/// بادئة المفتاح قبل `:` — أو null للمفاتيح البسيطة.
String? keyPrefix(String key) {
  final i = key.indexOf(':');
  return i <= 0 ? null : key.substring(0, i);
}

String? keyRest(String key) {
  final i = key.indexOf(':');
  return i <= 0 ? null : key.substring(i + 1);
}

/// الوصف العربي لكل بادئة.
const Map<String, String> kPrefixLabels = {
  'short': 'مختصر',
  'fmt': 'عنوان كامل',
  'acc': 'دقة',
  'id': 'معرّف',
  'types': 'أنواع',
  'lat': 'خط عرض',
  'lng': 'خط طول',
  'plus': 'كود بلس',
  'q': 'إحداثية الاستعلام',
};

/// الحقول الذكية وسلسلة بدائل كل منها — تُعرض تحت اسم المفتاح.
const Map<String, String> kSmartChain = {
  'best': 'أدق اسم عربي صالح · يرفض Unnamed Road وأكواد بلس',
  'best_line': 'best + منطقة أوسع + قرب معلم',
  'st': 'route',
  'nb': 'neighborhood › sublocality › admin2 › locality',
  'sub': 'sublocality › locality › admin2',
  'city': 'locality',
  'land': 'poi',
};

// ─────────────────────── أدوات توليد الكود المستقل ───────────────────────

/// نصّ Dart حرفي آمن: يهرّب `\` و `'` و `$` وأحرف التحكم ويلفّ بعلامتي `'`.
/// يُستعمل لكل مفتاح وبادئة وفاصل يدخل في الكود المولَّد.
String dartStr(String s) {
  final e = s
      .replaceAll('\\', '\\\\')
      .replaceAll("'", "\\'")
      .replaceAll(r'$', r'\$')
      .replaceAll('\n', r'\n')
      .replaceAll('\r', r'\r')
      .replaceAll('\t', r'\t');
  return "'$e'";
}

const Set<String> _kDartReserved = {
  'abstract', 'as', 'assert', 'async', 'await', 'base', 'break', 'case',
  'catch', 'class', 'const', 'continue', 'covariant', 'default', 'deferred',
  'do', 'dynamic', 'else', 'enum', 'export', 'extends', 'extension',
  'external', 'factory', 'false', 'final', 'finally', 'for', 'function',
  'get', 'hide', 'if', 'implements', 'import', 'in', 'interface', 'is',
  'late', 'library', 'mixin', 'new', 'null', 'of', 'on', 'operator', 'part',
  'required', 'rethrow', 'return', 'sealed', 'set', 'show', 'static',
  'super', 'switch', 'sync', 'this', 'throw', 'true', 'try', 'typedef',
  'var', 'void', 'when', 'while', 'with', 'yield',
};

/// معرّف Dart صالح من اسم القالب: `driver line` ⇒ `driverLine`.
/// الأسماء العربية البحتة تعطي [fallback]؛ ما يبدأ برقم يُسبق بـ `address`؛
/// الكلمات المحجوزة تُلحَق بـ `Line`.
String dartIdentifier(String name, {String fallback = 'formatAddress'}) {
  final words = name
      .replaceAll(RegExp(r'[^a-zA-Z0-9]+'), ' ')
      .trim()
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .toList();
  if (words.isEmpty) return fallback;
  var id = words.first.toLowerCase() +
      words.skip(1).map((w) => w[0].toUpperCase() + w.substring(1)).join();
  if (RegExp(r'^[0-9]').hasMatch(id)) id = 'address$id';
  if (_kDartReserved.contains(id)) id = '${id}Line';
  return id;
}

/// مصدر الصنف المساعد في الكود المولَّد — **نقل حرفي** لـ [PlaceLocation.fields]
/// والـ getters التي تعتمد عليها، بلا أي import.
///
/// أي تغيير في `fields` أو في منطق `PlaceLocation` يجب أن يُعكَس هنا؛
/// اختبار المطابقة في `test/standalone_code_test.dart` يترجم هذا المصدر
/// ويشغّله ويقارن ناتجه بـ `render()` على كل مفتاح.
String standaloneHelperSource(String className) =>
    _kHelperSource.replaceAll('__CLASS__', className);

/// الاستيرادات التي تحتاجها كتلة الجلب — من SDK فقط، لا package.
const String standaloneFetchImports = "import 'dart:convert';\n"
    "import 'dart:io';\n"
    "import 'dart:math' as math;\n";

/// دوال الجلب المشتركة في الكود المولَّد: طلب JSON، اختيار المعلم
/// (نسخة حرفية من [pickBestPoi])، معلم قريب من Places، ومنطقة من الجوار
/// (نسخة حرفية من `_backfillArea` / `_areaAt` في الشاشة الرئيسية).
String standaloneFetchSupportSource(String className) =>
    _kFetchSupportSource.replaceAll('__CLASS__', className);

const String _kFetchSupportSource = r'''
// ─────────── الجلب من Google — نفس ما يفعله Geocode Lab عند «افحص» ───────────
// يحتاج dart:io و dart:convert و dart:math فقط (لا package). لا يعمل على Web.

/// طلب GET يعيد JSON، أو خريطة فارغة عند أي خطأ شبكي.
Future<Map<String, dynamic>> _googleJson(
    String url, Map<String, String> query) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  try {
    final req =
        await client.getUrl(Uri.parse(url).replace(queryParameters: query));
    final res = await req.close().timeout(const Duration(seconds: 20));
    final text = await res.transform(utf8.decoder).join();
    final decoded = jsonDecode(text);
    return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
  } catch (_) {
    return <String, dynamic>{};
  } finally {
    client.close();
  }
}

/// أفضل معلم من رد Places Nearby: العربي أولاً، ثم الأنواع المعروفة،
/// ثم الأقرب.
String? pickBestPoi(List<dynamic> list, double lat, double lng) {
  const knownTypes = {
    'mosque', 'place_of_worship', 'school', 'university', 'hospital',
    'pharmacy', 'supermarket', 'shopping_mall', 'restaurant', 'cafe',
    'gas_station', 'bank', 'park', 'stadium', 'bakery', 'police',
    'bus_station', 'store',
  };

  double score(Map<String, dynamic> r) {
    final name = (r['name'] ?? '').toString();
    if (__CLASS__._isJunkName(name)) return -1e9;

    var s = 0.0;
    if (__CLASS__._hasArabic(name)) s += 100000; // العربي يتقدّم دائماً
    final types = List<String>.from(r['types'] ?? const []);
    if (types.any(knownTypes.contains)) s += 20000;

    final loc = r['geometry']?['location'];
    if (loc != null) {
      // تقريب مستوٍ يكفي لمئات الأمتار
      final dy = ((loc['lat'] as num).toDouble() - lat) * 111000;
      final dx = ((loc['lng'] as num).toDouble() - lng) *
          111000 *
          math.cos(lat * math.pi / 180);
      s -= math.sqrt(dy * dy + dx * dx); // الأقرب أفضل
    }
    return s;
  }

  Map<String, dynamic>? best;
  var bestScore = -1e8;
  for (final r in list) {
    final m = Map<String, dynamic>.from(r as Map);
    final v = score(m);
    if (v > bestScore) {
      bestScore = v;
      best = m;
    }
  }
  final name = best?['name']?.toString();
  return __CLASS__._isJunkName(name) ? null : name;
}

/// اسم معلم قريب (Places Nearby، نصف قطر 400م) — null إن لم يوجد.
/// طلب مُحاسَب أغلى من Geocoding؛ استدعِه فقط حين تحتاج المعلم.
Future<String?> fetchNearbyPoi(
  double lat,
  double lng, {
  required String apiKey,
  String language = 'ar',
}) async {
  final near = await _googleJson(
    'https://maps.googleapis.com/maps/api/place/nearbysearch/json',
    {
      'location': '$lat,$lng',
      'radius': '400',
      'language': language,
      'key': apiKey,
    },
  );
  return pickBestPoi((near['results'] as List?) ?? const [], lat, lng);
}

/// اسم منطقة من الجوار حين لا تملك النقطة اسم منطقة: أربع نقاط على بعد
/// 250م ثم 700م، والاسم الأكثر تكراراً بينها هو الأرجح.
/// كل محاولة = أربعة طلبات Geocoding.
Future<({String name, String source})?> fetchNearbyArea(
  double lat,
  double lng, {
  required String apiKey,
  String language = 'ar',
  String region = 'iq',
}) async {
  for (final meters in const [250.0, 700.0]) {
    final dLat = meters / 111000;
    final dLng = meters / (111000 * math.cos(lat * math.pi / 180));
    final points = [
      (lat + dLat, lng),
      (lat - dLat, lng),
      (lat, lng + dLng),
      (lat, lng - dLng),
    ];
    final names = await Future.wait(
        points.map((p) => _areaAt(p.$1, p.$2, apiKey, language, region)));

    final tally = <String, int>{};
    for (final n in names) {
      if (n != null) tally[n] = (tally[n] ?? 0) + 1;
    }
    if (tally.isNotEmpty) {
      final best =
          tally.entries.reduce((a, b) => b.value > a.value ? b : a).key;
      return (name: best, source: '${meters.round()}م');
    }
  }
  return null;
}

Future<String?> _areaAt(
  double lat,
  double lng,
  String apiKey,
  String language,
  String region,
) async {
  final r = await _googleJson(
    'https://maps.googleapis.com/maps/api/geocode/json',
    {
      'latlng': '$lat,$lng',
      'language': language,
      'region': region,
      'key': apiKey,
    },
  );
  final f = __CLASS__(r, lat: lat, lng: lng);
  final v = f.neighborhood ?? f.subLocality;
  return (v != null && !__CLASS__._isJunkName(v) && __CLASS__._hasArabic(v))
      ? v
      : null;
}
''';

const String _kHelperSource = r'''
/// يستخرج قيم رد Google Geocoding بمنطق Geocode Lab نفسه.
/// مستقل تماماً — لا يحتاج أي package. الصنف نفسه لكل القوالب.
class __CLASS__ {
  __CLASS__(
    Map<String, dynamic> body, {
    String? poi,
    String? areaHint,
    String? areaHintSource,
    double? lat,
    double? lng,
  })  : _poi = poi,
        _areaHint = areaHint {
    // 1) امسح كل النتائج لا results[0]: أول قيمة لكل نوع هي الأدق،
    //    والقيم التالية تُحفظ كبدائل (#2، #3).
    final results = (body['results'] as List?) ?? const [];
    for (final r in results) {
      final comps = ((r as Map)['address_components'] as List?) ?? const [];
      for (final c in comps) {
        final comp = c as Map;
        final name = (comp['long_name'] ?? '').toString().trim();
        if (name.isEmpty) continue;
        final short = (comp['short_name'] ?? '').toString().trim();
        for (final t in List<String>.from(comp['types'] ?? const [])) {
          if (t == 'political') continue;
          final list = _all.putIfAbsent(t, () => <String>[]);
          if (!list.contains(name)) list.add(name);
          if (short.isNotEmpty) _short.putIfAbsent(t, () => short);
        }
      }
    }

    // كود بلس من جذر الرد: "9FV5+87 بغداد، العراق" ⇒ الكود هو أول مقطع
    final compound = body['plus_code']?['compound_code'] as String?;
    _plusCode = compound?.trim().split(RegExp(r'\s+')).first;
    _globalCode = (body['plus_code']?['global_code'] ?? '').toString();

    // 2) ملء الخريطة بالترتيب نفسه الذي يستعمله Geocode Lab
    //    (الإسناد اللاحق يطغى على السابق عند تصادم المفاتيح).
    _m['best'] = bestName;
    _m['best_line'] = bestLine;
    _m['best_src'] = bestSource;
    _m['best_lang'] = bestIsArabic ? 'عربي' : 'لاتيني';
    if (areaHint != null && areaHint.isNotEmpty) {
      _m['area_nearby'] = areaHint;
      _m['area_nearby_src'] = areaHintSource ?? '';
    }
    if (st.isNotEmpty) _m['st'] = st;
    _m['nb'] = nb;
    if (sub.isNotEmpty) _m['sub'] = sub;
    if (city.isNotEmpty) _m['city'] = city;
    if (land.isNotEmpty) _m['land'] = land;
    if (poi != null && poi.trim().isNotEmpty) _m['poi'] = poi.trim();

    _all.forEach((k, vals) {
      for (var i = 0; i < vals.length; i++) {
        final key = i == 0 ? k : '$k#${i + 1}';
        _m[key] = k == 'route' ? (_cleanRoute(vals[i]) ?? vals[i]) : vals[i];
      }
    });

    _short.forEach((k, s) {
      if (_all[k]?.first != s) _m['short:$k'] = s;
    });

    final used = <String, int>{};
    for (final r in results) {
      final res = r as Map;
      final types = List<String>.from(res['types'] ?? const []);
      var t = _primaryType(types);
      final n = (used[t] ?? 0) + 1;
      used[t] = n;
      if (n > 1) t = '$t#$n';

      void put(String field, String? v) {
        final s = v?.trim();
        if (s != null && s.isNotEmpty) _m['$field:$t'] = s;
      }

      final geo = res['geometry'] as Map?;
      final loc = geo?['location'] as Map?;
      put('fmt', (res['formatted_address'] ?? '').toString());
      put('acc', (geo?['location_type'] ?? '').toString());
      put('id', (res['place_id'] ?? '').toString());
      put('types', types.join('/'));
      final rLat = (loc?['lat'] as num?)?.toDouble();
      final rLng = (loc?['lng'] as num?)?.toDouble();
      if (rLat != null) put('lat', rLat.toStringAsFixed(7));
      if (rLng != null) put('lng', rLng.toStringAsFixed(7));
      put('plus',
          ((res['plus_code'] as Map?)?['compound_code'] ?? '').toString());
    }

    final pc = _plusCode;
    if (pc != null && pc.isNotEmpty) _m['plus:compound'] = pc;
    if (_globalCode.isNotEmpty) _m['plus:global'] = _globalCode;

    if (lat != null) _m['q:lat'] = lat.toStringAsFixed(7);
    if (lng != null) _m['q:lng'] = lng.toStringAsFixed(7);
  }

  final Map<String, List<String>> _all = <String, List<String>>{};
  final Map<String, String> _short = <String, String>{};
  final Map<String, String> _m = <String, String>{};
  final String? _poi;
  final String? _areaHint;
  late final String? _plusCode;
  late final String _globalCode;

  /// قيمة مفتاح — null إن لم يوفّرها الرد.
  String? operator [](String key) => _m[key];

  /// كل المفاتيح المتاحة في هذا الرد مع قيمها.
  Map<String, String> get fields => Map.unmodifiable(_m);

  String? _first(String key) {
    final v = _all[key];
    return (v == null || v.isEmpty) ? null : v.first;
  }

  /// النوع المميّز للنتيجة — `political` وحده لا يميّز شيئاً.
  static String _primaryType(List<String> types) {
    for (final t in types) {
      if (t != 'political') return t;
    }
    return types.isEmpty ? 'result' : types.first;
  }

  /// "881-63" ليس اسماً مفهوماً للسائق ⇒ "شارع 881-63"
  static String? _cleanRoute(String? v) {
    final s = v?.trim();
    if (s == null || s.isEmpty) return null;
    if (s.startsWith('شارع') || s.startsWith('طريق')) return s;
    if (RegExp(r'^[٠-٩0-9\-/ ]+$').hasMatch(s)) return 'شارع $s';
    return s;
  }

  /// «شارع الشهداء - بغداد - الرشيد» ⇒ «شارع الشهداء»: تُحذف فقط المقاطع
  /// المطابقة لقيمة إدارية في نفس الرد، والفصل يشترط مسافة حول الشرطة
  /// حتى لا يُكسر «شارع 544-4».
  String _stripAdminTail(String v) {
    final admins = <String>{
      ...?_all['locality'],
      ...?_all['administrative_area_level_1'],
      ...?_all['administrative_area_level_2'],
      ...?_all['administrative_area_level_3'],
      ...?_all['country'],
    }.map((e) => e.trim()).where((e) => e.isNotEmpty).toSet();
    if (admins.isEmpty) return v;

    final parts = v.split(RegExp(r'\s+[-–—]\s+'));
    if (parts.length < 2) return v;

    final kept = parts.where((p) => !admins.contains(p.trim())).toList();
    return kept.isEmpty ? v : kept.join(' - ');
  }

  // ── الحقول المسمّاة ──
  String? get route {
    final v = _cleanRoute(_first('route'));
    return v == null ? null : _stripAdminTail(v);
  }

  String? get neighborhood => _first('neighborhood');
  String? get subLocality =>
      _first('sublocality_level_1') ?? _first('sublocality');
  String? get locality => _first('locality');
  String? get district => _first('administrative_area_level_2');

  /// هل تملك هذه النقطة اسم منطقة من بياناتها نفسها؟
  /// إن لم تملك، يُبحث عنه في الجوار بدل تصدير المعلم كأنه منطقة.
  bool get hasLocalArea {
    for (final v in [
      neighborhood,
      _first('sublocality_level_2'),
      _first('sublocality_level_1') ?? _first('sublocality'),
    ]) {
      if (v != null && !_isJunkName(v)) return true;
    }
    return false;
  }

  // ── الحقول الذكية: سلاسل بدائل ──
  String get nb =>
      neighborhood ?? subLocality ?? district ?? locality ?? 'موقع على الخريطة';
  String get sub => subLocality ?? locality ?? district ?? '';
  String get city => locality ?? '';
  String get st => route ?? '';
  String get land => _poi ?? '';

  // ── الاسم المضمون: لا يعود فارغاً ولا لاتينياً إن وُجد عربي ──
  static bool _hasArabic(String s) => RegExp(r'[؀-ۿ]').hasMatch(s);

  static final RegExp _plusCodeRe =
      RegExp(r'^[23456789CFGHJMPQRVWX]{4,8}\+[23456789CFGHJMPQRVWX]{2,3}$');

  /// قيمة لا تصلح اسماً يُعرض: Unnamed Road، كود بلس، أرقام بحتة…
  static bool _isJunkName(String? v) {
    final s = v?.trim();
    if (s == null || s.isEmpty) return true;
    final low = s.toLowerCase();
    if (low.contains('unnamed')) return true;
    if (low == 'null' || low == 'n/a') return true;
    if (_plusCodeRe.hasMatch(s.split(RegExp(r'\s+')).first)) return true;
    if (!RegExp(r'[؀-ۿA-Za-z]').hasMatch(s)) return true;
    return false;
  }

  /// مفاتيح تصلح «منطقة» تعطي السياق — الشوارع والمباني ليست منها.
  static const Set<String> _areaKeys = {
    'neighborhood',
    'sublocality_level_2',
    'sublocality_level_1',
    'area_nearby',
    'administrative_area_level_3',
    'administrative_area_level_2',
    'locality',
  };

  /// كل الأسماء الصالحة مرتّبة من الأدق إلى الأعم.
  List<({String key, String value, int rank})> get _nameCandidates {
    final out = <({String key, String value, int rank})>[];

    void add(String key, String? v, int rank) {
      final s = v?.trim();
      if (s == null || _isJunkName(s)) return;
      if (out.any((e) => e.value == s)) return;
      out.add((key: key, value: s, rank: rank));
    }

    add('neighborhood', neighborhood, 90);
    add('sublocality_level_2', _first('sublocality_level_2'), 85);
    add('sublocality_level_1',
        _first('sublocality_level_1') ?? _first('sublocality'), 80);
    add('area_nearby', _areaHint, 79);
    add('poi', _poi, 78);
    add('premise', _first('premise'), 75);
    add('route', route, 70);
    add('administrative_area_level_3',
        _first('administrative_area_level_3'), 50);
    add('administrative_area_level_2', district, 40);
    add('locality', locality, 30);
    add('administrative_area_level_1',
        _first('administrative_area_level_1'), 10);

    out.sort((a, b) => b.rank.compareTo(a.rank));
    return out;
  }

  /// الأدق بين العربية؛ وإن لم يوجد عربي فالأدق مطلقاً.
  ({String key, String value, int rank})? get _bestCandidate {
    final c = _nameCandidates;
    if (c.isEmpty) return null;
    final arabic = c.where((e) => _hasArabic(e.value)).toList();
    return (arabic.isNotEmpty ? arabic : c).first;
  }

  /// اسم المنطقة المضمون — لا يعود فارغاً أبداً.
  String get bestName =>
      _bestCandidate?.value ?? (_plusCode ?? 'موقع على الخريطة');

  /// من أي حقل جاء الاسم.
  String get bestSource => _bestCandidate?.key ?? 'plus_code';

  bool get bestIsArabic {
    final b = _bestCandidate;
    return b != null && _hasArabic(b.value);
  }

  /// السطر المضمون: منطقة + سياق أوسع + «قرب معلم».
  String get bestLine {
    final b = _bestCandidate;
    if (b == null) return bestName;

    final head = b.key == 'poi' ? 'قرب ${b.value}' : b.value;
    final out = <String>[head];
    final bArabic = _hasArabic(b.value);

    for (final c in _nameCandidates) {
      if (c.key == b.key) continue;
      if (!_areaKeys.contains(c.key)) continue;
      if (c.rank > b.rank) continue;
      if (bArabic && !_hasArabic(c.value)) continue;
      if (c.value.contains(b.value) || b.value.contains(c.value)) continue;
      out.add(c.value);
      break;
    }

    final l = _poi?.trim();
    if (b.key != 'poi' &&
        l != null &&
        !_isJunkName(l) &&
        !out.any((e) => e.contains(l) || l.contains(e))) {
      out.add('قرب $l');
    }
    return out.join('، ');
  }
}
''';

/// المفتاح بلا لاحقة البديل: `route#2` ⇒ `route`
String baseKey(String key) => key.split('#').first;

String labelFor(String key) {
  final prefix = keyPrefix(key);

  if (prefix != null) {
    final head = kPrefixLabels[prefix] ?? prefix;
    final rest = keyRest(key)!;
    if (prefix == 'plus' && (rest == 'compound' || rest == 'global')) {
      return '$head (${rest == 'compound' ? 'مركّب' : 'عالمي'})';
    }
    if (prefix == 'q') return '$head (${rest == 'lat' ? 'عرض' : 'طول'})';
    return '$head — ${_plainLabel(rest)}';
  }
  return _plainLabel(key);
}

String _plainLabel(String key) {
  final parts = key.split('#');
  final label = kFieldLabels[parts.first] ?? parts.first;
  return parts.length > 1 ? '$label (بديل ${parts[1]})' : label;
}

class TemplatePart {
  String key;
  String prefix;
  bool enabled;

  TemplatePart({required this.key, this.prefix = '', this.enabled = true});

  Map<String, dynamic> toJson() => {'k': key, 'p': prefix, 'e': enabled};

  factory TemplatePart.fromJson(Map<String, dynamic> j) => TemplatePart(
        key: j['k'] as String,
        prefix: (j['p'] ?? '') as String,
        enabled: (j['e'] ?? true) as bool,
      );

  TemplatePart copy() =>
      TemplatePart(key: key, prefix: prefix, enabled: enabled);
}

class AddressTemplate {
  String name;
  String separator;
  bool dedupe;
  List<TemplatePart> parts;

  AddressTemplate({
    required this.name,
    this.separator = '، ',
    this.dedupe = true,
    List<TemplatePart>? parts,
  }) : parts = parts ?? [];

  /// يبني السطر النهائي من نقطة معيّنة.
  String render(PlaceLocation p) {
    final values = <String>[];
    final rendered = <String>[];

    for (final part in parts) {
      if (!part.enabled) continue;
      final v = p.value(part.key)?.trim();
      if (v == null || v.isEmpty) continue;

      if (dedupe) {
        if (values.any((e) => e.contains(v))) continue;
        for (var i = values.length - 1; i >= 0; i--) {
          if (v.contains(values[i])) {
            values.removeAt(i);
            rendered.removeAt(i);
          }
        }
      }
      values.add(v);
      rendered.add('${part.prefix}$v');
    }
    return rendered.join(separator);
  }

  List<String> get activeKeys =>
      parts.where((e) => e.enabled).map((e) => e.key).toList();

  /// يضيف أي مفتاح جديد ظهر في رد لاحق — مطفأً — حتى يبقى متاحاً للاختيار.
  bool absorb(Iterable<String> keys) {
    var changed = false;
    final known = parts.map((e) => e.key).toSet();
    for (final k in keys) {
      if (known.contains(k)) continue;
      parts.add(TemplatePart(key: k, enabled: false));
      known.add(k);
      changed = true;
    }
    return changed;
  }

  // ─────────────────────── توليد الكود ───────────────────────
  //
  // الكود المولَّد مستقل تماماً: دالة واحدة + صنف مساعد بلا أي import،
  // مدخله رد Geocoding الخام. لا يعتمد على PlaceLocation ولا على هذا
  // التطبيق، وناتجه يطابق render() حرفياً — اختبار المطابقة يترجمه
  // ويشغّله فعلاً ويقارن.

  static const Set<String> _kBestKeys = {
    'best',
    'best_line',
    'best_src',
    'best_lang',
  };

  /// ما تحتاجه الدالة المولَّدة من مدخلات غير رد Geocoding.
  ({bool poi, bool area, bool coords}) get standaloneNeeds {
    var poi = false;
    var area = false;
    var coords = false;
    for (final k in activeKeys) {
      if (k.startsWith('q:')) coords = true;
      if (k == 'poi' || k == 'land' || _kBestKeys.contains(k)) poi = true;
      if (k == 'area_nearby' ||
          k == 'area_nearby_src' ||
          _kBestKeys.contains(k)) {
        area = true;
      }
    }
    return (poi: poi, area: area, coords: coords);
  }

  /// اسم الدالة المولَّدة من اسم القالب — `formatAddress` للأسماء العربية.
  String get defaultFunctionName => dartIdentifier(name);

  static String _oneLine(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

  static String _callArgs(({bool poi, bool area, bool coords}) needs) {
    final args = <String>[
      if (needs.poi) 'poi: poi',
      if (needs.area) 'areaHint: areaHint',
      if (needs.area) 'areaHintSource: areaHintSource',
      if (needs.coords) 'lat: lat',
      if (needs.coords) 'lng: lng',
    ];
    return args.isEmpty ? '' : ', ${args.join(', ')}';
  }

  /// الدالة وحدها (بلا الصنف المساعد). منطق `add()` منسوخ حرفياً من [render]:
  /// المقارنة على القيم بلا بادئة، والناتج مع البادئة.
  String standaloneFunction({
    String? functionName,
    String helperName = '_GeoFields',
  }) {
    final fn = functionName ?? defaultFunctionName;
    final needs = standaloneNeeds;
    final params = <String>[
      if (needs.poi) 'String? poi',
      if (needs.area) 'String? areaHint',
      if (needs.area) 'String? areaHintSource',
      if (needs.coords) 'required double lat',
      if (needs.coords) 'required double lng',
    ];
    final sig = params.isEmpty
        ? 'Map<String, dynamic> body'
        : 'Map<String, dynamic> body, {${params.join(', ')}}';

    final enabled = parts.where((e) => e.enabled).toList();
    final b = StringBuffer()
      ..writeln('/// قالب «${_oneLine(name)}» — مولَّد من Geocode Lab.')
      ..writeln('String $fn($sig) {');
    if (enabled.isEmpty) {
      // بلا حقول مفعّلة: لا نصدر متغيّرات غير مستعملة تُنذر بها أداة التحليل
      b
        ..writeln("  return ''; // القالب بلا حقول مفعّلة")
        ..writeln('}');
      return b.toString();
    }
    b
      ..writeln('  final f = $helperName(body${_callArgs(needs)});')
      ..writeln('  final out = <String>[];');
    if (dedupe) b.writeln('  final vals = <String>[];');
    b
      ..writeln("  void add(String? v, [String prefix = '']) {")
      ..writeln('    final s = v?.trim();')
      ..writeln('    if (s == null || s.isEmpty) return;');
    if (dedupe) {
      b
        ..writeln('    // حذف التكرار بالاحتواء: تبقى الصيغة الأشمل فقط')
        ..writeln('    if (vals.any((e) => e.contains(s))) return;')
        ..writeln('    for (var i = vals.length - 1; i >= 0; i--) {')
        ..writeln('      if (s.contains(vals[i])) {')
        ..writeln('        vals.removeAt(i);')
        ..writeln('        out.removeAt(i);')
        ..writeln('      }')
        ..writeln('    }')
        ..writeln('    vals.add(s);');
    }
    b
      ..writeln(r"    out.add('$prefix$s');")
      ..writeln('  }')
      ..writeln();

    for (final part in enabled) {
      final pfx = part.prefix.isEmpty ? '' : ', ${dartStr(part.prefix)}';
      b.writeln('  add(f[${dartStr(part.key)}]$pfx);');
    }

    b
      ..writeln('  return out.join(${dartStr(separator)});')
      ..writeln('}');
    return b.toString();
  }

  /// اسم دالة الجلب المقابلة: `formatAddress` ⇒ `fetchFormatAddress`.
  static String fetchNameFor(String fn) =>
      'fetch${fn[0].toUpperCase()}${fn.substring(1)}';

  /// دالة الجلب: تستدعي Geocoding (+ Places للمعلم إن [fetchPoi]،
  /// + الجوار إن [fetchArea]) ثم تبني القالب — تعادل الضغط على «افحص».
  /// تحتاج [standaloneFetchSupportSource] في الملف نفسه.
  String standaloneFetchFunction({
    String? functionName,
    String helperName = '_GeoFields',
    bool fetchPoi = false,
    bool fetchArea = false,
  }) {
    final fn = functionName ?? defaultFunctionName;
    final needs = standaloneNeeds;
    final poi = fetchPoi && needs.poi;
    final area = fetchArea && needs.area;
    final what = [
      'Geocoding',
      if (poi) 'معلماً قريباً من Places',
      if (area) 'اسم منطقة من الجوار عند غيابه',
    ].join(' + ');
    final args = <String>[
      'body',
      if (poi) 'poi: poi',
      if (area) 'areaHint: areaHint',
      if (area) 'areaHintSource: areaHintSource',
      if (needs.coords) 'lat: lat',
      if (needs.coords) 'lng: lng',
    ];

    final b = StringBuffer()
      ..writeln('/// يستدعي $what ثم يبني قالب «${_oneLine(name)}».')
      ..writeln('/// يعادل الضغط على «افحص» في Geocode Lab.')
      ..writeln('Future<String> ${fetchNameFor(fn)}(')
      ..writeln('  double lat,')
      ..writeln('  double lng, {')
      ..writeln('  required String apiKey,')
      ..writeln("  String language = 'ar',")
      ..writeln("  String region = 'iq',")
      ..writeln('}) async {')
      ..writeln('  final body = await _googleJson(')
      ..writeln("    'https://maps.googleapis.com/maps/api/geocode/json',")
      ..writeln('    {')
      ..writeln(r"      'latlng': '$lat,$lng',")
      ..writeln("      'language': language,")
      ..writeln("      'region': region,")
      ..writeln("      'key': apiKey,")
      ..writeln('    },')
      ..writeln('  );')
      ..writeln("  if (body['status'] != 'OK') {")
      ..writeln('    throw StateError(')
      ..writeln(r"        'Geocoding: ${body['status'] ?? 'NO_RESPONSE'} '")
      ..writeln(r"        '${body['error_message'] ?? ''}');")
      ..writeln('  }');
    if (poi) {
      b
        ..writeln('  final poi = await fetchNearbyPoi(lat, lng,')
        ..writeln('      apiKey: apiKey, language: language);');
    }
    if (area) {
      b
        ..writeln('  String? areaHint;')
        ..writeln('  String? areaHintSource;')
        ..writeln('  // لا اسم منطقة هنا؟ ابحث في الجوار بدل تصدير المعلم كأنه منطقة.')
        ..writeln('  if (!$helperName(body).hasLocalArea) {')
        ..writeln('    final hit = await fetchNearbyArea(lat, lng,')
        ..writeln('        apiKey: apiKey, language: language, region: region);')
        ..writeln('    areaHint = hit?.name;')
        ..writeln('    areaHintSource = hit?.source;')
        ..writeln('  }');
    }
    b
      ..writeln('  return $fn(${args.join(', ')});')
      ..writeln('}');
    return b.toString();
  }

  /// الكود الكامل الذي يُنسخ: رأس توضيحي + الدالة + الصنف المساعد،
  /// وكتلة الجلب إن كان أحد مفتاحَي [fetchPoi] / [fetchArea] مفعّلاً
  /// والقالب يحتاجه.
  String standaloneCode({
    String? functionName,
    String helperName = '_GeoFields',
    bool includeHelper = true,
    bool fetchPoi = false,
    bool fetchArea = false,
  }) {
    final fn = functionName ?? defaultFunctionName;
    final needs = standaloneNeeds;
    final poi = fetchPoi && needs.poi;
    final area = fetchArea && needs.area;
    final fetch = poi || area;
    const bar =
        '// ═══════════════════════════════════════════════════════════════';
    final b = StringBuffer()
      ..writeln(bar)
      ..writeln('//  قالب «${_oneLine(name)}» — كود مستقل مولَّد من Geocode Lab')
      ..writeln('//');
    if (fetch) {
      b
        ..writeln('//  • بلا أي package: يحتاج dart:io و dart:convert و dart:math')
        ..writeln('//    من الـ SDK فقط. الصق الملف كما هو في أي مشروع Dart أو')
        ..writeln('//    Flutter (لا يعمل على Web بسبب dart:io).')
        ..writeln('//  • ${fetchNameFor(fn)} تستدعي Google بنفسها: Geocoding'
            '${poi ? ' + Places Nearby للمعلم' : ''}'
            '${area ? ' + الجوار عند غياب اسم المنطقة' : ''}.')
        ..writeln('//  • $fn تبني السطر من رد Geocoding جاهز إن كنت تجلبه بنفسك.')
        ..writeln('//  • الناتج يطابق معاينة القالب في Geocode Lab حرفياً.')
        ..writeln('//')
        ..writeln('//  الاستعمال:')
        ..writeln("//    final line = await ${fetchNameFor(fn)}(33.28697, 44.29910,")
        ..writeln("//        apiKey: 'AIza...');")
        ..writeln('//    Text(line);');
      if (poi) {
        b.writeln('//  • المعلم: طلب Places مُحاسَب أغلى من Geocoding مع كل نداء.');
      }
      if (area) {
        b.writeln('//  • الجوار: حتى 8 طلبات Geocoding إضافية، فقط حين لا تملك '
            'النقطة اسم منطقة.');
      }
    } else {
      b
        ..writeln('//  • بلا أي اعتماد خارجي (لا package ولا استيراد): الصق الملف')
        ..writeln('//    كما هو في أي مشروع Dart أو Flutter.')
        ..writeln('//  • المدخل: رد Google Geocoding API الخام بعد jsonDecode.')
        ..writeln('//  • الناتج يطابق معاينة القالب في Geocode Lab حرفياً.')
        ..writeln('//')
        ..writeln('//  الاستعمال:')
        ..writeln('//    final body = jsonDecode(response) as Map<String, dynamic>;')
        ..writeln('//    Text($fn(body${_callArgs(needs)}));');
      if (needs.poi) {
        b.writeln('//  • poi: اسم المعلم القريب من Places API — اختياري، '
            'لا تمرّره إن لم تملكه.');
      }
      if (needs.area) {
        b.writeln('//  • areaHint / areaHintSource: اسم منطقة من نقطة مجاورة '
            'ومسافتها — اختياريان.');
      }
    }
    if (needs.coords) {
      b.writeln('//  • lat / lng: إحداثية الاستعلام نفسها التي أرسلتها '
          'إلى Geocoding.');
    }
    b
      ..writeln('//  • الصنف $helperName${fetch ? ' ودوال الجلب' : ''} '
          'واحد لكل القوالب: عند لصق أكثر من')
      ..writeln('//    قالب في ملف واحد أبقِ نسخة واحدة منه.')
      ..writeln(bar)
      ..writeln();
    if (fetch) {
      b
        ..writeln(standaloneFetchImports)
        ..write(standaloneFetchFunction(
          functionName: fn,
          helperName: helperName,
          fetchPoi: poi,
          fetchArea: area,
        ))
        ..writeln();
    }
    b.write(standaloneFunction(functionName: fn, helperName: helperName));
    if (includeHelper) {
      b
        ..writeln()
        ..write(standaloneHelperSource(helperName));
      if (fetch) {
        b
          ..writeln()
          ..write(standaloneFetchSupportSource(helperName));
      }
    }
    return b.toString();
  }

  /// مقطع الاستعمال القصير الذي يُعرض فوق الكود.
  String usageCode({bool fetchPoi = false, bool fetchArea = false}) {
    final needs = standaloneNeeds;
    final fn = defaultFunctionName;
    final b = StringBuffer();
    if ((fetchPoi && needs.poi) || (fetchArea && needs.area)) {
      b
        ..writeln('// تستدعي Google بنفسها (Geocoding'
            '${fetchPoi && needs.poi ? ' + Places' : ''}'
            '${fetchArea && needs.area ? ' + الجوار' : ''}) ثم تبني السطر:')
        ..writeln('final line = await ${fetchNameFor(fn)}(lat, lng, '
            "apiKey: 'AIza...');")
        ..writeln('Text(line);');
      return b.toString();
    }
    final args = <String>[
      if (needs.poi) 'poi: nearbyPlaceName',
      if (needs.area) 'areaHint: nearbyAreaName',
      if (needs.area) "areaHintSource: '250م'",
      if (needs.coords) 'lat: lat',
      if (needs.coords) 'lng: lng',
    ];
    b
      ..writeln('// بعد استدعاء Geocoding API بأي عميل (http أو dio):')
      ..writeln('final body = jsonDecode(response) as Map<String, dynamic>;')
      ..writeln('final line = $fn(body'
          '${args.isEmpty ? '' : ', ${args.join(', ')}'});')
      ..writeln('Text(line);');
    if (needs.poi || needs.area) {
      b.writeln('// poi و areaHint اختياريان — احذفهما إن لم تملكهما.');
    }
    return b.toString();
  }

  // ─────────────────────── التخزين ───────────────────────

  Map<String, dynamic> toJson() => {
        'name': name,
        'sep': separator,
        'dedupe': dedupe,
        'parts': parts.map((e) => e.toJson()).toList(),
      };

  factory AddressTemplate.fromJson(Map<String, dynamic> j) => AddressTemplate(
        name: (j['name'] ?? 'قالب') as String,
        separator: (j['sep'] ?? '، ') as String,
        dedupe: (j['dedupe'] ?? true) as bool,
        parts: ((j['parts'] as List?) ?? const [])
            .map((e) => TemplatePart.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
      );

  AddressTemplate copy({String? name}) => AddressTemplate(
        name: name ?? '${this.name} (نسخة)',
        separator: separator,
        dedupe: dedupe,
        parts: parts.map((e) => e.copy()).toList(),
      );

  static List<AddressTemplate> defaults() => [
        // الافتراضي: لا يعود فارغاً ولا لاتينياً إن وُجد عربي
        AddressTemplate(
          name: 'الاسم المضمون',
          parts: [TemplatePart(key: 'best_line')],
        ),
        AddressTemplate(
          name: 'سطر السائق',
          parts: [
            TemplatePart(key: 'route'),
            TemplatePart(key: 'neighborhood'),
            TemplatePart(key: 'sublocality_level_1'),
          ],
        ),
        AddressTemplate(
          name: 'مختصر',
          parts: [
            TemplatePart(key: 'neighborhood'),
            TemplatePart(key: 'sublocality_level_1'),
          ],
        ),
        AddressTemplate(
          name: 'مع المعلم',
          parts: [
            TemplatePart(key: 'route'),
            TemplatePart(key: 'neighborhood'),
            TemplatePart(key: 'sublocality_level_1'),
            TemplatePart(key: 'poi', prefix: 'قرب '),
          ],
        ),
        // يقابل: "${place.st}، ${place.nb}، ${place.sub}  قرب ${place.land}"
        AddressTemplate(
          name: 'الحقول الذكية',
          parts: [
            TemplatePart(key: 'st'),
            TemplatePart(key: 'nb'),
            TemplatePart(key: 'sub'),
            TemplatePart(key: 'land', prefix: 'قرب '),
          ],
        ),
      ];
}

class TemplateStore extends ChangeNotifier {
  static const _key = 'templates_v2';

  final SharedPreferences _prefs;
  List<AddressTemplate> templates;
  int activeIndex;

  TemplateStore._(this._prefs, this.templates, this.activeIndex);

  static Future<TemplateStore> load() async {
    final prefs = await SharedPreferences.getInstance();
    List<AddressTemplate> list;
    try {
      final raw = prefs.getString(_key);
      list = raw == null
          ? AddressTemplate.defaults()
          : (jsonDecode(raw) as List)
              .map((e) => AddressTemplate.fromJson(Map<String, dynamic>.from(e)))
              .toList();
      if (list.isEmpty) list = AddressTemplate.defaults();

      // ترقية: من حفظ قوالبه قبل وجود «الاسم المضمون» يحصل عليه
      // بلا أن يفقد قوالبه.
      if (!list.any((t) => t.parts.any((p) => p.key == 'best_line'))) {
        list.insert(
          0,
          AddressTemplate(
            name: 'الاسم المضمون',
            parts: [TemplatePart(key: 'best_line')],
          ),
        );
      }
    } catch (_) {
      list = AddressTemplate.defaults();
    }
    return TemplateStore._(prefs, list, 0);
  }

  AddressTemplate get active =>
      templates[activeIndex.clamp(0, templates.length - 1)];

  Future<void> save() async {
    await _prefs.setString(
      _key,
      jsonEncode(templates.map((e) => e.toJson()).toList()),
    );
    notifyListeners();
  }

  void setActive(int i) {
    activeIndex = i.clamp(0, templates.length - 1);
    notifyListeners();
  }

  Future<void> add(AddressTemplate t) async {
    templates.add(t);
    activeIndex = templates.length - 1;
    await save();
  }

  Future<void> remove(int i) async {
    if (templates.length <= 1) return;
    templates.removeAt(i);
    if (activeIndex >= templates.length) activeIndex = templates.length - 1;
    await save();
  }

  Future<void> absorbKeys(Iterable<String> keys) async {
    var changed = false;
    for (final t in templates) {
      if (t.absorb(keys)) changed = true;
    }
    if (changed) await save();
  }
}

// ════════════════════════════════════════════════════════════════════════════
//  3) الملخّص  (Digest)
// ════════════════════════════════════════════════════════════════════════════

String buildDigest(
  PlaceLocation p,
  Map<String, dynamic> body, {
  String? label,
  String? poiStatus,
  List<AddressTemplate> templates = const [],
}) {
  final b = StringBuffer()
    ..writeln('════ ${label ?? ''} '
        '${p.lat.toStringAsFixed(5)}, ${p.lng.toStringAsFixed(5)}')
    ..writeln('status : ${body['status']}   results: ${p.results.length}'
        '${poiStatus == null ? '' : '   places: $poiStatus'}');

  for (var i = 0; i < p.results.length; i++) {
    final r = p.results[i];
    b.writeln('[$i] ${r.types.join('/')}'
        '${r.locationType.isEmpty ? '' : ' · ${r.locationType}'}');
  }

  p.fields.forEach((k, v) => b.writeln('${k.padRight(28)}: $v'));

  for (final t in templates) {
    final line = t.render(p);
    b.writeln('⟦${t.name}⟧ ${line.isEmpty ? '(فارغ)' : line}');
  }
  return b.toString();
}

// ════════════════════════════════════════════════════════════════════════════
//  4) نقاط اختبار جاهزة
// ════════════════════════════════════════════════════════════════════════════

class Preset {
  final String name;
  final double lat;
  final double lng;
  const Preset(this.name, this.lat, this.lng);
}

const List<Preset> kPresets = [
  Preset('مدينة الصدر', 33.39327, 44.45821),
  Preset('حي الجهاد', 33.28697, 44.29910),
  Preset('الكرادة', 33.30500, 44.42000),
  Preset('المنصور', 33.31200, 44.33000),
  Preset('طريق سريع', 33.34000, 44.42500),
  Preset('أطراف بغداد', 33.19000, 44.25000),
  Preset('البصرة', 30.50850, 47.78040),
  Preset('الموصل', 36.34000, 43.13000),
  Preset('أربيل', 36.19110, 44.00920),
  Preset('كربلاء', 32.61600, 44.02490),
  Preset('النجف', 31.99600, 44.31600),
];

// ════════════════════════════════════════════════════════════════════════════
//  5) الشاشة الرئيسية
// ════════════════════════════════════════════════════════════════════════════

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.store});

  final TemplateStore store;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin {
  /// ثابت عبر إعادات البناء، وإلا قفزت القائمة للأعلى بعد كل نقرة.
  late final TabController _tabs = TabController(length: 4, vsync: this);

  GoogleMapController? _map;
  final fm.MapController _osm = fm.MapController();

  /// OSM افتراضياً: يعمل بلا مفتاح، فلا يوقفك تصريح Maps SDK.
  MapEngine _engine = MapEngine.osm;

  LatLng _center = const LatLng(33.39327, 44.45821);
  double _zoomLevel = 16;
  String _label = 'مدينة الصدر';
  MapType _mapType = MapType.normal;
  bool _satellite = false;
  bool _mapReady = true; // OSM جاهزة فوراً؛ Google تضبطها في onMapCreated

  PlaceLocation? _place;
  String _lastJson = '';
  String _statusLine = 'حرّك الخريطة ثم اضغط «افحص».';
  final List<String> _samples = [];

  bool _loading = false;
  bool _withPoi = false;

  /// البحث عن اسم المنطقة في الجوار حين تفتقده النقطة — يكلّف طلبات إضافية.
  bool _areaBackfill = true;
  double _panel = 0.45;

  // فلترة قائمة المفاتيح في بنّاء القالب
  String _fieldQuery = '';
  bool _onlyAvailable = true;

  final _coordCtrl = TextEditingController();

  TemplateStore get store => widget.store;

  @override
  void dispose() {
    _tabs.dispose();
    _coordCtrl.dispose();
    _map?.dispose();
    super.dispose();
  }

  // ─────────────────────────── الفحص ───────────────────────────

  Future<void> _probe() async {
    if (_loading) return;
    setState(() => _loading = true);

    try {
      final geo = await googleDio.get<Map<String, dynamic>>(
        'https://maps.googleapis.com/maps/api/geocode/json',
        queryParameters: {
          'latlng': '${_center.latitude},${_center.longitude}',
          'language': 'ar',
          'region': 'iq',
          'key': kMapsKey,
        },
      );
      final body = geo.data ?? <String, dynamic>{};

      if (body['status'] != 'OK') {
        setState(() => _statusLine =
            'Geocoding: ${body['status']} — ${body['error_message'] ?? ''}');
        return;
      }

      String? poi;
      String? poiStatus;
      if (_withPoi) {
        try {
          final near = await googleDio.get<Map<String, dynamic>>(
            'https://maps.googleapis.com/maps/api/place/nearbysearch/json',
            queryParameters: {
              'location': '${_center.latitude},${_center.longitude}',
              'radius': kPoiRadius,
              'language': 'ar',
              'key': kMapsKey,
            },
          );
          poiStatus = near.data?['status']?.toString();
          final list = (near.data?['results'] as List?) ?? const [];
          poi = pickBestPoi(list, _center.latitude, _center.longitude);
        } catch (_) {
          poiStatus = 'ERR';
        }
      }

      var place = PlaceLocation.fromGeocoding(
        body,
        lat: _center.latitude,
        lng: _center.longitude,
        poi: poi,
      );

      // لا اسم منطقة هنا؟ ابحث في الجوار بدل تصدير المعلم كأنه منطقة.
      if (_areaBackfill && !place.hasLocalArea) {
        final hit = await _backfillArea(_center.latitude, _center.longitude);
        if (hit != null) {
          place = PlaceLocation.fromGeocoding(
            body,
            lat: _center.latitude,
            lng: _center.longitude,
            poi: poi,
            areaHint: hit.name,
            areaHintSource: hit.source,
          );
        }
      }

      await store.absorbKeys(place.fields.keys);

      _samples.add(buildDigest(place, body,
          label: _label, poiStatus: poiStatus, templates: store.templates));

      setState(() {
        _place = place;
        _statusLine = '${place.bestIsArabic ? '✓' : '⚠ لاتيني'} '
            '${place.bestName}  ·  من ${place.bestSource}'
            '${place.areaHintSource == null ? '' : ' (${place.areaHintSource})'}'
            '  ·  '
            '${place.results.length} نتيجة · ${place.fields.length} مفتاح'
            '${poiStatus == null ? '' : ' · places: $poiStatus'}';
        _lastJson = const JsonEncoder.withIndent('  ').convert(body);
        if (_panel < 0.3) _panel = 0.45;
      });
    } on DioException catch (e) {
      setState(() => _statusLine = 'فشل الاتصال: ${e.message}');
    } catch (e) {
      setState(() => _statusLine = 'خطأ: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ═══════════ البحث عن اسم المنطقة في الجوار ═══════════

  /// نتائج البحث الجواري، مخزّنة بإحداثية مقرّبة حتى لا تتكرر الطلبات.
  final Map<String, ({String name, String source})?> _areaCache = {};

  /// أربع نقاط حول المركز على مسافة [m] متراً.
  List<(double, double)> _ring(double lat, double lng, double m) {
    final dLat = m / 111000;
    final dLng = m / (111000 * math.cos(lat * math.pi / 180));
    return [
      (lat + dLat, lng),
      (lat - dLat, lng),
      (lat, lng + dLng),
      (lat, lng - dLng),
    ];
  }

  /// اسم المنطقة عند نقطة واحدة — عربي وصالح فقط.
  Future<String?> _areaAt(double lat, double lng) async {
    try {
      final r = await googleDio.get<Map<String, dynamic>>(
        'https://maps.googleapis.com/maps/api/geocode/json',
        queryParameters: {
          'latlng': '$lat,$lng',
          'language': 'ar',
          'region': 'iq',
          'key': kMapsKey,
        },
      );
      final p = PlaceLocation.fromGeocoding(r.data ?? {}, lat: lat, lng: lng);
      final v = p.neighborhood ?? p.subLocality;
      return (v != null && !isJunkName(v) && hasArabic(v)) ? v : null;
    } catch (_) {
      return null;
    }
  }

  /// يوسّع دائرة البحث حتى يجد اسم منطقة: 250م ثم 700م.
  /// يُنفَّذ فقط حين لا تملك النقطة نفسها اسم منطقة.
  Future<({String name, String source})?> _backfillArea(
      double lat, double lng) async {
    final key = '${lat.toStringAsFixed(3)},${lng.toStringAsFixed(3)}';
    if (_areaCache.containsKey(key)) return _areaCache[key];

    for (final meters in const [250.0, 700.0]) {
      final points = _ring(lat, lng, meters);
      final names =
          await Future.wait(points.map((p) => _areaAt(p.$1, p.$2)));

      // الاسم الأكثر تكراراً بين الجهات الأربع هو الأرجح
      final tally = <String, int>{};
      for (final n in names) {
        if (n != null) tally[n] = (tally[n] ?? 0) + 1;
      }
      if (tally.isNotEmpty) {
        final best =
            tally.entries.reduce((a, b) => b.value > a.value ? b : a).key;
        final hit = (name: best, source: '${meters.round()}م');
        _areaCache[key] = hit;
        return hit;
      }
    }
    _areaCache[key] = null;
    return null;
  }

  /// يختار المعلم الأنسب: عربي الاسم أولاً، ثم نوعاً يعرفه الناس
  /// (جامع، مدرسة، مستشفى…)، ثم الأقرب مسافةً — لا مجرّد أول نتيجة.
  // اختيار أفضل معلم: انظر pickBestPoi على مستوى الملف — يُنسخ حرفياً
  // إلى الكود المولَّد ويُختبر تطابقه.

  // ─────────────────────────── أدوات ───────────────────────────

  void _moveTo(double lat, double lng, String label, {double? zoom}) {
    setState(() {
      _center = LatLng(lat, lng);
      _label = label;
      if (zoom != null) _zoomLevel = zoom;
    });

    if (_engine == MapEngine.google) {
      _map?.animateCamera(
        zoom == null
            ? CameraUpdate.newLatLng(_center)
            : CameraUpdate.newLatLngZoom(_center, zoom),
      );
    } else {
      _osm.move(ll.LatLng(lat, lng), zoom ?? _zoomLevel);
    }
  }

  void _zoomBy(double delta) {
    if (_engine == MapEngine.google) {
      _map?.animateCamera(
          delta > 0 ? CameraUpdate.zoomIn() : CameraUpdate.zoomOut());
    } else {
      final z = (_zoomLevel + delta).clamp(2.0, 19.0).toDouble();
      setState(() => _zoomLevel = z);
      _osm.move(ll.LatLng(_center.latitude, _center.longitude), z);
    }
  }

  void _goToTyped() {
    final raw = _coordCtrl.text.replaceAll(RegExp(r'[^0-9\.\-,]'), '');
    final parts = raw.split(',');
    if (parts.length != 2) return;
    final lat = double.tryParse(parts[0]);
    final lng = double.tryParse(parts[1]);
    if (lat == null || lng == null) return;
    FocusScope.of(context).unfocus();
    _moveTo(lat, lng, 'يدوي', zoom: 16);
  }

  void _copy(String text, String msg) {
    if (text.isEmpty) return;
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 1)),
    );
  }

  // ─────────────────────────── البناء ───────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: SafeArea(
        // الارتفاع يُحسب من المساحة المتاحة فعلاً لا من ارتفاع الشاشة،
        // وإلا تجاوزت الأعمدةُ الحدَّ عند ظهور لوحة المفاتيح.
        child: LayoutBuilder(
          builder: (context, c) {
            final panelH = (c.maxHeight * _panel).clamp(90.0, c.maxHeight - 200);
            return Column(
              children: [
                _topBar(),
                Expanded(child: _mapArea()),
                _dragHandle(),
                SizedBox(
                  height: panelH,
                  child: ListenableBuilder(
                    listenable: store,
                    builder: (_, __) => _panelTabs(),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  // ── الشريط العلوي ──

  Widget _topBar() => Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _coordCtrl,
                    textDirection: TextDirection.ltr,
                    keyboardType: const TextInputType.numberWithOptions(
                        decimal: true, signed: true),
                    onSubmitted: (_) => _goToTyped(),
                    decoration: const InputDecoration(
                      isDense: true,
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.my_location, size: 18),
                      hintText: '33.28697, 44.29910',
                    ),
                  ),
                ),
                IconButton(
                  onPressed: _goToTyped,
                  icon: const Icon(Icons.arrow_circle_left_outlined),
                  tooltip: 'اذهب',
                ),
                IconButton(
                  onPressed: () => _copy(
                    _samples.join('\n'),
                    'نُسخت ${_samples.length} عيّنة',
                  ),
                  icon: Badge(
                    isLabelVisible: _samples.isNotEmpty,
                    label: Text('${_samples.length}'),
                    child: const Icon(Icons.copy_all),
                  ),
                  tooltip: 'نسخ كل العيّنات',
                ),
              ],
            ),
            SizedBox(
              height: 40,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: kPresets.length,
                separatorBuilder: (_, __) => const SizedBox(width: 6),
                itemBuilder: (_, i) {
                  final p = kPresets[i];
                  return ActionChip(
                    visualDensity: VisualDensity.compact,
                    label: Text(p.name, style: const TextStyle(fontSize: 11.5)),
                    onPressed: () => _moveTo(p.lat, p.lng, p.name, zoom: 16),
                  );
                },
              ),
            ),
          ],
        ),
      );

  // ── الخريطة ──

  Widget _mapArea() => Stack(
        alignment: Alignment.center,
        children: [
          if (_engine == MapEngine.google) _googleMap() else _osmMap(),
          IgnorePointer(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 34),
              child: Icon(
                Icons.location_on,
                size: 46,
                color: _loading ? Colors.orange : const Color(0xFFD32F2F),
                shadows: const [Shadow(blurRadius: 6, color: Colors.black38)],
              ),
            ),
          ),
          Positioned(
            left: 8,
            bottom: 8,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _mapBtn(Icons.add, () => _zoomBy(1)),
                const SizedBox(height: 6),
                _mapBtn(Icons.remove, () => _zoomBy(-1)),
                const SizedBox(height: 6),
                _mapBtn(
                  _satellite ? Icons.map : Icons.satellite_alt,
                  () => setState(() {
                    _satellite = !_satellite;
                    _mapType = _satellite ? MapType.hybrid : MapType.normal;
                  }),
                ),
                const SizedBox(height: 6),
                // تبديل محرّك الخريطة: OSM بلا مفتاح، أو Google عند تصريحه.
                Material(
                  color: _engine == MapEngine.osm
                      ? const Color(0xFF2E7D32)
                      : const Color(0xFF1565C0),
                  shape: const StadiumBorder(),
                  elevation: 2,
                  child: InkWell(
                    customBorder: const StadiumBorder(),
                    onTap: () => setState(() {
                      _engine = _engine == MapEngine.osm
                          ? MapEngine.google
                          : MapEngine.osm;
                      _mapReady = _engine == MapEngine.osm;
                    }),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 7),
                      child: Text(
                        _engine == MapEngine.osm ? 'OSM' : 'Google',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            top: 8,
            child: Card(
              color: Colors.black.withValues(alpha: 0.72),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                child: Text(
                  '${_center.latitude.toStringAsFixed(5)}, '
                  '${_center.longitude.toStringAsFixed(5)}'
                  '${_mapReady ? '' : '  ·  الخريطة لم تُحمَّل'}',
                  textDirection: TextDirection.ltr,
                  style: TextStyle(
                    color: _mapReady ? Colors.white : Colors.orange,
                    fontSize: 11.5,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            right: 8,
            bottom: 8,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text('POI', style: TextStyle(fontSize: 11)),
                            Switch(
                              value: _withPoi,
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                              onChanged: (v) => setState(() => _withPoi = v),
                            ),
                          ],
                        ),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text('جوار',
                                style: TextStyle(fontSize: 11)),
                            Switch(
                              value: _areaBackfill,
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                              onChanged: (v) =>
                                  setState(() => _areaBackfill = v),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                FloatingActionButton.extended(
                  onPressed: _loading ? null : _probe,
                  icon: _loading
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.travel_explore),
                  label: const Text('افحص'),
                ),
              ],
            ),
          ),
        ],
      );

  // ── خريطة OpenStreetMap: لا تحتاج أي مفتاح ──

  Widget _osmMap() => fm.FlutterMap(
        mapController: _osm,
        options: fm.MapOptions(
          initialCenter: ll.LatLng(_center.latitude, _center.longitude),
          initialZoom: _zoomLevel,
          minZoom: 2,
          maxZoom: 19,
          onTap: (_, p) => _moveTo(p.latitude, p.longitude, 'نقرة'),
          onLongPress: (_, p) {
            _moveTo(p.latitude, p.longitude, 'ضغطة');
            _probe();
          },
          onPositionChanged: (camera, hasGesture) {
            _center = LatLng(camera.center.latitude, camera.center.longitude);
            _zoomLevel = camera.zoom;
            if (hasGesture) setState(() {});
          },
        ),
        children: [
          fm.TileLayer(
            urlTemplate: _satellite
                ? 'https://server.arcgisonline.com/ArcGIS/rest/services/'
                    'World_Imagery/MapServer/tile/{z}/{y}/{x}'
                : 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
            userAgentPackageName: 'com.geocodelab.geocode_lab',
            maxNativeZoom: 19,
          ),
          const Align(
            alignment: Alignment.bottomLeft,
            child: Padding(
              padding: EdgeInsets.only(left: 4, bottom: 2),
              child: Text(
                '© OpenStreetMap',
                style: TextStyle(fontSize: 9, color: Colors.black54),
              ),
            ),
          ),
        ],
      );

  // ── خريطة Google: تحتاج مفتاحاً مصرَّحاً لـ Maps SDK for Android ──

  Widget _googleMap() => GoogleMap(
        initialCameraPosition: CameraPosition(target: _center, zoom: _zoomLevel),
        mapType: _mapType,
        onMapCreated: (c) {
          _map = c;
          if (mounted) setState(() => _mapReady = true);
        },
        onCameraMove: (pos) {
          _center = pos.target;
          _zoomLevel = pos.zoom;
        },
        onCameraIdle: () => setState(() {}),
        onTap: (pos) => _moveTo(pos.latitude, pos.longitude, 'نقرة'),
        onLongPress: (pos) {
          _moveTo(pos.latitude, pos.longitude, 'ضغطة');
          _probe();
        },
        // يمنع تنازع الإيماءات مع الأعمدة والقوائم المحيطة:
        // الخريطة تفوز بالسحب فوراً بدل انتظار حسم الـ gesture arena.
        gestureRecognizers: <Factory<OneSequenceGestureRecognizer>>{
          Factory<OneSequenceGestureRecognizer>(() => EagerGestureRecognizer()),
        },
        myLocationButtonEnabled: false,
        zoomControlsEnabled: false,
        mapToolbarEnabled: false,
      );

  Widget _mapBtn(IconData icon, VoidCallback onTap) => Material(
        color: Colors.white,
        shape: const CircleBorder(),
        elevation: 2,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Icon(icon, size: 20, color: Colors.black87),
          ),
        ),
      );

  // ── مقبض تغيير ارتفاع اللوحة ──

  Widget _dragHandle() => GestureDetector(
        onVerticalDragUpdate: (d) {
          final h = MediaQuery.of(context).size.height;
          setState(() =>
              _panel = (_panel - d.delta.dy / h).clamp(0.12, 0.85).toDouble());
        },
        onDoubleTap: () => setState(() => _panel = _panel > 0.5 ? 0.3 : 0.8),
        child: Container(
          width: double.infinity,
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Column(
            children: [
              Container(
                width: 44,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade500,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 3),
              Text(_statusLine,
                  style: const TextStyle(fontSize: 11),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            ],
          ),
        ),
      );

  // ── اللوحة السفلية ──

  Widget _panelTabs() => Column(
        children: [
          TabBar(
            controller: _tabs,
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            labelStyle: const TextStyle(fontSize: 12.5),
            tabs: const [
              Tab(text: 'بنّاء القالب', height: 38),
              Tab(text: 'القوالب', height: 38),
              Tab(text: 'الرد الكامل', height: 38),
              Tab(text: 'الملخّص', height: 38),
            ],
          ),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: [
                _builderTab(),
                _templatesTab(),
                _rawTab(),
                _digestTab(),
              ],
            ),
          ),
        ],
      );

  // ═══ التبويب ١: بنّاء القالب ═══

  Widget _builderTab() {
    final t = store.active;
    final place = _place;

    if (place == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(20),
          child: Text(
            'افحص نقطة أولاً لتظهر المفاتيح وقيمها.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    final available = place.fields;

    // المفتاح يظهر إن كان مفعّلاً (دائماً)، أو مطابقاً للبحث،
    // أو متوفراً في هذه النقطة حين يكون «المتوفر فقط» مشغّلاً.
    bool visible(TemplatePart p) {
      if (p.enabled) return true;
      if (_onlyAvailable && !available.containsKey(p.key)) return false;
      if (_fieldQuery.isEmpty) return true;
      final q = _fieldQuery.toLowerCase();
      return p.key.toLowerCase().contains(q) ||
          labelFor(p.key).contains(_fieldQuery) ||
          (available[p.key] ?? '').contains(_fieldQuery);
    }

    final shown = <int>[
      for (var i = 0; i < t.parts.length; i++)
        if (visible(t.parts[i])) i,
    ];

    return Column(
      children: [
        _preview(t, place),
        _separatorBar(t),
        _fieldFilterBar(t.parts.length, shown.length),
        Expanded(
          child: ReorderableListView.builder(
            padding: const EdgeInsets.only(bottom: 10),
            itemCount: shown.length,
            onReorderItem: (oldI, newI) {
              setState(() {
                // الترتيب يجري على المواضع الحقيقية لا المعروضة
                final from = shown[oldI];
                final to = shown[newI.clamp(0, shown.length - 1)];
                final item = t.parts.removeAt(from);
                t.parts.insert(to, item);
              });
              store.save();
            },
            itemBuilder: (_, idx) {
              final i = shown[idx];
              final part = t.parts[i];
              final value = available[part.key];
              final missing = value == null;
              final warn = isDiscouraged(part.key);

              return ListTile(
                key: ValueKey(part.key),
                dense: true,
                visualDensity: VisualDensity.compact,
                contentPadding: const EdgeInsets.only(right: 4, left: 2),
                leading: Checkbox(
                  value: part.enabled,
                  onChanged: (v) {
                    setState(() => part.enabled = v ?? false);
                    store.save();
                  },
                ),
                title: Row(
                  children: [
                    Flexible(
                      child: Text(
                        labelFor(part.key),
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: missing ? Colors.grey : null,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (warn)
                      const Padding(
                        padding: EdgeInsets.only(right: 3),
                        child: Icon(Icons.warning_amber,
                            size: 13, color: Colors.orange),
                      ),
                    if (part.prefix.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: Text(
                          'بادئة "${part.prefix}"',
                          style: const TextStyle(
                              fontSize: 10, color: Colors.deepPurple),
                        ),
                      ),
                  ],
                ),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // اسم الـ key، وسلسلة البدائل للحقول الذكية
                    Text(
                      kSmartChain.containsKey(part.key)
                          ? '${part.key}  ←  ${kSmartChain[part.key]}'
                          : part.key,
                      textDirection: TextDirection.ltr,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 10.5,
                        color: kSmartChain.containsKey(part.key)
                            ? Colors.teal.shade700
                            : Colors.grey.shade600,
                      ),
                    ),
                    Text(
                      missing ? '—  (غير متوفر في هذه النقطة)' : value,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: missing ? Colors.grey : Colors.blue.shade800,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.text_fields, size: 18),
                      tooltip: 'بادئة (مثل "قرب ")',
                      onPressed: () => _editPrefix(part),
                    ),
                    ReorderableDragStartListener(
                      index: i,
                      child: const Padding(
                        padding: EdgeInsets.only(left: 6),
                        child: Icon(Icons.drag_handle, size: 20),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _preview(AddressTemplate t, PlaceLocation place) {
    final line = t.render(place);
    return Container(
      width: double.infinity,
      color: const Color(0xFF0E1216),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  t.name,
                  style: const TextStyle(color: Colors.white54, fontSize: 11),
                ),
              ),
              _tinyBtn(Icons.content_copy, 'نسخ الناتج',
                  () => _copy(line, 'نُسخ الناتج')),
              _tinyBtn(Icons.code, 'نسخ كود Dart', () => _showCode(t)),
              _tinyBtn(Icons.push_pin_outlined, 'حفظ كقالب جديد',
                  () => _saveAsNew(t)),
            ],
          ),
          const SizedBox(height: 4),
          SelectableText(
            line.isEmpty ? '(فارغ — لم تُحدَّد حقول متوفرة)' : line,
            style: TextStyle(
              color: line.isEmpty ? Colors.orange : const Color(0xFFD7E0E8),
              fontSize: 15,
              fontWeight: FontWeight.w600,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _tinyBtn(IconData i, String tip, VoidCallback onTap) => IconButton(
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
        padding: EdgeInsets.zero,
        icon: Icon(i, size: 17, color: Colors.white70),
        tooltip: tip,
        onPressed: onTap,
      );

  /// شريط الفلترة: بحث + «المتوفر فقط» + عدّاد.
  Widget _fieldFilterBar(int total, int shown) => Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
        child: Row(
          children: [
            Expanded(
              child: SizedBox(
                height: 36,
                child: TextField(
                  onChanged: (v) => setState(() => _fieldQuery = v.trim()),
                  style: const TextStyle(fontSize: 12.5),
                  decoration: InputDecoration(
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 10),
                    border: const OutlineInputBorder(),
                    prefixIcon: const Icon(Icons.search, size: 16),
                    hintText: 'ابحث في المفاتيح أو القيم…',
                    hintStyle: const TextStyle(fontSize: 12),
                    suffixIcon: _fieldQuery.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.close, size: 15),
                            onPressed: () => setState(() => _fieldQuery = ''),
                          ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),
            Tooltip(
              message: 'إظهار المتوفر في هذه النقطة فقط',
              child: FilterChip(
                visualDensity: VisualDensity.compact,
                label: Text('$shown/$total', style: const TextStyle(fontSize: 10.5)),
                avatar: Icon(
                  _onlyAvailable ? Icons.filter_alt : Icons.filter_alt_off,
                  size: 15,
                ),
                selected: _onlyAvailable,
                onSelected: (v) => setState(() => _onlyAvailable = v),
              ),
            ),
          ],
        ),
      );

  Widget _separatorBar(AddressTemplate t) {
    const seps = {'، ': '، ', ' - ': ' - ', '  ': 'مسافة', ' | ': ' | '};
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        children: [
          const Center(child: Text('الفاصل:', style: TextStyle(fontSize: 11))),
          const SizedBox(width: 6),
          for (final e in seps.entries) ...[
            ChoiceChip(
              visualDensity: VisualDensity.compact,
              label: Text(e.value, style: const TextStyle(fontSize: 11)),
              selected: t.separator == e.key,
              onSelected: (_) {
                setState(() => t.separator = e.key);
                store.save();
              },
            ),
            const SizedBox(width: 5),
          ],
          const SizedBox(width: 6),
          Center(
            child: Row(
              children: [
                const Text('حذف التكرار', style: TextStyle(fontSize: 11)),
                Switch(
                  value: t.dedupe,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  onChanged: (v) {
                    setState(() => t.dedupe = v);
                    store.save();
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ═══ التبويب ٢: القوالب المثبتة ═══

  Widget _templatesTab() {
    final place = _place;
    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(8),
            itemCount: store.templates.length,
            itemBuilder: (_, i) {
              final t = store.templates[i];
              final isActive = i == store.activeIndex;
              final line = place == null ? null : t.render(place);

              return Card(
                elevation: isActive ? 3 : 0,
                color: isActive
                    ? Theme.of(context).colorScheme.primaryContainer
                    : null,
                child: ListTile(
                  dense: true,
                  onTap: () => store.setActive(i),
                  title: Row(
                    children: [
                      if (isActive)
                        const Padding(
                          padding: EdgeInsets.only(left: 5),
                          child: Icon(Icons.edit_note, size: 16),
                        ),
                      Expanded(
                        child: Text(t.name,
                            style: const TextStyle(
                                fontSize: 13, fontWeight: FontWeight.w700)),
                      ),
                      Text('${t.activeKeys.length} حقل',
                          style: const TextStyle(fontSize: 10.5)),
                    ],
                  ),
                  subtitle: Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                      line == null
                          ? t.activeKeys.map(labelFor).join(' · ')
                          : (line.isEmpty ? '(فارغ على هذه النقطة)' : line),
                      style: TextStyle(
                        fontSize: 12.5,
                        color: line == null ? Colors.grey : Colors.black87,
                      ),
                    ),
                  ),
                  trailing: PopupMenuButton<String>(
                    onSelected: (v) async {
                      switch (v) {
                        case 'copy':
                          _copy(line ?? '', 'نُسخ الناتج');
                        case 'code':
                          _showCode(t);
                        case 'rename':
                          await _rename(t);
                        case 'dup':
                          await store.add(t.copy());
                        case 'del':
                          await store.remove(i);
                      }
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'copy', child: Text('نسخ الناتج')),
                      PopupMenuItem(value: 'code', child: Text('نسخ كود Dart')),
                      PopupMenuItem(
                          value: 'rename', child: Text('إعادة تسمية')),
                      PopupMenuItem(value: 'dup', child: Text('تكرار')),
                      PopupMenuItem(value: 'del', child: Text('حذف')),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('قالب فارغ'),
                  onPressed: () async {
                    final t = AddressTemplate(
                        name: 'قالب ${store.templates.length + 1}');
                    if (_place != null) t.absorb(_place!.fields.keys);
                    await store.add(t);
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.icon(
                  icon: const Icon(Icons.copy_all, size: 18),
                  label: const Text('نسخ كل النواتج'),
                  onPressed: _place == null
                      ? null
                      : () => _copy(
                            store.templates
                                .map((t) => '${t.name}: ${t.render(_place!)}')
                                .join('\n'),
                            'نُسخت ${store.templates.length} قوالب',
                          ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ═══ التبويب ٣: الرد الكامل ═══

  Widget _rawTab() {
    final place = _place;
    if (place == null) {
      return const Center(child: Text('افحص نقطة أولاً.'));
    }

    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(8),
            itemCount: place.results.length,
            itemBuilder: (_, i) {
              final r = place.results[i];
              return Card(
                margin: const EdgeInsets.only(bottom: 6),
                child: ExpansionTile(
                  dense: true,
                  tilePadding: const EdgeInsets.symmetric(horizontal: 10),
                  title: Text(
                    '[$i]  ${r.types.join(' / ')}',
                    textDirection: TextDirection.ltr,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  subtitle: Text(
                    '${r.formattedAddress}'
                    '${r.locationType.isEmpty ? '' : '  ·  ${r.locationType}'}',
                    style: const TextStyle(fontSize: 11),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  children: [
                    for (final c in r.components)
                      Padding(
                        padding:
                            const EdgeInsets.fromLTRB(14, 0, 14, 6),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              flex: 5,
                              child: Text(
                                c.types.join(', '),
                                textDirection: TextDirection.ltr,
                                style: TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 10,
                                  color: Colors.grey.shade700,
                                ),
                              ),
                            ),
                            Expanded(
                              flex: 4,
                              child: SelectableText(
                                c.longName,
                                style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600),
                              ),
                            ),
                          ],
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
                      child: SelectableText(
                        'place_id: ${r.placeId}',
                        textDirection: TextDirection.ltr,
                        style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 9.5,
                            color: Colors.grey.shade600),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
        Row(
          children: [
            Expanded(
              child: TextButton.icon(
                icon: const Icon(Icons.data_object, size: 18),
                label: const Text('نسخ JSON الخام'),
                onPressed: () => _copy(_lastJson, 'نُسخ JSON'),
              ),
            ),
            Expanded(
              child: Center(
                child: Text(
                  '${place.results.length} نتيجة · '
                  '${place.fields.length} مفتاح',
                  style: const TextStyle(fontSize: 11),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ═══ التبويب ٤: الملخّص ═══

  Widget _digestTab() => Column(
        children: [
          Expanded(
            child: Container(
              width: double.infinity,
              color: const Color(0xFF0E1216),
              padding: const EdgeInsets.all(8),
              child: SingleChildScrollView(
                child: SelectableText(
                  _samples.isEmpty ? '—' : _samples.last,
                  textDirection: TextDirection.ltr,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    height: 1.5,
                    color: Color(0xFFD7E0E8),
                  ),
                ),
              ),
            ),
          ),
          Row(
            children: [
              Expanded(
                child: TextButton.icon(
                  icon: const Icon(Icons.copy_all, size: 18),
                  label: Text('نسخ الكل (${_samples.length})'),
                  onPressed: () => _copy(
                      _samples.join('\n'), 'نُسخت ${_samples.length} عيّنة'),
                ),
              ),
              Expanded(
                child: TextButton.icon(
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: const Text('مسح'),
                  onPressed: () => setState(_samples.clear),
                ),
              ),
            ],
          ),
        ],
      );

  // ─────────────────────────── حوارات ───────────────────────────

  Future<void> _editPrefix(TemplatePart part) async {
    final ctrl = TextEditingController(text: part.prefix);
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('بادئة «${labelFor(part.key)}»'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'مثال:  قرب  /  شارع  /  محلة',
            helperText: 'تُضاف قبل القيمة مباشرة',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('حفظ'),
          ),
        ],
      ),
    );
    if (v != null) {
      setState(() => part.prefix = v);
      await store.save();
    }
  }

  Future<void> _rename(AddressTemplate t) async {
    final ctrl = TextEditingController(text: t.name);
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('اسم القالب'),
        content: TextField(controller: ctrl, autofocus: true),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('حفظ'),
          ),
        ],
      ),
    );
    if (v != null && v.isNotEmpty) {
      t.name = v;
      await store.save();
    }
  }

  Future<void> _saveAsNew(AddressTemplate t) async {
    await store.add(t.copy(name: '${t.name} ٢'));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
          content: Text('حُفظ كقالب جديد'), duration: Duration(seconds: 1)),
    );
  }

  void _showCode(AddressTemplate t) {
    // مفتاحا POI وجوار مفعّلان في الشريط ⇒ الكود المولَّد يجلبهما بنفسه
    final needs = t.standaloneNeeds;
    final fetchPoi = _withPoi && needs.poi;
    final fetchArea = _areaBackfill && needs.area;
    final code = t.standaloneCode(fetchPoi: fetchPoi, fetchArea: fetchArea);
    final usage = t.usageCode(fetchPoi: fetchPoi, fetchArea: fetchArea);

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.85,
        builder: (_, scroll) => ListView(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 20),
          children: [
            Text('كود القالب: ${t.name}',
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 14),
            _codeBlock(
              '١) الكود المستقل — يعمل في أي مشروع Dart/Flutter',
              code,
              fetchPoi || fetchArea
                  ? 'الصقه في ملف مستقل. بلا أي package (dart:io فقط). '
                      'يجلب Geocoding'
                      '${fetchPoi ? ' + المعلم من Places' : ''}'
                      '${fetchArea ? ' + الجوار' : ''} بنفسه، '
                      'وناتجه يطابق المعاينة حرفياً.'
                  : 'الصقه في ملف مستقل. لا يحتاج أي package ولا PlaceLocation؛ '
                      'مدخله رد Geocoding الخام، وناتجه يطابق المعاينة حرفياً. '
                      'فعّل POI أو جوار في الشريط ليُضمَّن جلبهما في الكود.',
            ),
            const SizedBox(height: 14),
            _codeBlock(
              '٢) الاستعمال',
              usage,
              fetchPoi || fetchArea
                  ? 'مرّر الإحداثية ومفتاح Google فقط.'
                  : 'بعد استدعاء Geocoding API بأي عميل (http أو dio). '
                      'poi و areaHint اختياريان يأتيان من مشروعك.',
            ),
          ],
        ),
      ),
    );
  }

  Widget _codeBlock(String title, String code, String note) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(title,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
              IconButton(
                icon: const Icon(Icons.content_copy, size: 18),
                onPressed: () => _copy(code, 'نُسخ الكود'),
              ),
            ],
          ),
          Text(note, style: const TextStyle(fontSize: 11, color: Colors.grey)),
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFF0E1216),
              borderRadius: BorderRadius.circular(8),
            ),
            child: SelectableText(
              code,
              textDirection: TextDirection.ltr,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 11.5,
                height: 1.5,
                color: Color(0xFFD7E0E8),
              ),
            ),
          ),
        ],
      );
}

// ════════════════════════════════════════════════════════════════════════════
//  6) شاشة التنبيه عند غياب المفتاح
// ════════════════════════════════════════════════════════════════════════════

class SetupScreen extends StatelessWidget {
  const SetupScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Padding(
          padding: EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.key_off, size: 56, color: Colors.orange),
              SizedBox(height: 16),
              Text(
                'مفتاح Google Maps غير مضبوط',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              SizedBox(height: 14),
              Text(
                '١) ضع المفتاح في defaultValue داخل kMapsKey في lib/main.dart\n'
                '٢) ضعه أيضاً في AndroidManifest.xml و AppDelegate.swift\n'
                '٣) فعّل من Google Cloud:\n'
                '    Maps SDK for Android/iOS  +  Geocoding API  +  Places API',
                textAlign: TextAlign.center,
                style: TextStyle(height: 1.8),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
