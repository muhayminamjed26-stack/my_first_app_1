import 'dart:async';

import 'package:barcode_widget/barcode_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart' hide Barcode;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';

// =====================================================================
//  نظام الجامعة: رئيس الجامعة / رئيس القسم / الدكتور / الطالب
//  حضور وغياب بالباركود + امتحانات وكوزات + تقارير
//  حسابات تجريبية:
//    رئيس الجامعة: president / 1234
//    رئيس القسم:   head_cyber / head_ai / head_control  (1234)
//    الدكتور:      doctor_cyber / doctor_ai / doctor_control  (1234)
//    الطالب:       رقمه الجامعي / نفس الرقم
// =====================================================================

// ======== الصق هنا قيم firebaseConfig من Firebase Console ========
const firebaseOptions = FirebaseOptions(
  apiKey: 'AIzaSyDWRCipOAjXif8zjX72XX13plIr3P5M4Nk',
  authDomain: 'uni-app-e7dea.firebaseapp.com',
  projectId: 'uni-app-e7dea',
  storageBucket: 'uni-app-e7dea.firebasestorage.app',
  messagingSenderId: '577460056261',
  appId: '1:577460056261:web:1e81cadd5312ef6c6400ac',
);
// ==================================================================

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  String? error;
  if (firebaseOptions.apiKey.startsWith('PASTE')) {
    error = 'لازم تلصق قيم Firebase بأعلى ملف main.dart';
  } else {
    try {
      await Firebase.initializeApp(options: firebaseOptions);
    } catch (e) {
      error = 'ما كدر يتصل بـ Firebase:\n$e';
    }
  }
  runApp(App(error: error));
}

// ----------------------------- أدوات عامة -----------------------------
String two(int n) => n.toString().padLeft(2, '0');
String today() {
  final d = DateTime.now();
  return '${d.year}-${two(d.month)}-${two(d.day)}';
}

String uid() => DateTime.now().microsecondsSinceEpoch.toString();
String pct(double v) => '${(v * 100).toStringAsFixed(0)}%';

const roleNames = {
  'president': 'رئيس الجامعة',
  'head': 'رئيس القسم',
  'doctor': 'دكتور',
  'student': 'طالب',
};

typedef Rec = Map<String, dynamic>;

// ----------------------------- قاعدة البيانات -----------------------------
const kMail = '@uni-app.local';
String emailOf(String username) => '$username$kMail';

class DB {
  static final _f = FirebaseFirestore.instance;
  static const keys = ['accounts', 'subjects', 'students', 'attendance', 'exams', 'keys', 'submissions', 'messages'];
  static final Map<String, List<Rec>> _c = {for (final k in keys) k: <Rec>[]};
  static final _subs = <StreamSubscription>[];
  static final _grading = <String>{};
  static Rec me = {};

  /// يزيد كل ما تتغير البيانات أونلاين، والصفحات تتحدث وحدها
  static final version = ValueNotifier<int>(0);

  static List<Rec> list(String k) => _c[k]!;
  static bool get isStaff => me['role'] != 'student';
  static String get myId => '${me['studentId'] ?? me['username']}';

  /// يبدي الاستماع للبيانات حسب صلاحية المستخدم (الطالب يشوف بس بياناته)
  static Future<void> start(Rec user) async {
    await stop();
    me = user;
    final staff = isStaff;
    final sid = myId;
    final queries = <String, List<Query<Map<String, dynamic>>>>{
      'accounts': [_f.collection('accounts')],
      'subjects': [_f.collection('subjects')],
      'exams': [_f.collection('exams')],
      'students': staff ? [_f.collection('students')] : [],
      'attendance': staff
          ? [_f.collection('attendance')]
          : [_f.collection('attendance').where('studentId', isEqualTo: sid)],
      'keys': staff ? [_f.collection('keys')] : [],
      'submissions': staff
          ? [_f.collection('submissions')]
          : [_f.collection('submissions').where('studentId', isEqualTo: sid)],
      'messages': [
        _f.collection('messages').where('from', isEqualTo: sid),
        _f.collection('messages').where('to', isEqualTo: sid),
      ],
    };
    if (!staff) _c['students'] = [{...user, 'id': sid}];

    final waits = <Future<void>>[];
    for (final e in queries.entries) {
      final parts = List<List<Rec>>.filled(e.value.length, const []);
      for (var i = 0; i < e.value.length; i++) {
        final first = Completer<void>();
        _subs.add(e.value[i].snapshots().listen((snap) {
          parts[i] = [for (final d in snap.docs) {...d.data(), '_id': d.id}];
          final seen = <String>{};
          _c[e.key] = [for (final p in parts) for (final r in p) if (seen.add('${r['_id']}')) r];
          if (staff && (e.key == 'submissions' || e.key == 'keys')) _autoGrade();
          version.value++;
          if (!first.isCompleted) first.complete();
        }, onError: (err) {
          if (!first.isCompleted) first.completeError(err);
        }));
        waits.add(first.future);
      }
    }
    await Future.wait(waits);
  }

  static Future<void> stop() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    for (final k in keys) {
      _c[k] = <Rec>[];
    }
    me = {};
  }

  /// التصحيح يصير عند الكادر فقط، لأن الطالب ما يشوف الأجوبة الصحيحة
  static void _autoGrade() {
    for (final sub in list('submissions')) {
      if (sub['score'] != null || _grading.contains(sub['_id'])) continue;
      final key = find('keys', (k) => k['_id'] == sub['examId']);
      if (key == null) continue;
      final correct = (key['answers'] as List).cast<num>();
      final ans = (sub['answers'] as List?) ?? [];
      var score = 0;
      for (var i = 0; i < correct.length; i++) {
        if (i < ans.length && ans[i] == correct[i]) score++;
      }
      _grading.add('${sub['_id']}');
      _f.collection('submissions').doc('${sub['_id']}').update({'score': score, 'total': correct.length});
    }
  }

  // ---------- الكتابة أونلاين ----------
  static Future<void> put(String k, Rec r, [String? id]) {
    final docId = id ?? (r['_id'] as String?);
    final ref = docId == null ? _f.collection(k).doc() : _f.collection(k).doc(docId);
    final data = Map<String, dynamic>.from(r)..remove('_id');
    return ref.set(data);
  }

  static Future<void> del(String k, Rec r) => _f.collection(k).doc('${r['_id']}').delete();

  static Future<void> delWhere(String k, bool Function(Rec) test) async {
    final docs = list(k).where(test).toList();
    for (var i = 0; i < docs.length; i += 400) {
      final b = _f.batch();
      for (final r in docs.skip(i).take(400)) {
        b.delete(_f.collection(k).doc('${r['_id']}'));
      }
      await b.commit();
    }
  }

  static Future<void> putMany(String k, List<Rec> rows, String Function(Rec) idOf,
      {bool merge = false}) async {
    for (var i = 0; i < rows.length; i += 400) {
      final b = _f.batch();
      for (final r in rows.skip(i).take(400)) {
        b.set(_f.collection(k).doc(idOf(r).replaceAll('/', '-')), r,
            SetOptions(merge: merge));
      }
      await b.commit();
    }
  }

  // ---------- استعلامات ----------
  static Rec? find(String k, bool Function(Rec) test) {
    for (final e in list(k)) {
      if (test(e)) return e;
    }
    return null;
  }

  static List<Rec> studentsOf(Rec subject, [String shift = '']) => list('students')
      .where((s) =>
          s['dept'] == subject['dept'] &&
          ('${subject['stage'] ?? ''}'.isEmpty || s['stage'] == subject['stage']) &&
          (shift.isEmpty || s['shift'] == shift))
      .toList();

  static String subInfo(Rec s) => [
        if ('${s['code'] ?? ''}'.isNotEmpty) s['code'],
        if ('${s['stage'] ?? ''}'.isNotEmpty) s['stage'],
        if ('${s['semester'] ?? ''}'.isNotEmpty) 'فصل ${s['semester']}',
      ].join(' • ');

  static String stuInfo(Rec s) => [
        '${s['id']}',
        if ('${s['stage'] ?? ''}'.isNotEmpty) s['stage'],
        if ('${s['shift'] ?? ''}'.isNotEmpty) s['shift'],
      ].join(' • ');

  static List<Rec> subjectsOfDept(String? dept) => list('subjects')
      .where((s) => dept == null || s['dept'] == dept)
      .toList();

  static double attRate({String? studentId, String? subjectId, String? dept}) {
    final subIds = dept == null
        ? null
        : subjectsOfDept(dept).map((s) => s['id']).toSet();
    final a = list('attendance').where((e) =>
        (studentId == null || e['studentId'] == studentId) &&
        (subjectId == null || e['subjectId'] == subjectId) &&
        (subIds == null || subIds.contains(e['subjectId'])));
    if (a.isEmpty) return 0;
    return a.where((e) => e['present'] == true).length / a.length;
  }

  static int lectures(String subjectId) => list('attendance')
      .where((e) => e['subjectId'] == subjectId)
      .map((e) => e['date'])
      .toSet()
      .length;

  static Set<String> depts() => {
        ...list('students').map((s) => '${s['dept']}'),
        ...list('subjects').map((s) => '${s['dept']}'),
      }..removeWhere((e) => e.isEmpty);

  static double avgScore({String? examId, String? dept}) {
    Iterable<Rec> r = list('submissions').where((e) => e['score'] != null && e['total'] != null && (e['total'] as num) > 0);
    if (examId != null) r = r.where((e) => e['examId'] == examId);
    if (dept != null) {
      final subIds = subjectsOfDept(dept).map((s) => s['id']).toSet();
      final exIds = list('exams')
          .where((e) => subIds.contains(e['subjectId']))
          .map((e) => e['id'])
          .toSet();
      r = r.where((e) => exIds.contains(e['examId']));
    }
    if (r.isEmpty) return 0;
    return r.map((e) => (e['score'] as num) / (e['total'] as num)).reduce((a, b) => a + b) /
        r.length;
  }
}

// ----------------------------- التطبيق -----------------------------
class App extends StatelessWidget {
  final String? error;
  const App({super.key, this.error});
  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'نظام الجامعة',
        theme: appTheme(),
        builder: (c, child) =>
            Directionality(textDirection: TextDirection.rtl, child: child!),
        home: error == null
            ? const LoginPage()
            : Scaffold(
                body: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(error!, textAlign: TextAlign.center, style: const TextStyle(fontSize: 18, color: Colors.red)),
                  ),
                ),
              ),
      );
}

/// أي صفحة ترث من Live تتحدث وحدها لما تتغير البيانات أونلاين
abstract class Live<T extends StatefulWidget> extends State<T> {
  void _onDb() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    DB.version.addListener(_onDb);
  }

  @override
  void dispose() {
    DB.version.removeListener(_onDb);
    super.dispose();
  }
}

Widget homeFor(Rec u) {
  switch (u['role']) {
    case 'president':
      return PresidentHome(user: u);
    case 'head':
      return HeadHome(user: u);
    case 'doctor':
      return DoctorHome(user: u);
    default:
      return StudentHome(user: u);
  }
}

/// يحدد منو المستخدم وصلاحيته من قاعدة البيانات (مو من جهازه)
Future<Rec?> resolveMe() async {
  final cu = FirebaseAuth.instance.currentUser;
  final email = cu?.email;
  if (email == null || !email.endsWith(kMail)) return null;
  final un = email.substring(0, email.length - kMail.length);
  final f = FirebaseFirestore.instance;
  final acc = await f.collection('accounts').doc(un).get();
  if (acc.exists) return {...acc.data()!, 'username': un};
  if (un == 'president') {
    final me = {'username': 'president', 'name': 'رئيس الجامعة', 'role': 'president', 'dept': ''};
    await f.collection('accounts').doc('president').set(me);
    return me;
  }
  final st = await f.collection('students').doc(un).get();
  if (st.exists) {
    final d = st.data()!;
    return {...d, 'username': un, 'studentId': un, 'role': 'student'};
  }
  return null;
}

Future<void> logout(BuildContext? context) async {
  await DB.stop();
  await FirebaseAuth.instance.signOut();
  if (context != null && context.mounted) {
    Navigator.pushAndRemoveUntil(context, MaterialPageRoute(builder: (_) => const LoginPage()), (_) => false);
  }
}

/// تغيير الرمز. force = ما يكدر يلغي (أول دخول للطالب)
Future<bool> changePassword(BuildContext context, {bool force = false}) async {
  final a = TextEditingController(), b = TextEditingController();
  final ok = await showDialog<bool>(
    context: context,
    barrierDismissible: !force,
    builder: (c) => AlertDialog(
      title: Text(force ? 'اختار رمز جديد' : 'تغيير الرمز'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        if (force) const Text('لحماية حسابك، لازم تختار رمز جديد غير رقمك الجامعي.'),
        TextField(controller: a, obscureText: true, decoration: const InputDecoration(labelText: 'الرمز الجديد (6 أحرف أو أكثر)')),
        TextField(controller: b, obscureText: true, decoration: const InputDecoration(labelText: 'أعد كتابة الرمز')),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: Text(force ? 'خروج' : 'إلغاء')),
        FilledButton(
          onPressed: () async {
            final pw = a.text.trim();
            if (pw.length < 6 || pw != b.text.trim()) {
              toast(c, 'الرمز لازم 6 أحرف أو أكثر ومتطابق', Colors.red);
              return;
            }
            final cu = FirebaseAuth.instance.currentUser!;
            if (pw == cu.email!.split('@').first) {
              toast(c, 'لا تستخدم رقمك الجامعي كرمز', Colors.red);
              return;
            }
            try {
              await cu.updatePassword(pw);
              if (c.mounted) Navigator.pop(c, true);
            } catch (e) {
              if (c.mounted) toast(c, 'ما انحفظ، سجل خروج ودخول وعيد: $e', Colors.red);
            }
          },
          child: const Text('حفظ'),
        ),
      ],
    ),
  );
  if (ok == true && context.mounted) toast(context, 'تم تغيير الرمز ✓', Colors.green);
  return ok == true;
}

/// ينشئ حساب دخول لشخص ثاني بدون ما يطلع الحساب الحالي
Future<void> createLogin(String username, String password) async {
  final app = await Firebase.initializeApp(
      name: 'admin${DateTime.now().millisecondsSinceEpoch}', options: firebaseOptions);
  try {
    await FirebaseAuth.instanceFor(app: app)
        .createUserWithEmailAndPassword(email: emailOf(username), password: password);
  } finally {
    await app.delete();
  }
}

Widget logoutBtn(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
      IconButton(
        tooltip: 'تغيير الرمز',
        icon: const Icon(Icons.key),
        onPressed: () => changePassword(context),
      ),
      IconButton(
        tooltip: 'خروج',
        icon: const Icon(Icons.logout),
        onPressed: () => logout(context),
      ),
    ]);

void toast(BuildContext context, String m, [Color? c]) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
        content: Text(m),
        backgroundColor: c,
        duration: const Duration(milliseconds: 1200)));
}

Future<bool> confirm(BuildContext context, String m) async =>
    await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        content: Text(m),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('لا')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('نعم')),
        ],
      ),
    ) ??
    false;

/// نافذة إدخال عامة: حقول نصية + قائمة اختيار اختيارية (ترجع قيمتها بالمفتاح _drop)
Future<Map<String, String>?> formDialog(
    BuildContext context, String title, List<String> fields,
    {String? dropLabel, Map<String, String>? drop, List<String>? init, String? dropInit}) {
  final cs = [
    for (var i = 0; i < fields.length; i++)
      TextEditingController(text: (init != null && i < init.length) ? init[i] : '')
  ];
  String? sel = (drop != null && drop.isNotEmpty)
      ? (drop.containsKey(dropInit) ? dropInit : drop.keys.first)
      : null;
  return showDialog<Map<String, String>>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, set) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            for (var i = 0; i < fields.length; i++)
              TextField(
                  controller: cs[i],
                  decoration: InputDecoration(labelText: fields[i])),
            if (drop != null && drop.isNotEmpty)
              DropdownButtonFormField<String>(
                value: sel,
                decoration: InputDecoration(labelText: dropLabel),
                items: [
                  for (final e in drop.entries)
                    DropdownMenuItem(value: e.key, child: Text(e.value))
                ],
                onChanged: (v) => set(() => sel = v),
              ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('إلغاء')),
          FilledButton(
            onPressed: () {
              final m = <String, String>{
                for (var i = 0; i < fields.length; i++) fields[i]: cs[i].text.trim()
              };
              if (m.values.any((v) => v.isEmpty)) return;
              if (sel != null) m['_drop'] = sel!;
              Navigator.pop(c, m);
            },
            child: const Text('حفظ'),
          ),
        ],
      ),
    ),
  );
}

// ============================ التصميم ============================
const kPrimary = Color(0xFF0E4D64);
const kPrimaryDark = Color(0xFF082F3E);
const kAccent = Color(0xFFF2A541);
const kBg = Color(0xFFF3F6F8);
const kSoft = Color(0xFFE3EEF2);
const kGreen = Color(0xFF2E7D32);
const kRed = Color(0xFFC62828);
const kFont = 'Almarai';

ThemeData appTheme() {
  final cs = ColorScheme.fromSeed(seedColor: kPrimary, primary: kPrimary, secondary: kAccent, surface: Colors.white);
  final round = RoundedRectangleBorder(borderRadius: BorderRadius.circular(14));
  return ThemeData(
    useMaterial3: true,
    colorScheme: cs,
    fontFamily: kFont,
    scaffoldBackgroundColor: kBg,
    appBarTheme: const AppBarTheme(
      backgroundColor: kPrimary,
      foregroundColor: Colors.white,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(fontFamily: kFont, fontSize: 19, fontWeight: FontWeight.w800, color: Colors.white),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(bottom: Radius.circular(26))),
    ),
    cardTheme: CardThemeData(
      color: Colors.white,
      elevation: 0,
      margin: const EdgeInsets.symmetric(vertical: 5, horizontal: 2),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18), side: const BorderSide(color: Color(0xFFE6ECEF))),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
          backgroundColor: kPrimary,
          foregroundColor: Colors.white,
          shape: round,
          textStyle: const TextStyle(fontFamily: kFont, fontWeight: FontWeight.w700, fontSize: 15)),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(foregroundColor: kPrimary, shape: round, side: const BorderSide(color: kPrimary)),
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: kPrimary, foregroundColor: Colors.white),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: Color(0xFFDCE4E8))),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: Color(0xFFDCE4E8))),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: kPrimary, width: 1.6)),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Colors.white,
      indicatorColor: kAccent.withValues(alpha: 0.25),
      iconTheme: WidgetStateProperty.resolveWith((st) =>
          IconThemeData(color: st.contains(WidgetState.selected) ? kPrimary : Colors.grey.shade600)),
      labelTextStyle: WidgetStateProperty.resolveWith((st) => TextStyle(
          fontFamily: kFont,
          fontSize: 12,
          fontWeight: st.contains(WidgetState.selected) ? FontWeight.w800 : FontWeight.w400,
          color: st.contains(WidgetState.selected) ? kPrimary : Colors.grey.shade600)),
    ),
    chipTheme: ChipThemeData(
      selectedColor: kPrimary,
      checkmarkColor: Colors.white,
      labelStyle: const TextStyle(fontFamily: kFont),
      secondaryLabelStyle: const TextStyle(fontFamily: kFont, color: Colors.white),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    dialogTheme: DialogThemeData(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22))),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}

String greeting() => DateTime.now().hour < 12 ? 'صباح الخير' : 'مساء الخير';

String initials(String name) {
  final parts = name.replaceAll('د.', '').trim().split(RegExp(r'\s+')).where((x) => x.isNotEmpty).toList();
  if (parts.isEmpty) return '?';
  if (parts.length == 1) return parts.first.characters.first;
  return '${parts[0].characters.first}${parts[1].characters.first}';
}

/// خلفية الهيدر المنحنية
class _WaveClip extends CustomClipper<Path> {
  @override
  Path getClip(Size s) => Path()
    ..lineTo(0, s.height - 22)
    ..quadraticBezierTo(s.width * 0.25, s.height, s.width * 0.5, s.height - 12)
    ..quadraticBezierTo(s.width * 0.78, s.height - 26, s.width, s.height - 6)
    ..lineTo(s.width, 0)
    ..close();
  @override
  bool shouldReclip(covariant CustomClipper<Path> o) => false;
}

/// الهيدر الكبير للصفحات الرئيسية (تحية + اسم + أفاتار)
class UniHeader extends StatelessWidget implements PreferredSizeWidget {
  final String title;
  final String? name, line, sub;
  final List<Widget> actions;
  final Widget? bottom;
  final double extra;
  final bool back;
  const UniHeader(
      {super.key, required this.title, this.name, this.line, this.sub, this.actions = const [], this.bottom, this.extra = 0, this.back = false});

  @override
  Size get preferredSize => Size.fromHeight((name != null ? 158 : (sub != null ? 104 : 88)) + extra);

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.of(context).padding.top;
    return SizedBox(
      height: preferredSize.height + top,
      child: ClipPath(
        clipper: _WaveClip(),
        child: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(colors: [kPrimaryDark, kPrimary], begin: Alignment.topLeft, end: Alignment.bottomRight),
          ),
          padding: EdgeInsets.fromLTRB(16, top + 10, 8, 24),
          child: DefaultTextStyle(
            style: const TextStyle(fontFamily: kFont, color: Colors.white),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                if (back) const BackButton(color: Colors.white),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Flexible(
                        child: Text(title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                      ),
                      const SizedBox(width: 6),
                      const Icon(Icons.circle, size: 7, color: kAccent),
                    ]),
                    if (sub != null)
                      Text(sub!, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: Colors.white70)),
                  ]),
                ),
                Theme(
                  data: Theme.of(context).copyWith(
                      iconButtonTheme: IconButtonThemeData(style: IconButton.styleFrom(foregroundColor: Colors.white))),
                  child: IconTheme(
                      data: const IconThemeData(color: Colors.white),
                      child: Row(mainAxisSize: MainAxisSize.min, children: actions)),
                ),
              ]),
              if (name != null) ...[
                const SizedBox(height: 14),
                Row(children: [
                  Container(
                    width: 52,
                    height: 52,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white.withValues(alpha: 0.14),
                        border: Border.all(color: kAccent, width: 1.5)),
                    child: Text(initials(name!), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(greeting(), style: const TextStyle(fontSize: 12, color: Colors.white70)),
                      Text(name!, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
                      if (line != null)
                        Text(line!, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: Colors.white70)),
                    ]),
                  ),
                ]),
              ],
              if (bottom != null) ...[const SizedBox(height: 10), bottom!],
            ]),
          ),
        ),
      ),
    );
  }
}

/// مربعات صغيرة داخل الهيدر (مثل: الطلاب ٨ • المحاضرات ٤)
Widget headerPills(List<(String, String)> items) => Row(children: [
      for (final it in items)
        Expanded(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 4),
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(14)),
            child: Column(children: [
              Text(it.$1, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: Colors.white)),
              Text(it.$2, style: const TextStyle(fontSize: 11, color: Colors.white70)),
            ]),
          ),
        ),
    ]);

class StatCard extends StatelessWidget {
  final String title, value;
  final IconData icon;
  final String? sub;
  final Color? color;
  const StatCard(this.title, this.value, this.icon, {super.key, this.sub, this.color});
  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
          Row(children: [
            Expanded(child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: Colors.grey.shade700))),
            Icon(icon, size: 18, color: Colors.grey.shade600),
          ]),
          const SizedBox(height: 4),
          Text(value, style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: color ?? kPrimaryDark)),
          if (sub != null) Text(sub!, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
        ]),
      ),
    );
  }
}

/// شبكة مربعات الإحصائيات (عمودين)
Widget statGrid(List<Widget> cards) => LayoutBuilder(builder: (context, c) {
      final n = c.maxWidth > 760 ? 4 : 2;
      final w = (c.maxWidth - (n - 1) * 6) / n;
      return GridView.count(
        crossAxisCount: n,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        childAspectRatio: w / 108,
        mainAxisSpacing: 4,
        crossAxisSpacing: 6,
        children: cards,
      );
    });

Widget sectionTitle(String t, [int? count]) => Padding(
      padding: const EdgeInsets.fromLTRB(4, 16, 4, 6),
      child: Row(children: [
        Text(t, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: kPrimaryDark)),
        if (count != null) ...[
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
            decoration: BoxDecoration(color: kSoft, borderRadius: BorderRadius.circular(10)),
            child: Text('$count', style: const TextStyle(fontSize: 11, color: kPrimary, fontWeight: FontWeight.w700)),
          ),
        ],
      ]),
    );

/// دائرة النسبة (مثل نسبة الحضور)
Widget ring(double? v, {double size = 52}) {
  final c = v == null ? Colors.grey : (v < 0.75 ? kRed : kPrimary);
  return SizedBox(
    width: size,
    height: size,
    child: Stack(alignment: Alignment.center, children: [
      CircularProgressIndicator(
        value: v ?? 0,
        strokeWidth: 4.5,
        backgroundColor: kSoft,
        color: c,
      ),
      Text(v == null ? '–' : pct(v), style: TextStyle(fontSize: size < 60 ? 11 : 16, fontWeight: FontWeight.w800, color: c)),
    ]),
  );
}

/// شارة صغيرة ملونة (حاضر/غائب/مفتوحة...)
Widget tag(String t, Color c) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
      child: Text('• $t', style: TextStyle(fontSize: 11, color: c, fontWeight: FontWeight.w700)),
    );

/// بطاقة مادة: أيقونة + اسم + معلومات + دائرة نسبة
Widget subjectCard(Rec s, {String? line, double? rate, bool showRing = true, VoidCallback? onTap, Widget? extra}) {
  final doc = DB.find('accounts', (a) => a['username'] == s['doctor']);
  return Card(
    child: InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(color: kSoft, borderRadius: BorderRadius.circular(12)),
            child: const Icon(Icons.menu_book_rounded, color: kPrimary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${s['name']}', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
              const SizedBox(height: 2),
              Text(line ?? [if ('${s['code'] ?? ''}'.isNotEmpty) s['code'], if (doc != null) '${doc['name']}'].join(' • '),
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
              if (extra != null) ...[const SizedBox(height: 4), extra],
            ]),
          ),
          if (showRing) ring(rate),
        ]),
      ),
    ),
  );
}

Widget empty(String m) => Center(
    child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(m, textAlign: TextAlign.center, style: const TextStyle(color: Colors.grey))));

// ----------------------------- تسجيل الدخول -----------------------------
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final u = TextEditingController(), p = TextEditingController();
  bool hide = true;

  bool busy = false;

  @override
  void initState() {
    super.initState();
    // إذا كان مسجل دخول من قبل، يدخل مباشرة
    if (FirebaseAuth.instance.currentUser != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _enter(null));
    }
  }

  Future<void> _enter(String? typedPw) async {
    setState(() => busy = true);
    try {
      final me = await resolveMe();
      if (me == null) {
        // حساب بدون صلاحية: نمسحه ونطلع
        final cu = FirebaseAuth.instance.currentUser;
        if (typedPw != null) await cu?.delete().catchError((_) {});
        await FirebaseAuth.instance.signOut();
        if (mounted) toast(context, 'هذا الحساب ما عنده صلاحية', Colors.red);
        return;
      }
      await DB.start(me);
      if (!mounted) return;
      // الطالب لازم يغير الرمز الافتراضي (رقمه الجامعي) أول مرة
      if (me['role'] == 'student' && typedPw == me['username']) {
        final ok = await changePassword(context, force: true);
        if (!ok || !mounted) {
          await logout(null);
          return;
        }
      }
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => homeFor(me)));
    } catch (e) {
      if (mounted) toast(context, 'خطأ: $e', Colors.red);
      await FirebaseAuth.instance.signOut();
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> login() async {
    final un = u.text.trim().toLowerCase(), pw = p.text.trim();
    if (un.isEmpty || pw.isEmpty || busy) return;
    if (!RegExp(r'^[a-z0-9_.-]+$').hasMatch(un)) {
      toast(context, 'اسم المستخدم لازم يكون أحرف إنكليزية أو أرقام', Colors.red);
      return;
    }
    setState(() => busy = true);
    final auth = FirebaseAuth.instance;
    try {
      await auth.signInWithEmailAndPassword(email: emailOf(un), password: pw);
    } on FirebaseAuthException catch (signErr) {
      // أول دخول للطالب: الرمز = رقمه الجامعي، والحساب ينسوى تلقائياً
      var created = false;
      if (pw == un && pw.length >= 6) {
        try {
          await auth.createUserWithEmailAndPassword(email: emailOf(un), password: pw);
          created = true;
        } on FirebaseAuthException catch (_) {}
      }
      if (!created) {
        if (mounted) {
          setState(() => busy = false);
          toast(context, signErr.code == 'invalid-credential' || signErr.code == 'wrong-password' || signErr.code == 'user-not-found'
              ? 'اسم المستخدم أو كلمة المرور غلط'
              : 'خطأ بالدخول: ${signErr.code}', Colors.red);
        }
        return;
      }
    }
    await _enter(pw);
  }

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.of(context).padding.top;
    return Scaffold(
      body: SingleChildScrollView(
        child: Column(children: [
          ClipPath(
            clipper: _WaveClip(),
            child: Container(
              width: double.infinity,
              padding: EdgeInsets.fromLTRB(20, top + 20, 20, 46),
              decoration: const BoxDecoration(
                gradient: LinearGradient(colors: [kPrimaryDark, kPrimary], begin: Alignment.topLeft, end: Alignment.bottomRight),
              ),
              child: const Column(children: [
                Row(children: [
                  Text('الحضور الجامعي', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800)),
                  SizedBox(width: 6),
                  Icon(Icons.circle, size: 7, color: kAccent),
                ]),
                SizedBox(height: 18),
                Icon(Icons.school_rounded, size: 72, color: Colors.white),
                SizedBox(height: 6),
                Text('جامعة المعقل', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800)),
                Text('الحضور بالباركود • الامتحانات • الكوزات', style: TextStyle(color: Colors.white70, fontSize: 12)),
              ]),
            ),
          ),
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(22, 18, 22, 24),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  const Text('تسجيل الدخول', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: kPrimaryDark)),
                  const SizedBox(height: 6),
                  Text('الطالب يدخل برقمه الجامعي، والكادر باسم المستخدم الذي أعطاه إياه المدير',
                      style: TextStyle(color: Colors.grey.shade600, fontSize: 13)),
                  const SizedBox(height: 22),
                  TextField(
                    controller: u,
                    decoration: const InputDecoration(
                        hintText: 'اسم المستخدم / الرقم الجامعي', prefixIcon: Icon(Icons.person_outline)),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: p,
                    obscureText: hide,
                    onSubmitted: (_) => login(),
                    decoration: InputDecoration(
                        hintText: 'كلمة المرور',
                        prefixIcon: const Icon(Icons.lock_outline),
                        suffixIcon: IconButton(
                            icon: Icon(hide ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                            onPressed: () => setState(() => hide = !hide))),
                  ),
                  const SizedBox(height: 22),
                  SizedBox(
                    height: 54,
                    child: FilledButton.icon(
                        onPressed: busy ? null : login,
                        icon: busy
                            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                            : const Icon(Icons.login_rounded),
                        label: const Text('تسجيل الدخول')),
                  ),
                  const SizedBox(height: 14),
                  Text('الطالب: أول مرة يكتب رقمه الجامعي بالخانتين، وبعدها يختار رمز جديد',
                      textAlign: TextAlign.center, style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
                ]),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

// ----------------------------- تقرير الحضور (مشترك) -----------------------------
class ReportView extends StatelessWidget {
  final String? dept;
  const ReportView({super.key, this.dept});
  @override
  Widget build(BuildContext context) {
    final subs = DB.subjectsOfDept(dept);
    if (subs.isEmpty) return empty('ماكو مواد');
    return ListView(
      padding: const EdgeInsets.all(8),
      children: [
        for (final s in subs)
          Card(
            child: ExpansionTile(
              leading: const Icon(Icons.menu_book),
              title: Text('${s['name']}'),
              subtitle: Text(
                  '${DB.subInfo(s)}\nالحضور: ${pct(DB.attRate(subjectId: s['id']))} • محاضرات: ${DB.lectures(s['id'])}'
                  '${dept == null ? ' • ${s['dept']}' : ''}'),
              children: [
                for (final st in DB.studentsOf(s))
                  Builder(builder: (_) {
                    final r = DB.attRate(subjectId: s['id'], studentId: st['id']);
                    final has = DB.lectures(s['id']) > 0;
                    final low = has && r < 0.75;
                    return ListTile(
                      dense: true,
                      title: Text('${st['name']}'),
                      subtitle: Text(DB.stuInfo(st)),
                      trailing: Text(has ? pct(r) : '-',
                          style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: low ? Colors.red : Colors.green)),
                    );
                  }),
              ],
            ),
          ),
      ],
    );
  }
}

// ----------------------------- إدارة المستخدمين (مشترك) -----------------------------
/// اختيار مواد الدكتور (رئيس القسم أو رئيس الجامعة)
Future<void> assignSubjects(BuildContext context, String doc, String dept) async {
  final subs = DB.subjectsOfDept(dept)
    ..sort((a, b) => '${a['stage']}${a['semester']}${a['name']}'.compareTo('${b['stage']}${b['semester']}${b['name']}'));
  if (subs.isEmpty) {
    toast(context, 'ماكو مواد بهذا القسم', Colors.orange);
    return;
  }
  final sel = {for (final s in subs) if (s['doctor'] == doc) '${s['_id']}'};
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, set) => AlertDialog(
        title: Text('مواد الدكتور ($doc)'),
        content: SizedBox(
          width: 420,
          height: 460,
          child: ListView(children: [
            for (final s in subs)
              CheckboxListTile(
                value: sel.contains('${s['_id']}'),
                title: Text('${s['name']}'),
                subtitle: Text(DB.subInfo(s) +
                    (('${s['doctor'] ?? ''}'.isNotEmpty && s['doctor'] != doc) ? '\nحالياً: ${s['doctor']}' : '')),
                onChanged: (v) => set(() => v == true ? sel.add('${s['_id']}') : sel.remove('${s['_id']}')),
              ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('إلغاء')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text('حفظ (${sel.length})')),
        ],
      ),
    ),
  );
  if (ok != true) return;
  try {
    for (final s in subs) {
      final has = s['doctor'] == doc, want = sel.contains('${s['_id']}');
      if (has == want) continue;
      await FirebaseFirestore.instance.collection('subjects').doc('${s['_id']}').update({'doctor': want ? doc : ''});
    }
    if (context.mounted) toast(context, 'انحفظت مواد الدكتور ✓', Colors.green);
  } catch (e) {
    if (context.mounted) toast(context, 'ما انحفظ: $e', Colors.red);
  }
}

class UsersManage extends StatefulWidget {
  final List<String> roles;
  final String? dept; // null = كل الأقسام
  const UsersManage({super.key, required this.roles, this.dept});
  @override
  State<UsersManage> createState() => _UsersManageState();
}

class _UsersManageState extends Live<UsersManage> {
  Future<void> add() async {
    var dept = widget.dept;
    if (dept == null) {
      dept = await showDialog<String>(
        context: context,
        builder: (c) => SimpleDialog(title: const Text('اختار القسم'), children: [
          for (final d in DB.depts())
            SimpleDialogOption(onPressed: () => Navigator.pop(c, d), child: Text(d)),
        ]),
      );
      if (dept == null || !mounted) return;
    }
    final r = await formDialog(context, 'إضافة مستخدم • $dept', ['الاسم', 'اسم المستخدم (إنكليزي)', 'كلمة المرور (6 أو أكثر)'],
        dropLabel: 'الصلاحية',
        drop: {for (final x in widget.roles) x: roleNames[x]!});
    if (r == null || !mounted) return;
    final un = r['اسم المستخدم (إنكليزي)']!.toLowerCase();
    final pw = r['كلمة المرور (6 أو أكثر)']!;
    if (!RegExp(r'^[a-z][a-z0-9_.-]*$').hasMatch(un)) {
      toast(context, 'اسم المستخدم لازم يبدي بحرف إنكليزي وبدون مسافات', Colors.red);
      return;
    }
    if (pw.length < 6) {
      toast(context, 'كلمة المرور لازم 6 أحرف أو أكثر', Colors.red);
      return;
    }
    if (DB.find('accounts', (e) => e['_id'] == un) != null) {
      toast(context, 'اسم المستخدم موجود', Colors.red);
      return;
    }
    try {
      try {
        await createLogin(un, pw);
      } on FirebaseAuthException catch (e) {
        // الحساب موجود من قبل (مثلاً انحذف وانضاف من جديد): نرجع نعطيه الصلاحية
        if (e.code != 'email-already-in-use') rethrow;
        if (mounted) toast(context, 'الحساب موجود من قبل، يدخل برمزه القديم', Colors.orange);
      }
      await DB.put('accounts', {
        'name': r['الاسم'],
        'username': un,
        'role': r['_drop'] ?? widget.roles.first,
        'dept': dept,
      }, un);
      if (mounted) toast(context, 'انضاف ✓  المستخدم: $un', Colors.green);
      if ((r['_drop'] ?? widget.roles.first) == 'doctor' && mounted) {
        await assignSubjects(context, un, dept);
      }
    } catch (e) {
      if (mounted) toast(context, 'ما انضاف: $e', Colors.red);
    }
  }

  @override
  Widget build(BuildContext context) {
    final us = DB.list('accounts').where((u) =>
        widget.roles.contains(u['role']) &&
        (widget.dept == null || u['dept'] == widget.dept)).toList();
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
          onPressed: add, icon: const Icon(Icons.person_add), label: const Text('إضافة')),
      body: us.isEmpty
          ? empty('ماكو مستخدمين')
          : ListView(children: [
              for (final u in us)
                ListTile(
                  leading: CircleAvatar(child: Text('${u['name']}'.characters.first)),
                  title: Text('${u['name']}'),
                  subtitle: Text('${roleNames[u['role']]} • ${u['username']} • ${u['dept']}'
                      '${u['role'] == 'doctor' ? '\nالمواد: ${DB.list('subjects').where((x) => x['doctor'] == u['username']).length} (اضغط للتعديل)' : ''}'),
                  isThreeLine: u['role'] == 'doctor',
                  onTap: u['role'] == 'doctor' ? () => assignSubjects(context, '${u['username']}', '${u['dept']}') : null,
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline, color: Colors.red),
                    onPressed: () async {
                      if (!await confirm(context, 'حذف ${u['name']}؟')) return;
                      await DB.del('accounts', u);
                    },
                  ),
                ),
            ]),
    );
  }
}

// ----------------------------- إدارة المواد -----------------------------
class SubjectsManage extends StatefulWidget {
  final String dept;
  const SubjectsManage({super.key, required this.dept});
  @override
  State<SubjectsManage> createState() => _SubjectsManageState();
}

class _SubjectsManageState extends Live<SubjectsManage> {
  Map<String, String> get doctors => {
        for (final u in DB.list('accounts').where((u) => u['role'] == 'doctor' && u['dept'] == widget.dept))
          '${u['username']}': '${u['name']}'
      };

  Future<void> edit([Rec? s]) async {
    if (doctors.isEmpty) {
      toast(context, 'أضف دكتور أولاً', Colors.orange);
      return;
    }
    final r = await formDialog(context, s == null ? 'إضافة مادة' : 'تعديل المادة', ['اسم المادة', 'المرحلة', 'الفصل'],
        dropLabel: 'الدكتور',
        drop: doctors,
        init: s == null ? ['', 'المرحلة الأولى', '1'] : ['${s['name']}', '${s['stage'] ?? ''}', '${s['semester'] ?? ''}'],
        dropInit: s == null ? null : '${s['doctor']}');
    if (r == null) return;
    if (s == null) {
      final id = uid();
      await DB.put('subjects', {
        'id': id, 'name': r['اسم المادة'], 'dept': widget.dept, 'doctor': r['_drop'],
        'stage': r['المرحلة'], 'semester': r['الفصل'], 'code': '',
      }, id);
    } else {
      s['name'] = r['اسم المادة'];
      s['stage'] = r['المرحلة'];
      s['semester'] = r['الفصل'];
      s['doctor'] = r['_drop'];
      await DB.put('subjects', s);
    }
  }

  @override
  Widget build(BuildContext context) {
    final subs = DB.subjectsOfDept(widget.dept);
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
          onPressed: edit, icon: const Icon(Icons.add), label: const Text('مادة')),
      body: subs.isEmpty
          ? empty('ماكو مواد')
          : ListView(children: [
              for (final s in subs)
                ListTile(
                  leading: const Icon(Icons.menu_book),
                  title: Text('${s['name']}'),
                  subtitle: Text('${DB.subInfo(s)}\nالدكتور: ${DB.find('accounts', (u) => u['username'] == s['doctor'])?['name'] ?? '-'}'),
                  isThreeLine: true,
                  onTap: () => edit(s),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline, color: Colors.red),
                    onPressed: () async {
                      if (!await confirm(context, 'حذف ${s['name']}؟')) return;
                      await DB.del('subjects', s);
                    },
                  ),
                ),
            ]),
    );
  }
}

// ----------------------------- إدارة الطلاب -----------------------------
class StudentsManage extends StatefulWidget {
  final String dept;
  const StudentsManage({super.key, required this.dept});
  @override
  State<StudentsManage> createState() => _StudentsManageState();
}

class _StudentsManageState extends Live<StudentsManage> {
  String q = '', stage = '';

  Future<void> add() async {
    final r = await formDialog(context, 'إضافة طالب', ['الرقم الجامعي', 'الاسم', 'المرحلة', 'الدراسة'],
        init: ['', '', 'المرحلة الأولى', 'صباحي']);
    if (r == null) return;
    final id = r['الرقم الجامعي']!;
    if (DB.find('students', (s) => s['id'] == id) != null) {
      if (mounted) toast(context, 'الرقم موجود', Colors.red);
      return;
    }
    await DB.put('students', {
      'id': id, 'name': r['الاسم'], 'dept': widget.dept,
      'stage': r['المرحلة'], 'shift': r['الدراسة'],
    }, id);
  }

  @override
  Widget build(BuildContext context) {
    final st = DB.list('students').where((s) =>
        s['dept'] == widget.dept &&
        (stage.isEmpty || s['stage'] == stage) &&
        ('${s['name']}'.contains(q) || '${s['id']}'.contains(q))).toList();
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
          onPressed: add, icon: const Icon(Icons.person_add), label: const Text('طالب')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: TextField(
            decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search), hintText: 'بحث بالاسم أو الرقم', border: OutlineInputBorder()),
            onChanged: (v) => setState(() => q = v),
          ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(children: [
            for (final x in ['', ...DB.list('students').where((s) => s['dept'] == widget.dept).map((s) => '${s['stage'] ?? ''}').where((x) => x.isNotEmpty).toSet()])
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: ChoiceChip(
                  label: Text(x.isEmpty ? 'الكل' : x),
                  selected: stage == x,
                  onSelected: (_) => setState(() => stage = x),
                ),
              ),
          ]),
        ),
        Expanded(
          child: st.isEmpty
              ? empty('ماكو طلاب')
              : ListView(children: [
                  for (final s in st)
                    ListTile(
                      leading: const Icon(Icons.badge),
                      title: Text('${s['name']}'),
                      subtitle: Text('${DB.stuInfo(s)} • حضور ${pct(DB.attRate(studentId: s['id']))}'),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline, color: Colors.red),
                        onPressed: () async {
                          if (!await confirm(context, 'حذف ${s['name']}؟')) return;
                          await DB.del('students', s);
                        },
                      ),
                    ),
                ]),
        ),
      ]),
    );
  }
}

// ================================ رئيس الجامعة ================================
class PresidentHome extends StatefulWidget {
  final Rec user;
  const PresidentHome({super.key, required this.user});
  @override
  State<PresidentHome> createState() => _PresidentHomeState();
}

class _PresidentHomeState extends Live<PresidentHome> {
  int i = 0;

  Widget dashboard() {
    final depts = DB.depts();
    final noDoc = DB.list('subjects').where((s) => '${s['doctor'] ?? ''}'.isEmpty ||
        DB.find('accounts', (a) => a['username'] == s['doctor']) == null).length;
    return ListView(padding: const EdgeInsets.fromLTRB(12, 4, 12, 20), children: [
      statGrid([
        StatCard('الطلاب', '${DB.list('students').length}', Icons.school_outlined, sub: 'بكل الأقسام'),
        StatCard('التدريسيين', '${DB.list('accounts').where((u) => u['role'] == 'doctor').length}', Icons.badge_outlined, sub: 'حساب فعّال'),
        StatCard('المواد', '${DB.list('subjects').length}', Icons.menu_book_outlined, sub: '${depts.length} أقسام'),
        StatCard('نسبة الحضور', pct(DB.attRate()), Icons.fact_check_outlined, sub: 'لكل المواد'),
        StatCard('امتحانات وكوزات', '${DB.list('exams').length}', Icons.quiz_outlined),
        StatCard('معدل الدرجات', pct(DB.avgScore()), Icons.grade_outlined),
      ]),
      if (noDoc > 0) ...[
        sectionTitle('تحتاج إجراء'),
        Card(
          child: ListTile(
            leading: const Icon(Icons.person_search_outlined, color: kAccent),
            title: Text('$noDoc مادة بلا تدريسي'),
            subtitle: const Text('عيّن تدريسيين من تبويب المستخدمين (اضغط على الدكتور)'),
            onTap: () => setState(() => i = 2),
          ),
        ),
      ],
      sectionTitle('الأقسام', depts.length),
      for (final dp in depts)
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(color: kSoft, borderRadius: BorderRadius.circular(12)),
                child: const Icon(Icons.apartment_rounded, color: kPrimary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(dp, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                  Text('طلاب ${DB.list('students').where((s) => s['dept'] == dp).length} • مواد ${DB.subjectsOfDept(dp).length} • معدل ${pct(DB.avgScore(dept: dp))}',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                ]),
              ),
              ring(DB.list('attendance').isEmpty ? null : DB.attRate(dept: dp)),
            ]),
          ),
        ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      dashboard(),
      const ReportView(),
      const UsersManage(roles: ['head', 'doctor']),
      ChatListPage(me: meOf(widget.user)),
    ];
    const titles = ['الحضور الجامعي', 'التقارير', 'المستخدمون', 'المحادثات'];
    return Scaffold(
      appBar: i == 0
          ? UniHeader(title: titles[0], name: '${widget.user['name']}', line: 'مدير النظام', actions: [logoutBtn(context)])
          : UniHeader(title: titles[i], sub: 'كل الأقسام', actions: [logoutBtn(context)]),
      body: pages[i],
      bottomNavigationBar: NavigationBar(
        selectedIndex: i,
        onDestinationSelected: (v) => setState(() => i = v),
        destinations: [
          const NavigationDestination(icon: Icon(Icons.grid_view_outlined), selectedIcon: Icon(Icons.grid_view_rounded), label: 'الرئيسية'),
          const NavigationDestination(icon: Icon(Icons.bar_chart_outlined), selectedIcon: Icon(Icons.bar_chart), label: 'التقارير'),
          const NavigationDestination(icon: Icon(Icons.people_outline), selectedIcon: Icon(Icons.people), label: 'المستخدمون'),
          NavigationDestination(icon: chatIcon('${widget.user['username']}', Icons.chat), label: 'المحادثات'),
        ],
      ),
    );
  }
}

// ================================ رئيس القسم ================================
class HeadHome extends StatefulWidget {
  final Rec user;
  const HeadHome({super.key, required this.user});
  @override
  State<HeadHome> createState() => _HeadHomeState();
}

class _HeadHomeState extends Live<HeadHome> {
  int i = 0;
  @override
  Widget build(BuildContext context) {
    final dept = '${widget.user['dept']}';
    final subs = DB.subjectsOfDept(dept);
    final noDoc = subs.where((s) => '${s['doctor'] ?? ''}'.isEmpty ||
        DB.find('accounts', (a) => a['username'] == s['doctor']) == null).toList();
    final home = ListView(padding: const EdgeInsets.fromLTRB(12, 4, 12, 20), children: [
      statGrid([
        StatCard('الطلاب', '${DB.list('students').where((x) => x['dept'] == dept).length}', Icons.school_outlined, sub: 'حساب القسم'),
        StatCard('التدريسيين', '${DB.list('accounts').where((u) => u['role'] == 'doctor' && u['dept'] == dept).length}', Icons.badge_outlined, sub: 'حساب فعّال'),
        StatCard('المواد', '${subs.length}', Icons.menu_book_outlined, sub: 'بالقسم'),
        StatCard('نسبة الحضور', pct(DB.attRate(dept: dept)), Icons.fact_check_outlined, sub: 'لكل المواد'),
      ]),
      if (noDoc.isNotEmpty) ...[
        sectionTitle('تحتاج إجراء'),
        Card(
          child: ListTile(
            leading: const Icon(Icons.person_search_outlined, color: kAccent),
            title: Text('${noDoc.length} مادة بلا تدريسي'),
            subtitle: const Text('اضغط على الدكتور بتبويب الدكاترة واختار مواده'),
            onTap: () => setState(() => i = 3),
          ),
        ),
      ],
      sectionTitle('التقارير'),
      Card(
        child: ListTile(
          leading: const Icon(Icons.bar_chart_rounded, color: kPrimary),
          title: const Text('تقرير الحضور لكل المواد'),
          subtitle: const Text('نسبة كل طالب بكل مادة، والأقل من 75% بالأحمر'),
          trailing: const Icon(Icons.chevron_left),
          onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => Scaffold(appBar: AppBar(title: const Text('تقرير الحضور')), body: ReportView(dept: dept)))),
        ),
      ),
    ]);
    final pages = [
      home,
      SubjectsManage(dept: dept),
      StudentsManage(dept: dept),
      UsersManage(roles: const ['doctor'], dept: dept),
      ChatListPage(me: meOf(widget.user)),
    ];
    const titles = ['الحضور الجامعي', 'المواد', 'الطلاب', 'التدريسيين', 'المحادثات'];
    return Scaffold(
      appBar: i == 0
          ? UniHeader(title: titles[0], name: '${widget.user['name']}', line: 'رئيس قسم • $dept', actions: [logoutBtn(context)])
          : UniHeader(title: titles[i], sub: dept, actions: [logoutBtn(context)]),
      body: pages[i],
      bottomNavigationBar: NavigationBar(
        selectedIndex: i,
        onDestinationSelected: (v) => setState(() => i = v),
        destinations: [
          const NavigationDestination(icon: Icon(Icons.grid_view_outlined), selectedIcon: Icon(Icons.grid_view_rounded), label: 'الرئيسية'),
          const NavigationDestination(icon: Icon(Icons.menu_book_outlined), selectedIcon: Icon(Icons.menu_book), label: 'المواد'),
          const NavigationDestination(icon: Icon(Icons.groups_outlined), selectedIcon: Icon(Icons.groups), label: 'الطلاب'),
          const NavigationDestination(icon: Icon(Icons.badge_outlined), selectedIcon: Icon(Icons.badge), label: 'التدريسيين'),
          NavigationDestination(icon: chatIcon('${widget.user['username']}', Icons.chat), label: 'المحادثات'),
        ],
      ),
    );
  }
}

// ================================ الدكتور ================================
class DoctorHome extends StatefulWidget {
  final Rec user;
  const DoctorHome({super.key, required this.user});
  @override
  State<DoctorHome> createState() => _DoctorHomeState();
}

class _DoctorHomeState extends Live<DoctorHome> {
  @override
  Widget build(BuildContext context) {
    final subs = DB.list('subjects').where((s) => s['doctor'] == widget.user['username']).toList();
    final students = <String>{};
    final over = <String>{};
    for (final sub in subs) {
      final has = DB.lectures(sub['id']) > 0;
      for (final st in DB.studentsOf(sub)) {
        students.add('${st['id']}');
        if (has && DB.attRate(subjectId: sub['id'], studentId: st['id']) < 0.75) over.add('${st['id']}');
      }
    }
    final rates = [for (final sub in subs) if (DB.lectures(sub['id']) > 0) DB.attRate(subjectId: sub['id'])];
    final avg = rates.isEmpty ? null : rates.reduce((a, b) => a + b) / rates.length;
    final todayCount = DB.list('attendance').where((a) => a['date'] == today() && subs.any((x) => x['id'] == a['subjectId'])).map((a) => a['subjectId']).toSet().length;
    return Scaffold(
      appBar: UniHeader(
        title: 'الحضور الجامعي',
        name: '${widget.user['name']}',
        line: 'تدريسي • ${widget.user['dept']}',
        actions: [
          IconButton(
            tooltip: 'المحادثات',
            icon: chatIcon('${widget.user['username']}', Icons.chat_bubble_outline),
            onPressed: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => ChatListPage(me: meOf(widget.user), standalone: true))),
          ),
          logoutBtn(context),
        ],
      ),
      body: ListView(padding: const EdgeInsets.fromLTRB(12, 4, 12, 20), children: [
        statGrid([
          StatCard('طلابي', '${students.length}', Icons.groups_outlined, sub: 'بكل المواد'),
          StatCard('موادي', '${subs.length}', Icons.menu_book_outlined, sub: 'هذا الفصل'),
          StatCard('متوسط الحضور', avg == null ? '–' : pct(avg), Icons.fact_check_outlined, sub: 'لكل المواد'),
          StatCard('تجاوزوا الحد', '${over.length}', Icons.warning_amber_rounded,
              sub: 'يحتاجون متابعة', color: over.isEmpty ? null : kRed),
        ]),
        sectionTitle('موادي', subs.length),
        if (subs.isEmpty) empty('ماكو مواد مسندة إلك\nرئيس القسم يختار موادك من تبويب التدريسيين'),
        for (final s in subs)
          subjectCard(
            s,
            line: '${s['code'] ?? ''} • طلاب ${DB.studentsOf(s).length} • محاضرات ${DB.lectures(s['id'])}',
            rate: DB.lectures(s['id']) > 0 ? DB.attRate(subjectId: s['id']) : null,
            extra: Wrap(spacing: 6, children: [
              if ('${s['stage'] ?? ''}'.isNotEmpty) tag('${s['stage']}', kPrimary),
              if (DB.list('attendance').any((a) => a['subjectId'] == s['id'] && a['date'] == today())) tag('سُجّل اليوم', kGreen),
            ]),
            onTap: () async {
              await Navigator.push(context, MaterialPageRoute(builder: (_) => SubjectPage(subject: s)));
              setState(() {});
            },
          ),
        if (todayCount == 0 && subs.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text('اضغط على المادة ثم «تسجيل الحضور بالباركود» لبدء محاضرة اليوم',
                textAlign: TextAlign.center, style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
          ),
      ]),
    );
  }
}

class SubjectPage extends StatefulWidget {
  final Rec subject;
  const SubjectPage({super.key, required this.subject});
  @override
  State<SubjectPage> createState() => _SubjectPageState();
}

class _SubjectPageState extends Live<SubjectPage> {
  Future<void> go(Widget p) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => p));
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.subject;
    final exams = DB.list('exams').where((e) => e['subjectId'] == s['id']).toList();
    final lec = DB.lectures(s['id']);
    return Scaffold(
      appBar: UniHeader(
        title: '${s['name']}',
        sub: DB.subInfo(s),
        back: true,
        extra: 64,
        bottom: headerPills([
          ('${DB.studentsOf(s).length}', 'الطلاب'),
          ('$lec', 'المحاضرات'),
          (lec == 0 ? '–' : pct(DB.attRate(subjectId: s['id'])), 'الحضور'),
        ]),
      ),
      body: ListView(padding: const EdgeInsets.all(12), children: [
        SizedBox(
          height: 60,
          child: FilledButton.icon(
            onPressed: () => go(AttendancePage(subject: s)),
            icon: const Icon(Icons.qr_code_scanner),
            label: const Text('تسجيل الحضور بالباركود', style: TextStyle(fontSize: 17)),
          ),
        ),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: OutlinedButton.icon(
                onPressed: () => go(AttendanceHistoryPage(subject: s)),
                icon: const Icon(Icons.history),
                label: const Text('سجل الحضور')),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: OutlinedButton.icon(
                onPressed: () => go(ExamCreatePage(subject: s)),
                icon: const Icon(Icons.add_task),
                label: const Text('امتحان / كوز')),
          ),
        ]),
        sectionTitle('الامتحانات والكوزات', exams.length),
        if (exams.isEmpty) empty('ماكو امتحانات بعد'),
        for (final e in exams)
          Card(
            child: ListTile(
              leading: CircleAvatar(
                  backgroundColor: kSoft,
                  child: Icon(e['type'] == 'quiz' ? Icons.bolt : Icons.assignment_outlined, color: kPrimary)),
              title: Text('${e['title']}'),
              subtitle: Text(
                  '${e['type'] == 'quiz' ? 'كوز' : 'امتحان'} • ${(e['questions'] as List).length} سؤال • ${e['duration']} دقيقة\n'
                  'سلّموا: ${DB.list('submissions').where((r) => r['examId'] == e['id']).length} • المعدل: ${pct(DB.avgScore(examId: e['id']))}'),
              isThreeLine: true,
              onTap: () => go(ExamResultsPage(exam: e)),
            ),
          ),
      ]),
    );
  }
}

// ---------- تسجيل الحضور بالباركود ----------
class AttendancePage extends StatefulWidget {
  final Rec subject;
  const AttendancePage({super.key, required this.subject});
  @override
  State<AttendancePage> createState() => _AttendancePageState();
}

class _AttendancePageState extends Live<AttendancePage> {
  final ctrl = MobileScannerController(detectionSpeed: DetectionSpeed.noDuplicates);
  final present = <String>{};
  String shift = '';
  List<Rec> get studs => DB.studentsOf(widget.subject, shift);
  late final List<String> shifts = DB
      .studentsOf(widget.subject)
      .map((s) => '${s['shift'] ?? ''}')
      .where((x) => x.isNotEmpty)
      .toSet()
      .toList();

  @override
  void initState() {
    super.initState();
    for (final a in DB.list('attendance')) {
      if (a['subjectId'] == widget.subject['id'] && a['date'] == today() && a['present'] == true) {
        present.add('${a['studentId']}');
      }
    }
  }

  @override
  void dispose() {
    ctrl.dispose();
    super.dispose();
  }

  void onDetect(BarcodeCapture cap) {
    for (final b in cap.barcodes) {
      final v = b.rawValue?.trim();
      if (v == null || v.isEmpty) continue;
      Rec? st;
      for (final s in studs) {
        if ('${s['id']}' == v) st = s;
      }
      if (st == null) {
        toast(context, 'باركود مو لطالب بهالمادة: $v', Colors.red);
      } else if (present.contains(v)) {
        toast(context, '${st['name']} مسجّل من قبل', Colors.orange);
      } else {
        HapticFeedback.mediumImpact();
        setState(() => present.add(v));
        toast(context, '✓ حاضر: ${st['name']}', Colors.green);
      }
    }
  }

  Future<void> save() async {
    final sid = widget.subject['id'];
    final d = today();
    final list = studs;
    final ids = list.map((s) => '${s['id']}').toSet();
    // يحذف بس سجلات طلاب هذي الشعبة (حتى ما يأثر على الدراسة الثانية)
    assert(ids.isNotEmpty || list.isEmpty);
    final here = list.where((s) => present.contains('${s['id']}')).length;
    await DB.putMany('attendance', [
      for (final s in list)
        {
          'subjectId': sid,
          'studentId': s['id'],
          'date': d,
          'present': present.contains('${s['id']}'),
        }
    ], (r) => '${r['subjectId']}_${r['date']}_${r['studentId']}');
    if (!mounted) return;
    toast(context, 'انحفظ: $here حاضر • ${list.length - here} غائب', Colors.green);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('حضور ${widget.subject['name']} • ${today()}'),
        actions: [
          IconButton(icon: const Icon(Icons.flash_on), onPressed: () => ctrl.toggleTorch()),
          IconButton(icon: const Icon(Icons.cameraswitch), onPressed: () => ctrl.switchCamera()),
        ],
      ),
      body: Column(children: [
        SizedBox(
          height: 260,
          child: ClipRRect(
            borderRadius: const BorderRadius.vertical(bottom: Radius.circular(16)),
            child: MobileScanner(controller: ctrl, onDetect: onDetect),
          ),
        ),
        if (shifts.length > 1)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: SegmentedButton<String>(
              segments: [
                for (final x in shifts) ButtonSegment(value: x, label: Text(x)),
                const ButtonSegment(value: '', label: Text('الكل')),
              ],
              selected: {shift},
              onSelectionChanged: (v) => setState(() => shift = v.first),
            ),
          ),
        Padding(
          padding: const EdgeInsets.all(10),
          child: Text('الحاضرون: ${studs.where((s) => present.contains('${s['id']}')).length} / ${studs.length}',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        ),
        Expanded(
          child: ListView(children: [
            for (final s in studs)
              CheckboxListTile(
                value: present.contains('${s['id']}'),
                title: Text('${s['name']}'),
                subtitle: Text(DB.stuInfo(s)),
                secondary: Icon(present.contains('${s['id']}') ? Icons.check_circle : Icons.cancel,
                    color: present.contains('${s['id']}') ? Colors.green : Colors.red),
                onChanged: (v) => setState(() =>
                    v == true ? present.add('${s['id']}') : present.remove('${s['id']}')),
              ),
          ]),
        ),
      ]),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: SizedBox(
            height: 52,
            child: FilledButton.icon(
                onPressed: save, icon: const Icon(Icons.save), label: const Text('حفظ (الباقي غياب)')),
          ),
        ),
      ),
    );
  }
}

// ---------- سجل الحضور ----------
class AttendanceHistoryPage extends StatefulWidget {
  final Rec subject;
  const AttendanceHistoryPage({super.key, required this.subject});
  @override
  State<AttendanceHistoryPage> createState() => _AttendanceHistoryPageState();
}

class _AttendanceHistoryPageState extends Live<AttendanceHistoryPage> {
  @override
  Widget build(BuildContext context) {
    final recs = DB.list('attendance').where((a) => a['subjectId'] == widget.subject['id']).toList();
    final dates = recs.map((a) => '${a['date']}').toSet().toList()..sort((a, b) => b.compareTo(a));
    return Scaffold(
      appBar: AppBar(title: Text('سجل حضور ${widget.subject['name']}')),
      body: dates.isEmpty
          ? empty('ماكو محاضرات مسجلة')
          : ListView(children: [
              for (final d in dates)
                Builder(builder: (_) {
                  final day = recs.where((a) => a['date'] == d).toList();
                  final p = day.where((a) => a['present'] == true).length;
                  return Card(
                    child: ExpansionTile(
                      title: Text(d),
                      subtitle: Text('حاضر $p • غائب ${day.length - p}'),
                      children: [
                        for (final a in day)
                          ListTile(
                            dense: true,
                            title: Text('${DB.find('students', (s) => s['id'] == a['studentId'])?['name'] ?? a['studentId']}'),
                            trailing: Text(a['present'] == true ? 'حاضر' : 'غائب',
                                style: TextStyle(color: a['present'] == true ? Colors.green : Colors.red)),
                            onTap: () async {
                              a['present'] = a['present'] != true;
                              await DB.put('attendance', a);
                            },
                          ),
                      ],
                    ),
                  );
                }),
            ]),
    );
  }
}

// ---------- إنشاء امتحان / كوز ----------
class _Q {
  final q = TextEditingController();
  final o = List.generate(4, (_) => TextEditingController());
  int correct = 0;
}

class ExamCreatePage extends StatefulWidget {
  final Rec subject;
  const ExamCreatePage({super.key, required this.subject});
  @override
  State<ExamCreatePage> createState() => _ExamCreatePageState();
}

class _ExamCreatePageState extends Live<ExamCreatePage> {
  final title = TextEditingController();
  final dur = TextEditingController(text: '10');
  String type = 'quiz';
  final qs = <_Q>[_Q()];
  static const letters = ['أ', 'ب', 'ج', 'د'];

  Future<void> save() async {
    if (title.text.trim().isEmpty) {
      toast(context, 'اكتب عنوان', Colors.red);
      return;
    }
    final out = <Rec>[];
    final answers = <int>[];
    for (var n = 0; n < qs.length; n++) {
      final q = qs[n];
      final opts = <String>[];
      int? correct;
      for (var j = 0; j < 4; j++) {
        final t = q.o[j].text.trim();
        if (t.isEmpty) continue;
        if (j == q.correct) correct = opts.length;
        opts.add(t);
      }
      if (q.q.text.trim().isEmpty || opts.length < 2 || correct == null) {
        toast(context, 'السؤال ${n + 1} ناقص (نص + خيارين + الجواب الصحيح)', Colors.red);
        return;
      }
      out.add({'q': q.q.text.trim(), 'options': opts});
      answers.add(correct);
    }
    final eid = uid();
    // الأجوبة الصحيحة بمكان منفصل ما يشوفه الطالب
    await DB.put('keys', {'subjectId': widget.subject['id'], 'answers': answers}, eid);
    await DB.put('exams', {
      'id': eid,
      'subjectId': widget.subject['id'],
      'title': title.text.trim(),
      'type': type,
      'duration': int.tryParse(dur.text) ?? 10,
      'date': today(),
      'questions': out,
    }, eid);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('امتحان / كوز جديد')),
      body: ListView(padding: const EdgeInsets.all(12), children: [
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'quiz', label: Text('كوز'), icon: Icon(Icons.bolt)),
            ButtonSegment(value: 'exam', label: Text('امتحان'), icon: Icon(Icons.assignment)),
          ],
          selected: {type},
          onSelectionChanged: (v) => setState(() => type = v.first),
        ),
        const SizedBox(height: 10),
        TextField(controller: title, decoration: const InputDecoration(labelText: 'العنوان', border: OutlineInputBorder())),
        const SizedBox(height: 10),
        TextField(
            controller: dur,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'المدة (دقائق)', border: OutlineInputBorder())),
        for (var n = 0; n < qs.length; n++)
          Card(
            margin: const EdgeInsets.only(top: 12),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Text('سؤال ${n + 1}', style: const TextStyle(fontWeight: FontWeight.bold)),
                  const Spacer(),
                  if (qs.length > 1)
                    IconButton(
                        icon: const Icon(Icons.delete_outline, color: Colors.red),
                        onPressed: () => setState(() => qs.removeAt(n))),
                ]),
                TextField(controller: qs[n].q, maxLines: null, decoration: const InputDecoration(labelText: 'نص السؤال')),
                for (var j = 0; j < 4; j++)
                  TextField(
                      controller: qs[n].o[j],
                      decoration: InputDecoration(labelText: 'الخيار ${letters[j]}${j >= 2 ? ' (اختياري)' : ''}')),
                const SizedBox(height: 8),
                Wrap(spacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  const Text('الصحيح:'),
                  for (var j = 0; j < 4; j++)
                    ChoiceChip(
                      label: Text(letters[j]),
                      selected: qs[n].correct == j,
                      onSelected: (_) => setState(() => qs[n].correct = j),
                    ),
                ]),
              ]),
            ),
          ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
            onPressed: () => setState(() => qs.add(_Q())),
            icon: const Icon(Icons.add),
            label: const Text('إضافة سؤال')),
        const SizedBox(height: 80),
      ]),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: SizedBox(
              height: 52,
              child: FilledButton.icon(onPressed: save, icon: const Icon(Icons.publish), label: const Text('نشر للطلاب'))),
        ),
      ),
    );
  }
}

// ---------- نتائج امتحان ----------
class ExamResultsPage extends StatelessWidget {
  final Rec exam;
  const ExamResultsPage({super.key, required this.exam});
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
      valueListenable: DB.version, builder: (context, _, __) => _build(context));

  Widget _build(BuildContext context) {
    final rs = DB.list('submissions').where((r) => r['examId'] == exam['id']).toList()
      ..sort((a, b) => ((b['score'] as num?) ?? -1).compareTo((a['score'] as num?) ?? -1));
    return Scaffold(
      appBar: AppBar(
        title: Text('${exam['title']}'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () async {
              if (!await confirm(context, 'حذف الامتحان ونتائجه؟')) return;
              await DB.delWhere('submissions', (r) => r['examId'] == exam['id']);
              await DB.delWhere('keys', (k) => k['_id'] == exam['id']);
              await DB.del('exams', exam);
              if (context.mounted) Navigator.pop(context);
            },
          ),
        ],
      ),
      body: rs.isEmpty
          ? empty('ماكو طالب سلّم بعد')
          : ListView(children: [
              ListTile(title: Text('المعدل: ${pct(DB.avgScore(examId: exam['id']))} • عدد المسلّمين: ${rs.length}')),
              const Divider(),
              for (var n = 0; n < rs.length; n++)
                ListTile(
                  leading: CircleAvatar(child: Text('${n + 1}')),
                  title: Text('${DB.find('students', (s) => s['id'] == rs[n]['studentId'])?['name'] ?? rs[n]['studentId']}'),
                  subtitle: Text('${rs[n]['date']}'),
                  trailing: Text(rs[n]['score'] == null ? '...' : '${rs[n]['score']} / ${rs[n]['total']}',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                ),
            ]),
    );
  }
}

// ================================ الطالب ================================
class StudentHome extends StatefulWidget {
  final Rec user;
  const StudentHome({super.key, required this.user});
  @override
  State<StudentHome> createState() => _StudentHomeState();
}

class _StudentHomeState extends Live<StudentHome> {
  int i = 0;
  String get sid => '${widget.user['studentId'] ?? widget.user['username']}';
  Rec get me => DB.find('students', (s) => s['id'] == sid) ?? {'id': sid, 'name': widget.user['name'], 'dept': widget.user['dept']};
  List<Rec> get mySubjects => DB.subjectsOfDept('${me['dept']}')
      .where((s) => '${s['stage'] ?? ''}'.isEmpty || s['stage'] == me['stage'])
      .toList();

  bool get _ascii => RegExp(r'^[\x20-\x7E]+$').hasMatch(sid);

  Widget barcodeBox({double width = 260}) => Container(
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14)),
        padding: const EdgeInsets.all(12),
        child: BarcodeWidget(
          barcode: _ascii ? Barcode.code128() : Barcode.qrCode(),
          data: sid,
          width: width,
          height: _ascii ? width * 0.38 : width * 0.7,
          drawText: true,
          style: const TextStyle(fontFamily: kFont, fontSize: 13),
        ),
      );

  void showBarcode() => showDialog(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('باركود الحضور', textAlign: TextAlign.center),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            barcodeBox(width: 280),
            const SizedBox(height: 10),
            Text('${me['name']}', style: const TextStyle(fontWeight: FontWeight.w800)),
            const Text('وجّه الباركود لكاميرا الدكتور', style: TextStyle(color: Colors.grey, fontSize: 12)),
          ]),
          actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('إغلاق'))],
        ),
      );

  List<Rec> _recs(Rec s) =>
      DB.list('attendance').where((a) => a['subjectId'] == s['id'] && a['studentId'] == sid).toList();

  Widget home() {
    final subs = mySubjects;
    final all = DB.list('attendance').where((a) => a['studentId'] == sid).toList();
    final absent = all.where((a) => a['present'] != true).length;
    final ids = subs.map((s) => s['id']).toSet();
    final openExams = DB.list('exams').where((e) => ids.contains(e['subjectId']) &&
        DB.find('submissions', (r) => r['examId'] == e['id'] && r['studentId'] == sid) == null).length;
    return ListView(padding: const EdgeInsets.fromLTRB(12, 4, 12, 20), children: [
      Card(
        color: kPrimaryDark,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: showBarcode,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(color: kAccent, borderRadius: BorderRadius.circular(12)),
                child: const Icon(Icons.qr_code_2_rounded, color: kPrimaryDark, size: 30),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('باركود الحضور', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16)),
                  Text('اضغط واعرضه للدكتور حتى يسجل حضورك', style: TextStyle(color: Colors.white70, fontSize: 12)),
                ]),
              ),
              const Icon(Icons.chevron_left, color: Colors.white),
            ]),
          ),
        ),
      ),
      const SizedBox(height: 6),
      statGrid([
        StatCard('نسبة حضوري', all.isEmpty ? '–' : pct(DB.attRate(studentId: sid)), Icons.fact_check_outlined,
            sub: 'حضرت ${all.length - absent} من ${all.length}'),
        StatCard('موادي', '${subs.length}', Icons.menu_book_outlined, sub: 'مسجل هذا الفصل'),
        StatCard('امتحانات متاحة', '$openExams', Icons.quiz_outlined, sub: 'بانتظار الحل', color: openExams > 0 ? kAccent : null),
        StatCard('مرات الغياب', '$absent', Icons.event_busy_outlined, sub: 'لكل المواد', color: absent > 0 ? kRed : null),
      ]),
      sectionTitle('موادي', subs.length),
      if (subs.isEmpty) empty('ماكو مواد لمرحلتك بعد'),
      for (final s in subs)
        subjectCard(s,
            rate: _recs(s).isEmpty ? null : DB.attRate(studentId: sid, subjectId: s['id']),
            onTap: () => setState(() => i = 1)),
    ]);
  }

  Widget attendance() {
    final subs = mySubjects;
    if (subs.isEmpty) return empty('ماكو مواد');
    final all = DB.list('attendance').where((a) => a['studentId'] == sid).toList();
    final present = all.where((a) => a['present'] == true).length;
    return ListView(padding: const EdgeInsets.fromLTRB(12, 4, 12, 20), children: [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('حضورك الإجمالي', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                const SizedBox(height: 4),
                Text('حضرت $present من ${all.length} محاضرة', style: TextStyle(color: Colors.grey.shade700)),
                Text('الحد المسموح للغياب 25% من كل مادة', style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
              ]),
            ),
            ring(all.isEmpty ? null : present / all.length, size: 84),
          ]),
        ),
      ),
      sectionTitle('حسب المادة'),
      for (final s in subs)
        Builder(builder: (_) {
          final recs = _recs(s);
          final abs = recs.where((a) => a['present'] != true).map((a) => '${a['date']}').toList();
          final r = recs.isEmpty ? 0.0 : (recs.length - abs.length) / recs.length;
          final low = recs.isNotEmpty && r < 0.75;
          return Card(
            child: Theme(
              data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                shape: const Border(),
                title: Row(children: [
                  Expanded(child: Text('${s['name']}', style: const TextStyle(fontWeight: FontWeight.w800))),
                  if (recs.isNotEmpty) tag(low ? 'تجاوز الحد' : 'ضمن الحد', low ? kRed : kGreen),
                ]),
                subtitle: Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: LinearProgressIndicator(
                          value: recs.isEmpty ? 0 : r, minHeight: 8, backgroundColor: kSoft, color: low ? kRed : kGreen),
                    ),
                    const SizedBox(height: 6),
                    Text(recs.isEmpty
                        ? 'لا محاضرات منتهية بعد'
                        : 'حضر ${recs.length - abs.length} • غاب ${abs.length} • المحاضرات ${recs.length} • ${pct(r)}',
                        style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
                  ]),
                ),
                children: [
                  for (final d in abs)
                    ListTile(dense: true, leading: const Icon(Icons.close_rounded, color: kRed), title: Text('غائب: $d')),
                  if (abs.isEmpty && recs.isNotEmpty)
                    const ListTile(dense: true, leading: Icon(Icons.check_rounded, color: kGreen), title: Text('ما عندك غياب بهذه المادة')),
                ],
              ),
            ),
          );
        }),
    ]);
  }

  Widget exams() {
    final ids = mySubjects.map((s) => s['id']).toSet();
    final ex = DB.list('exams').where((e) => ids.contains(e['subjectId'])).toList().reversed.toList();
    if (ex.isEmpty) return empty('ماكو امتحانات أو كوزات حالياً');
    return ListView(padding: const EdgeInsets.fromLTRB(12, 8, 12, 20), children: [
      for (final e in ex)
        Builder(builder: (_) {
          final res = DB.find('submissions', (r) => r['examId'] == e['id'] && r['studentId'] == sid);
          final sub = DB.find('subjects', (s) => s['id'] == e['subjectId']);
          return Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(children: [
                CircleAvatar(
                  radius: 22,
                  backgroundColor: res == null ? kAccent.withValues(alpha: 0.2) : kSoft,
                  child: Icon(e['type'] == 'quiz' ? Icons.bolt : Icons.assignment_outlined,
                      color: res == null ? const Color(0xFFB26A00) : kPrimary),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${e['title']}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                    Text('${sub?['name'] ?? ''} • ${e['type'] == 'quiz' ? 'كوز' : 'امتحان'} • ${e['duration']} دقيقة',
                        style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                  ]),
                ),
                if (res == null)
                  FilledButton(
                      onPressed: () async {
                        if (!await confirm(context, 'تبدي ${e['title']}؟ عندك ${e['duration']} دقيقة وما تكدر تطلع قبل التسليم')) return;
                        if (!mounted) return;
                        await Navigator.push(context, MaterialPageRoute(builder: (_) => ExamTakePage(exam: e, studentId: sid)));
                        setState(() {});
                      },
                      child: const Text('ابدأ'))
                else if (res['score'] == null)
                  tag('بانتظار التصحيح', const Color(0xFFB26A00))
                else
                  Text('${res['score']}/${res['total']}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: kPrimary)),
              ]),
            ),
          );
        }),
    ]);
  }

  Widget grades() {
    final rs = DB.list('submissions').where((r) => r['studentId'] == sid && r['score'] != null && (r['total'] as num? ?? 0) > 0).toList().reversed.toList();
    if (rs.isEmpty) return empty('ماكو درجات بعد');
    final avg = rs.map((r) => (r['score'] as num) / (r['total'] as num)).reduce((a, b) => a + b) / rs.length;
    return ListView(padding: const EdgeInsets.fromLTRB(12, 4, 12, 20), children: [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('معدل درجاتي', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                Text('${rs.length} امتحان وكوز مصحح', style: TextStyle(color: Colors.grey.shade700)),
              ]),
            ),
            ring(avg, size: 84),
          ]),
        ),
      ),
      sectionTitle('التفاصيل'),
      for (final r in rs)
        Builder(builder: (_) {
          final e = DB.find('exams', (x) => x['id'] == r['examId']);
          final sub = e == null ? null : DB.find('subjects', (s) => s['id'] == e['subjectId']);
          final ratio = (r['score'] as num) / (r['total'] as num);
          return Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(
                    child: Text('${e?['title'] ?? 'امتحان محذوف'}', style: const TextStyle(fontWeight: FontWeight.w800)),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                    decoration: BoxDecoration(color: kSoft, borderRadius: BorderRadius.circular(12)),
                    child: Text('${r['score']} / ${r['total']}',
                        style: const TextStyle(fontWeight: FontWeight.w800, color: kPrimary)),
                  ),
                ]),
                Text('${sub?['name'] ?? ''} • ${r['date']}', style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                      value: ratio, minHeight: 8, backgroundColor: kSoft, color: ratio >= 0.5 ? kPrimary : kRed),
                ),
              ]),
            ),
          );
        }),
    ]);
  }

  Widget account() {
    Widget row(IconData ic, String k, String v) => ListTile(
          dense: true,
          leading: Icon(ic, size: 20, color: Colors.grey.shade600),
          title: Text(k, style: TextStyle(color: Colors.grey.shade700)),
          trailing: Text(v, style: const TextStyle(fontWeight: FontWeight.w700)),
        );
    return ListView(padding: const EdgeInsets.fromLTRB(12, 4, 12, 20), children: [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(children: [
            CircleAvatar(
              radius: 38,
              backgroundColor: kSoft,
              child: Text(initials('${me['name']}'),
                  style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: kPrimary)),
            ),
            const SizedBox(height: 10),
            Text('${me['name']}', textAlign: TextAlign.center, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            tag('طالب', kPrimary),
            const SizedBox(height: 14),
            barcodeBox(),
          ]),
        ),
      ),
      Card(
        child: Column(children: [
          row(Icons.tag, 'الرقم الجامعي', sid),
          row(Icons.apartment_outlined, 'القسم', '${me['dept'] ?? ''}'),
          row(Icons.stairs_outlined, 'المرحلة', '${me['stage'] ?? ''}'),
          row(Icons.schedule, 'الدوام', '${me['shift'] ?? ''}'),
        ]),
      ),
      Card(
        child: Column(children: [
          ListTile(
            leading: const Icon(Icons.chat_bubble_outline, color: kPrimary),
            title: const Text('المحادثات'),
            trailing: unreadFor(sid) > 0 ? Badge(label: Text('${unreadFor(sid)}')) : const Icon(Icons.chevron_left),
            onTap: () => Navigator.push(
                context, MaterialPageRoute(builder: (_) => ChatListPage(me: meOf(widget.user), standalone: true))),
          ),
          ListTile(
            leading: const Icon(Icons.key_outlined, color: kPrimary),
            title: const Text('تغيير كلمة المرور'),
            trailing: const Icon(Icons.chevron_left),
            onTap: () => changePassword(context),
          ),
        ]),
      ),
      const SizedBox(height: 6),
      OutlinedButton.icon(
        style: OutlinedButton.styleFrom(foregroundColor: kRed, side: const BorderSide(color: kRed), minimumSize: const Size.fromHeight(48)),
        onPressed: () => logout(context),
        icon: const Icon(Icons.logout),
        label: const Text('تسجيل الخروج'),
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final pages = [home(), attendance(), exams(), grades(), account()];
    const titles = ['الحضور الجامعي', 'حضوري', 'الامتحانات', 'درجاتي', 'حسابي'];
    const subs = [null, 'نسبة حضورك في كل مادة', 'الامتحانات والكوزات المتاحة', 'درجات كل المواد', null];
    final chatBtn = IconButton(
      tooltip: 'المحادثات',
      icon: chatIcon(sid, Icons.chat_bubble_outline),
      onPressed: () => Navigator.push(
          context, MaterialPageRoute(builder: (_) => ChatListPage(me: meOf(widget.user), standalone: true))),
    );
    return Scaffold(
      appBar: i == 0
          ? UniHeader(
              title: titles[0],
              name: '${me['name']}',
              line: ['طالب', me['stage'], me['shift']].where((x) => '${x ?? ''}'.isNotEmpty).join(' • '),
              actions: [chatBtn])
          : UniHeader(title: titles[i], sub: subs[i], actions: [chatBtn]),
      body: pages[i],
      bottomNavigationBar: NavigationBar(
        selectedIndex: i,
        onDestinationSelected: (v) => setState(() => i = v),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home_rounded), label: 'الرئيسية'),
          NavigationDestination(icon: Icon(Icons.fact_check_outlined), selectedIcon: Icon(Icons.fact_check), label: 'حضوري'),
          NavigationDestination(icon: Icon(Icons.quiz_outlined), selectedIcon: Icon(Icons.quiz), label: 'الامتحانات'),
          NavigationDestination(icon: Icon(Icons.workspace_premium_outlined), selectedIcon: Icon(Icons.workspace_premium), label: 'درجاتي'),
          NavigationDestination(icon: Icon(Icons.person_outline), selectedIcon: Icon(Icons.person), label: 'حسابي'),
        ],
      ),
    );
  }
}

// ---------- حل امتحان ----------
class ExamTakePage extends StatefulWidget {
  final Rec exam;
  final String studentId;
  const ExamTakePage({super.key, required this.exam, required this.studentId});
  @override
  State<ExamTakePage> createState() => _ExamTakePageState();
}

class _ExamTakePageState extends Live<ExamTakePage> {
  late final List qs = widget.exam['questions'] as List;
  final answers = <int, int>{};
  late int left = ((widget.exam['duration'] as num?)?.toInt() ?? 10) * 60;
  Timer? t;
  bool done = false;

  @override
  void initState() {
    super.initState();
    t = Timer.periodic(const Duration(seconds: 1), (_) {
      if (left <= 1) {
        submit(auto: true);
      } else {
        setState(() => left--);
      }
    });
  }

  @override
  void dispose() {
    t?.cancel();
    super.dispose();
  }

  Future<void> submit({bool auto = false}) async {
    if (done) return;
    if (!auto && answers.length < qs.length) {
      if (!await confirm(context, 'باقي ${qs.length - answers.length} سؤال بدون جواب. تسلّم؟')) return;
    }
    if (done) return;
    done = true;
    t?.cancel();
    try {
      await DB.put('submissions', {
        'examId': widget.exam['id'],
        'studentId': widget.studentId,
        'answers': [for (var n = 0; n < qs.length; n++) answers[n] ?? -1],
        'date': today(),
      }, '${widget.exam['id']}_${widget.studentId}');
    } catch (e) {
      if (mounted) toast(context, 'ما انحفظ التسليم (يمكن سلّمت من قبل): $e', Colors.red);
    }
    if (!mounted) return;
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (c) => AlertDialog(
        title: Text(auto ? 'انتهى الوقت' : 'تم التسليم'),
        content: const Text('انحفظت أجوبتك ✓\nالدرجة تطلع بقسم الدرجات بعد التصحيح.', style: TextStyle(fontSize: 16)),
        actions: [FilledButton(onPressed: () => Navigator.pop(c), child: const Text('تمام'))],
      ),
    );
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final m = left ~/ 60, s = left % 60;
    return PopScope(
      canPop: false,
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: false,
          title: Text('${widget.exam['title']}'),
          actions: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Center(
                child: Text('${two(m)}:${two(s)}',
                    style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: left < 60 ? Colors.red : null)),
              ),
            ),
          ],
        ),
        body: ListView(padding: const EdgeInsets.all(12), children: [
          for (var n = 0; n < qs.length; n++)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${n + 1}. ${(qs[n] as Map)['q']}',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  for (var j = 0; j < ((qs[n] as Map)['options'] as List).length; j++)
                    ListTile(
                      dense: true,
                      leading: Icon(answers[n] == j ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                          color: answers[n] == j ? Theme.of(context).colorScheme.primary : null),
                      title: Text('${((qs[n] as Map)['options'] as List)[j]}'),
                      onTap: () => setState(() => answers[n] = j),
                    ),
                ]),
              ),
            ),
          const SizedBox(height: 80),
        ]),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: SizedBox(
              height: 52,
              child: FilledButton.icon(
                  onPressed: () => submit(),
                  icon: const Icon(Icons.send),
                  label: Text('تسليم (${answers.length}/${qs.length})')),
            ),
          ),
        ),
      ),
    );
  }
}

// ================================ المحادثات ================================
Rec meOf(Rec u) => {
      'id': '${u['studentId'] ?? u['username']}',
      'name': '${u['name']}',
      'role': '${u['role']}',
      'dept': '${u['dept'] ?? ''}',
    };

String chatKey(String a, String b) => (a.compareTo(b) < 0) ? '${a}__$b' : '${b}__$a';

int unreadFor(String myId) =>
    DB.list('messages').where((m) => m['to'] == myId && m['read'] != true).length;

/// أيقونة مع عدد الرسائل غير المقروءة
Widget chatIcon(String myId, IconData icon) {
  final n = unreadFor(myId);
  return n == 0 ? Icon(icon) : Badge(label: Text('$n'), child: Icon(icon));
}

/// منو يكدر يحجي وية منو
List<Rec> contactsFor(Rec me) {
  final out = <Rec>[];
  final seen = <String>{me['id']};
  void add(String id, String name, String info) {
    if (seen.add(id)) out.add({'id': id, 'name': name, 'info': info});
  }

  final role = me['role'], dept = me['dept'];
  for (final u in DB.list('accounts')) {
    final r = u['role'];
    final same = u['dept'] == dept;
    final ok = switch (role) {
      'president' => true,
      'head' => r == 'president' || same,
      'doctor' => r == 'president' || (same && (r == 'head' || r == 'doctor')),
      _ => r == 'president' || (same && (r == 'head' || r == 'doctor')),
    };
    if (ok) add('${u['username']}', '${u['name']}', '${roleNames[r] ?? ''} • ${u['dept'] ?? ''}');
  }
  if (role == 'president' || role == 'head') {
    for (final st in DB.list('students')) {
      if (role == 'president' || st['dept'] == dept) add('${st['id']}', '${st['name']}', 'طالب • ${DB.stuInfo(st)}');
    }
  } else if (role == 'doctor') {
    for (final sub in DB.list('subjects').where((x) => x['doctor'] == me['id'])) {
      for (final st in DB.studentsOf(sub)) {
        add('${st['id']}', '${st['name']}', 'طالب • ${DB.stuInfo(st)}');
      }
    }
  }
  return out;
}

class ChatListPage extends StatefulWidget {
  final Rec me;
  final bool standalone;
  const ChatListPage({super.key, required this.me, this.standalone = false});
  @override
  State<ChatListPage> createState() => _ChatListPageState();
}

class _ChatListPageState extends Live<ChatListPage> {
  String q = '';

  @override
  Widget build(BuildContext context) {
    final myId = '${widget.me['id']}';
    // آخر رسالة وعدد غير المقروء لكل شخص
    final last = <String, Rec>{};
    final unread = <String, int>{};
    for (final m in DB.list('messages')) {
      if (m['from'] != myId && m['to'] != myId) continue;
      final other = m['from'] == myId ? '${m['to']}' : '${m['from']}';
      final old = last[other];
      if (old == null || (m['time'] as num) > (old['time'] as num)) last[other] = m;
      if (m['to'] == myId && m['read'] != true) unread[other] = (unread[other] ?? 0) + 1;
    }
    var cs = contactsFor(widget.me);
    // ناس حجوا ويايه وما بقائمتي (مثلاً طالب راسل رئيس الجامعة)
    for (final id in last.keys) {
      if (!cs.any((c) => c['id'] == id)) {
        final m = last[id]!;
        cs.add({'id': id, 'name': m['from'] == id ? '${m['fromName']}' : '${m['toName'] ?? id}', 'info': ''});
      }
    }
    if (q.isNotEmpty) {
      cs = cs.where((c) => '${c['name']}'.contains(q) || '${c['id']}'.contains(q)).toList();
    }
    final withMsg = cs.where((c) => last.containsKey(c['id'])).toList()
      ..sort((a, b) => (last[b['id']]!['time'] as num).compareTo(last[a['id']]!['time'] as num));
    final others = cs.where((c) => !last.containsKey(c['id'])).take(q.isEmpty ? 60 : 200).toList();

    Widget tile(Rec c) {
      final m = last[c['id']];
      final n = unread[c['id']] ?? 0;
      return ListTile(
        leading: CircleAvatar(child: Text('${c['name']}'.isEmpty ? '?' : '${c['name']}'.characters.first)),
        title: Text('${c['name']}', style: TextStyle(fontWeight: n > 0 ? FontWeight.bold : null)),
        subtitle: Text(m == null ? '${c['info']}' : '${m['from'] == myId ? 'أنت: ' : ''}${m['text']}',
            maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: n > 0 ? Badge(label: Text('$n')) : null,
        onTap: () => Navigator.push(context,
            MaterialPageRoute(builder: (_) => ChatPage(me: widget.me, other: c))),
      );
    }

    final body = Column(children: [
      Padding(
        padding: const EdgeInsets.all(8),
        child: TextField(
          decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search), hintText: 'ابحث عن شخص', border: OutlineInputBorder()),
          onChanged: (v) => setState(() => q = v.trim()),
        ),
      ),
      Expanded(
        child: ListView(children: [
          if (withMsg.isNotEmpty) const Padding(padding: EdgeInsets.all(8), child: Text('المحادثات', style: TextStyle(fontWeight: FontWeight.bold))),
          for (final c in withMsg) tile(c),
          if (others.isNotEmpty) const Padding(padding: EdgeInsets.all(8), child: Text('ابدأ محادثة جديدة', style: TextStyle(fontWeight: FontWeight.bold))),
          for (final c in others) tile(c),
          if (withMsg.isEmpty && others.isEmpty) empty('ماكو نتائج'),
        ]),
      ),
    ]);
    return widget.standalone
        ? Scaffold(appBar: AppBar(title: const Text('المحادثات')), body: body)
        : body;
  }
}

class ChatPage extends StatefulWidget {
  final Rec me, other;
  const ChatPage({super.key, required this.me, required this.other});
  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends Live<ChatPage> {
  final input = TextEditingController();
  final marking = <String>{};

  String get myId => '${widget.me['id']}';
  String get otherId => '${widget.other['id']}';

  Future<void> send() async {
    final t = input.text.trim();
    if (t.isEmpty) return;
    input.clear();
    await DB.put('messages', {
      'chat': chatKey(myId, otherId),
      'from': myId,
      'to': otherId,
      'fromName': widget.me['name'],
      'toName': widget.other['name'],
      'text': t,
      'time': DateTime.now().millisecondsSinceEpoch,
      'read': false,
    });
  }

  @override
  Widget build(BuildContext context) {
    final key = chatKey(myId, otherId);
    final msgs = DB.list('messages').where((m) => m['chat'] == key).toList()
      ..sort((a, b) => (b['time'] as num).compareTo(a['time'] as num));
    // علم الرسائل الجديدة كمقروءة
    final toMark = msgs.where((m) => m['to'] == myId && m['read'] != true && !marking.contains(m['_id'])).toList();
    if (toMark.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        for (final m in toMark) {
          marking.add('${m['_id']}');
          DB.put('messages', {...m, 'read': true});
        }
      });
    }
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text('${widget.other['name']}')),
      body: Column(children: [
        Expanded(
          child: msgs.isEmpty
              ? empty('ابدأ المحادثة 👋')
              : ListView.builder(
                  reverse: true,
                  padding: const EdgeInsets.all(8),
                  itemCount: msgs.length,
                  itemBuilder: (_, i) {
                    final m = msgs[i];
                    final mine = m['from'] == myId;
                    final t = DateTime.fromMillisecondsSinceEpoch((m['time'] as num).toInt());
                    return Align(
                      alignment: mine ? AlignmentDirectional.centerStart : AlignmentDirectional.centerEnd,
                      child: Container(
                        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
                        margin: const EdgeInsets.symmetric(vertical: 3),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: mine ? cs.primary : cs.secondaryContainer,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('${m['text']}', style: TextStyle(color: mine ? cs.onPrimary : null, fontSize: 15)),
                          const SizedBox(height: 2),
                          Text('${two(t.hour)}:${two(t.minute)}${mine && m['read'] == true ? ' ✓✓' : ''}',
                              style: TextStyle(fontSize: 10, color: mine ? Colors.white70 : Colors.grey)),
                        ]),
                      ),
                    );
                  },
                ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: input,
                  minLines: 1,
                  maxLines: 4,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => send(),
                  decoration: const InputDecoration(hintText: 'اكتب رسالة...', border: OutlineInputBorder()),
                ),
              ),
              const SizedBox(width: 6),
              IconButton.filled(onPressed: send, icon: const Icon(Icons.send)),
            ]),
          ),
        ),
      ]),
    );
  }
}
