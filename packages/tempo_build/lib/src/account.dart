import 'dart:io';
import 'package:path/path.dart' as p;
import 'context.dart';
import 'process.dart';

/// The account's name and ids, as the templates want them.
final class Account {
  const Account({
    required this.user,
    required this.uid,
    required this.gid,
    required this.passwordlessSudo,
  });
  factory Account.fromConfig(BuildConfig config) => Account(
    user: config.string('user.name'),
    uid: config.string('user.uid'),
    gid: config.string('user.gid'),
    passwordlessSudo:
        config.get('user.sudoer') == true &&
        config.get('user.passwordless_sudo') == true,
  );
  final String user, uid, gid;
  final bool passwordlessSudo;
}

/// The templates under platform/rootfs/account, relative to the image root.
const accountTemplates = 'platform/rootfs/account';
const accountSudoers = 'etc/sudoers.d/10-tempo';

/// Whether [user] can be a Unix account name here: the same rule the device
/// applies at first run, so what one accepts the other accepts.
bool validAccountName(String user) =>
    RegExp(r'^[a-z_][a-z0-9_-]{0,31}$').hasMatch(user) && user != 'root';

/// Every file in the image that names the account, rendered from the
/// templates: relative image path to contents. The sudoers file is only
/// among them when the account has passwordless sudo.
Map<String, String> renderAccountFiles(Repository repo, Account account) {
  if (!validAccountName(account.user)) {
    throw BuildFailure('Invalid account name: ${account.user}');
  }
  final root = repo.path(accountTemplates);
  final rendered = <String, String>{};
  for (final entry in Directory(root).listSync(recursive: true)) {
    if (entry is! File || p.basename(entry.path) == 'README.md') continue;
    final relative = p.relative(entry.path, from: root);
    if (relative == accountSudoers && !account.passwordlessSudo) continue;
    rendered[relative] = renderAccountTemplate(
      entry.readAsStringSync(),
      account,
    );
  }
  return rendered;
}

String renderAccountTemplate(String template, Account account) => template
    .replaceAll('@USER@', account.user)
    .replaceAll('@UID@', account.uid)
    .replaceAll('@GID@', account.gid);
