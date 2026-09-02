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
        child: child ?? const SizedBox.shrink(),
      ),
      routerConfig: router,
    );
  }
}
