import 'dart:convert';
import 'dart:io';

/// Locates `testdata/processing/<name>` from either `app/` (flutter test) or
/// the repository root.
File fixtureFile(String name) {
  for (final String base in <String>[
    '../testdata/processing',
    'testdata/processing',
    '../../testdata/processing',
  ]) {
    final File f = File('$base/$name');
    if (f.existsSync()) return f;
  }
  throw StateError('fixture $name not found from ${Directory.current.path}');
}

Map<String, dynamic> loadFixture(String name) =>
    jsonDecode(fixtureFile(name).readAsStringSync()) as Map<String, dynamic>;

/// Documented tolerances (PROCESSING_ON_DEVICE.md section 3).
const double kDistTolM = 1e-6; // metres, trig libm differences
const double kSpeedTol = 1e-9; // m/s
const double kCoordTol = 1e-9; // degrees

/// Recursively compares JSON-like values: numbers within [tol] (absolute, or
/// relative 1e-9), everything else exactly. Returns a list of differences.
void diffJson(Object? exp, Object? got, String path, List<String> out, {double tol = 1e-6}) {
  if (exp is Map && got is Map) {
    for (final Object? k in exp.keys) {
      if (!got.containsKey(k)) {
        out.add('$path.$k missing');
        continue;
      }
      diffJson(exp[k], got[k], '$path.$k', out, tol: tol);
    }
    for (final Object? k in got.keys) {
      if (!exp.containsKey(k)) out.add('$path.$k unexpected (${got[k]})');
    }
  } else if (exp is List && got is List) {
    if (exp.length != got.length) {
      out.add('$path length ${got.length}, want ${exp.length}');
      return;
    }
    for (int i = 0; i < exp.length; i++) {
      diffJson(exp[i], got[i], '$path[$i]', out, tol: tol);
    }
  } else if (exp is num && got is num) {
    final double a = exp.toDouble(), b = got.toDouble();
    final double allowed = tol + 1e-9 * a.abs();
    if ((a - b).abs() > allowed) out.add('$path = $b, want $a');
  } else if (exp != got) {
    out.add('$path = $got, want $exp');
  }
}
