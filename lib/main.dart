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
        theme: ThemeData(
            useMaterial3: true, colorSchemeSeed: const Color(0xFF1E3A8A)),
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

class StatCard extends StatelessWidget {
  final String title, value;
  final IconData icon;
  const StatCard(this.title, this.value, this.icon, {super.key});
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      color: cs.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: cs.primary),
            const SizedBox(height: 6),
            Text(value,
                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
            Text(title, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }
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
    } on FirebaseAuthException catch (_) {
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
          toast(context, 'اسم المستخدم أو كلمة المرور غلط', Colors.red);
        }
        return;
      }
    }
    await _enter(pw);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(children: [
                Icon(Icons.school, size: 80, color: cs.primary),
                const SizedBox(height: 8),
                const Text('نظام الجامعة',
                    style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
                const Text('الحضور بالباركود • الامتحانات • الكوزات'),
                const SizedBox(height: 28),
                TextField(
                  controller: u,
                  decoration: const InputDecoration(
                      labelText: 'اسم المستخدم / الرقم الجامعي',
                      prefixIcon: Icon(Icons.person),
                      border: OutlineInputBorder()),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: p,
                  obscureText: hide,
                  onSubmitted: (_) => login(),
                  decoration: InputDecoration(
                      labelText: 'كلمة المرور',
                      prefixIcon: const Icon(Icons.lock),
                      suffixIcon: IconButton(
                          icon: Icon(hide ? Icons.visibility : Icons.visibility_off),
                          onPressed: () => setState(() => hide = !hide)),
                      border: const OutlineInputBorder()),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: FilledButton(
                      onPressed: busy ? null : login,
                      child: busy
                          ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Text('دخول')),
                ),
                const SizedBox(height: 12),
                const Text('الطالب: أول مرة يدخل برقمه الجامعي بالخانتين، وبعدها يختار رمز جديد',
                    textAlign: TextAlign.center, style: TextStyle(color: Colors.grey, fontSize: 12)),
              ]),
            ),
          ),
        ),
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
                  subtitle: Text('${roleNames[u['role']]} • ${u['username']} • ${u['dept']}'),
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
    final cards = [
      StatCard('الأقسام', '${depts.length}', Icons.apartment),
      StatCard('الطلاب', '${DB.list('students').length}', Icons.groups),
      StatCard('الدكاترة', '${DB.list('accounts').where((u) => u['role'] == 'doctor').length}', Icons.person),
      StatCard('المواد', '${DB.list('subjects').length}', Icons.menu_book),
      StatCard('نسبة الحضور', pct(DB.attRate()), Icons.how_to_reg),
      StatCard('امتحانات وكوزات', '${DB.list('exams').length}', Icons.quiz),
      StatCard('معدل الدرجات', pct(DB.avgScore()), Icons.grade),
    ];
    return ListView(padding: const EdgeInsets.all(8), children: [
      GridView.count(
        crossAxisCount: 3,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        childAspectRatio: 0.95,
        children: cards,
      ),
      const Padding(
        padding: EdgeInsets.all(8),
        child: Text('الأقسام', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
      ),
      for (final dp in depts)
        Card(
          child: ListTile(
            leading: const Icon(Icons.apartment),
            title: Text(dp),
            subtitle: Text(
                'طلاب: ${DB.list('students').where((s) => s['dept'] == dp).length} • '
                'مواد: ${DB.subjectsOfDept(dp).length} • '
                'حضور: ${pct(DB.attRate(dept: dp))} • '
                'معدل: ${pct(DB.avgScore(dept: dp))}'),
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
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.user['name']}'),
        actions: [
          logoutBtn(context),
        ],
      ),
      body: pages[i],
      bottomNavigationBar: NavigationBar(
        selectedIndex: i,
        onDestinationSelected: (v) => setState(() => i = v),
        destinations: [
          const NavigationDestination(icon: Icon(Icons.dashboard), label: 'الرئيسية'),
          const NavigationDestination(icon: Icon(Icons.bar_chart), label: 'التقارير'),
          const NavigationDestination(icon: Icon(Icons.manage_accounts), label: 'المستخدمين'),
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
    final pages = [
      SubjectsManage(dept: dept),
      StudentsManage(dept: dept),
      UsersManage(roles: const ['doctor'], dept: dept),
      ReportView(dept: dept),
      ChatListPage(me: meOf(widget.user)),
    ];
    return Scaffold(
      appBar: AppBar(title: Text('رئيس القسم • $dept'), actions: [logoutBtn(context)]),
      body: pages[i],
      bottomNavigationBar: NavigationBar(
        selectedIndex: i,
        onDestinationSelected: (v) => setState(() => i = v),
        destinations: [
          const NavigationDestination(icon: Icon(Icons.menu_book), label: 'المواد'),
          const NavigationDestination(icon: Icon(Icons.groups), label: 'الطلاب'),
          const NavigationDestination(icon: Icon(Icons.person), label: 'الدكاترة'),
          const NavigationDestination(icon: Icon(Icons.bar_chart), label: 'التقارير'),
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
    return Scaffold(
      appBar: AppBar(title: Text('${widget.user['name']}'), actions: [
        IconButton(
          tooltip: 'المحادثات',
          icon: chatIcon('${widget.user['username']}', Icons.chat),
          onPressed: () => Navigator.push(context,
              MaterialPageRoute(builder: (_) => ChatListPage(me: meOf(widget.user), standalone: true))),
        ),
        logoutBtn(context),
      ]),
      body: subs.isEmpty
          ? empty('ماكو مواد مسندة إلك')
          : ListView(padding: const EdgeInsets.all(8), children: [
              for (final s in subs)
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.menu_book, size: 32),
                    title: Text('${s['name']}', style: const TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Text('${DB.subInfo(s)}\nطلاب: ${DB.studentsOf(s).length} • محاضرات: ${DB.lectures(s['id'])} • حضور: ${pct(DB.attRate(subjectId: s['id']))}'),
                    trailing: const Icon(Icons.chevron_left),
                    onTap: () async {
                      await Navigator.push(context, MaterialPageRoute(builder: (_) => SubjectPage(subject: s)));
                      setState(() {});
                    },
                  ),
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
    return Scaffold(
      appBar: AppBar(title: Text('${s['name']}')),
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
        const SizedBox(height: 16),
        const Text('الامتحانات والكوزات', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        if (exams.isEmpty) empty('ماكو امتحانات بعد'),
        for (final e in exams)
          Card(
            child: ListTile(
              leading: Icon(e['type'] == 'quiz' ? Icons.bolt : Icons.assignment),
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

  Widget card() {
    final ascii = RegExp(r'^[\x20-\x7E]+$').hasMatch(sid);
    return ListView(padding: const EdgeInsets.all(16), children: [
      Card(
        elevation: 3,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(children: [
            const Icon(Icons.school, size: 48),
            Text('${me['name']}', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
            Text('${me['dept']}'),
            Text([me['stage'], me['shift']].where((x) => '${x ?? ''}'.isNotEmpty).join(' • ')),
            const SizedBox(height: 20),
            Container(
              color: Colors.white,
              padding: const EdgeInsets.all(12),
              child: BarcodeWidget(
                barcode: ascii ? Barcode.code128() : Barcode.qrCode(),
                data: sid,
                width: 280,
                height: ascii ? 110 : 200,
                drawText: true,
              ),
            ),
            const SizedBox(height: 12),
            const Text('اعرض هذا الباركود للدكتور حتى يسجل حضورك',
                textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)),
          ]),
        ),
      ),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(child: StatCard('نسبة حضوري', pct(DB.attRate(studentId: sid)), Icons.how_to_reg)),
        Expanded(
            child: StatCard('امتحانات سلّمتها',
                '${DB.list('submissions').where((r) => r['studentId'] == sid).length}', Icons.quiz)),
      ]),
    ]);
  }

  Widget attendance() {
    final subs = mySubjects;
    if (subs.isEmpty) return empty('ماكو مواد');
    return ListView(padding: const EdgeInsets.all(8), children: [
      for (final s in subs)
        Builder(builder: (_) {
          final recs = DB.list('attendance').where((a) => a['subjectId'] == s['id'] && a['studentId'] == sid).toList();
          final abs = recs.where((a) => a['present'] != true).map((a) => '${a['date']}').toList();
          final r = DB.attRate(studentId: sid, subjectId: s['id']);
          final low = recs.isNotEmpty && r < 0.75;
          return Card(
            child: ExpansionTile(
              title: Text('${s['name']}'),
              subtitle: LinearProgressIndicator(
                  value: recs.isEmpty ? 0 : r, color: low ? Colors.red : Colors.green, minHeight: 6),
              trailing: Text(recs.isEmpty ? '-' : pct(r),
                  style: TextStyle(fontWeight: FontWeight.bold, color: low ? Colors.red : Colors.green)),
              children: [
                ListTile(dense: true, title: Text('حضور ${recs.length - abs.length} • غياب ${abs.length}')),
                if (low) const ListTile(dense: true, leading: Icon(Icons.warning, color: Colors.red), title: Text('تحذير: حضورك أقل من 75%')),
                for (final d in abs) ListTile(dense: true, leading: const Icon(Icons.close, color: Colors.red), title: Text('غائب: $d')),
              ],
            ),
          );
        }),
    ]);
  }

  Widget exams() {
    final ids = mySubjects.map((s) => s['id']).toSet();
    final ex = DB.list('exams').where((e) => ids.contains(e['subjectId'])).toList().reversed.toList();
    if (ex.isEmpty) return empty('ماكو امتحانات أو كوزات حالياً');
    return ListView(padding: const EdgeInsets.all(8), children: [
      for (final e in ex)
        Builder(builder: (_) {
          final res = DB.find('submissions', (r) => r['examId'] == e['id'] && r['studentId'] == sid);
          final sub = DB.find('subjects', (s) => s['id'] == e['subjectId']);
          return Card(
            child: ListTile(
              leading: Icon(e['type'] == 'quiz' ? Icons.bolt : Icons.assignment,
                  color: res == null ? Colors.orange : Colors.green),
              title: Text('${e['title']}'),
              subtitle: Text('${sub?['name'] ?? ''} • ${e['type'] == 'quiz' ? 'كوز' : 'امتحان'} • ${e['duration']} دقيقة'),
              trailing: res == null
                  ? FilledButton(
                      onPressed: () async {
                        if (!await confirm(context, 'تبدي ${e['title']}؟ عندك ${e['duration']} دقيقة وما تكدر تطلع قبل التسليم')) return;
                        if (!mounted) return;
                        await Navigator.push(context, MaterialPageRoute(builder: (_) => ExamTakePage(exam: e, studentId: sid)));
                        setState(() {});
                      },
                      child: const Text('ابدأ'))
                  : Text(res['score'] == null ? 'بانتظار التصحيح' : '${res['score']}/${res['total']}',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: res['score'] == null ? 12 : 16)),
            ),
          );
        }),
    ]);
  }

  Widget grades() {
    final rs = DB.list('submissions').where((r) => r['studentId'] == sid && r['score'] != null && (r['total'] as num? ?? 0) > 0).toList().reversed.toList();
    if (rs.isEmpty) return empty('ماكو درجات بعد');
    return ListView(padding: const EdgeInsets.all(8), children: [
      Card(child: ListTile(title: Text('معدلي: ${pct(rs.map((r) => (r['score'] as num) / (r['total'] as num)).reduce((a, b) => a + b) / rs.length)}'))),
      for (final r in rs)
        Builder(builder: (_) {
          final e = DB.find('exams', (x) => x['id'] == r['examId']);
          final sub = e == null ? null : DB.find('subjects', (s) => s['id'] == e['subjectId']);
          final ratio = (r['score'] as num) / (r['total'] as num);
          return ListTile(
            leading: Icon(ratio >= 0.5 ? Icons.check_circle : Icons.cancel, color: ratio >= 0.5 ? Colors.green : Colors.red),
            title: Text('${e?['title'] ?? 'امتحان محذوف'}'),
            subtitle: Text('${sub?['name'] ?? ''} • ${r['date']}'),
            trailing: Text('${r['score']} / ${r['total']}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          );
        }),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final pages = [card(), attendance(), exams(), grades(), ChatListPage(me: meOf(widget.user))];
    return Scaffold(
      appBar: AppBar(title: Text('${me['name']}'), actions: [logoutBtn(context)]),
      body: pages[i],
      bottomNavigationBar: NavigationBar(
        selectedIndex: i,
        onDestinationSelected: (v) => setState(() => i = v),
        destinations: [
          const NavigationDestination(icon: Icon(Icons.qr_code_2), label: 'بطاقتي'),
          const NavigationDestination(icon: Icon(Icons.how_to_reg), label: 'الحضور'),
          const NavigationDestination(icon: Icon(Icons.quiz), label: 'الامتحانات'),
          const NavigationDestination(icon: Icon(Icons.grade), label: 'الدرجات'),
          NavigationDestination(icon: chatIcon(sid, Icons.chat), label: 'المحادثات'),
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
