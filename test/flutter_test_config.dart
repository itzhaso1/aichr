import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:sqlite3/open.dart';

/// Ensures Drift native tests can open SQLite on Linux CI/agents.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  if (Platform.isLinux) {
    open.overrideFor(OperatingSystem.linux, () {
      for (final path in const [
        'libsqlite3.so',
        '/usr/lib/x86_64-linux-gnu/libsqlite3.so',
        '/usr/lib/libsqlite3.so',
      ]) {
        try {
          return DynamicLibrary.open(path);
        } catch (_) {}
      }
      return DynamicLibrary.open('libsqlite3.so');
    });
  }
  await testMain();
}
