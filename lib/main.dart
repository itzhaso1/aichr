import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'core/config/app_config.dart';
import 'core/offline/offline_store.dart';
import 'core/theme/hasim_theme.dart';
import 'router/app_router.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final previousOnError = FlutterError.onError;
  FlutterError.onError = (details) {
    final message = details.exceptionAsString();
    // Debug-only framework races while the POS rebuilds under a desktop
    // mouse cursor. They are noisy and non-fatal; ignore them.
    if (message.contains('Cannot hit test a render box with no size') ||
        message.contains('_debugDuringDeviceUpdate')) {
      return;
    }
    previousOnError?.call(details);
  };

  ErrorWidget.builder = (details) {
    return Material(
      color: Colors.white,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 40, color: Colors.red),
              const SizedBox(height: 12),
              const Text(
                'تعذر عرض هذه الشاشة',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              Text(
                details.exceptionAsString(),
                textAlign: TextAlign.center,
                maxLines: 8,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: Colors.black54),
              ),
            ],
          ),
        ),
      ),
    );
  };
  await Hive.initFlutter();
  await OfflineStore.instance.init();
  runApp(const ProviderScope(child: HasimCashierApp()));
}

class HasimCashierApp extends ConsumerWidget {
  const HasimCashierApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(appRouterProvider);
    return MaterialApp.router(
      title: AppConfig.appName,
      debugShowCheckedModeBanner: false,
      theme: HasimTheme.light(),
      locale: const Locale('ar'),
      supportedLocales: const [Locale('ar'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      // POS terminal: skip the accessibility tree. Flutter 3.35 debug builds
      // can cascade `!semantics.parentDataDirty` around modal/dropdown routes.
      builder: (context, child) => ExcludeSemantics(
        child: child ?? const SizedBox.expand(),
      ),
      routerConfig: router,
    );
  }
}
