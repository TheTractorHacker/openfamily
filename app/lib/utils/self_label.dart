/// How the signed-in person is shown in lists and cards: their real name with a small
/// "(you)" tag, never a bare "You". Only when the name is truly unknown is it just "You".
String selfLabel(String? name) {
  final String n = (name ?? '').trim();
  if (n.isEmpty || n == 'Member' || n == 'Someone') return 'You';
  return '$n (you)';
}

/// A display name for someone with no profile name: the part of the email before the "@".
String nameOrEmail(String? name, String? email, {String fallback = 'Member'}) {
  final String n = (name ?? '').trim();
  if (n.isNotEmpty) return n;
  final String e = (email ?? '').trim();
  final int at = e.indexOf('@');
  final String local = at > 0 ? e.substring(0, at) : '';
  return local.isNotEmpty ? local : fallback;
}
