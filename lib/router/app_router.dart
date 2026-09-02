import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/auth/auth_controller.dart';
import '../core/theme/hasim_colors.dart';
import '../core/theme/hasim_theme.dart';
import '../features/auth/forgot_password_screen.dart';
import '../features/auth/login_screen.dart';
import '../features/auth/pin_login_screen.dart';
import '../features/auth/pos_blocked_screen.dart';
import '../features/auth/standalone_setup_screen.dart';
import '../features/auth/workspace_picker_screen.dart';
import '../features/home/shell_screen.dart';

/// GoRouter must NOT be rebuilt on every auth state change.
/// Watching auth inside this provider remounted ShellScreen → re-hit
/// /bootstrap in a loop until Laravel returned 429 Too Many Attempts.
final appRouterProvider = Provider<GoRouter>((ref) {
  final refresh = _AuthRefresh(ref);

  return GoRouter(
    initialLocation: '/splash',
    refreshListenable: refresh,
    redirect: (context, state) {
      final auth = ref.read(authControllerProvider);
      final loggingIn = state.matchedLocation == '/login';
      final picking = state.matchedLocation == '/workspaces';
      final splash = state.matchedLocation == '/splash';
      final forgot = state.matchedLocation == '/forgot-password';
      final reset = state.matchedLocation == '/reset-password';
      final pin = state.matchedLocation == '/pin';
      final setup = state.matchedLocation == '/standalone-setup';

      if (auth.isLoading) {
        return splash ? null : '/splash';
      }

      final session = auth.valueOrNull;
      if (session == null) {
        if (loggingIn || forgot || reset || pin || setup) return null;
        return '/login';
      }

      final needsPick =
          session.workspace == null && session.workspaces.length > 1;
      if (needsPick) {
        return picking ? null : '/workspaces';
      }

      if (loggingIn || splash || picking || forgot || reset || pin || setup) {
        return '/home';
      }
      return null;
    },
    routes: [
      GoRoute(path: '/splash', builder: (_, __) => const _Splash()),
      GoRoute(path: '/login', builder: (_, __) => const LoginScreen()),
      GoRoute(path: '/pin', builder: (_, __) => const PinLoginScreen()),
      GoRoute(
        path: '/standalone-setup',
        builder: (_, __) => const StandaloneSetupScreen(),
      ),
      GoRoute(
        path: '/forgot-password',
        builder: (_, __) => const ForgotPasswordScreen(),
      ),
      GoRoute(
        path: '/reset-password',
        builder: (context, state) {
          final email = state.extra is String ? state.extra as String : '';
          return ResetPasswordScreen(initialEmail: email);
        },
      ),
      GoRoute(
        path: '/workspaces',
        builder: (_, __) => const WorkspacePickerScreen(),
      ),
      GoRoute(
        path: '/pos-blocked',
        builder: (_, __) => const PosBlockedScreen(),
      ),
      GoRoute(path: '/home', builder: (_, __) => const ShellScreen()),
    ],
  );
});

class _AuthRefresh extends ChangeNotifier {
  _AuthRefresh(this.ref) {
    ref.listen(authControllerProvider, (_, __) => notifyListeners());
  }

  final Ref ref;
}

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [HasimColors.brandSoft, Colors.white],
          ),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 88,
                height: 88,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: HasimColors.border),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x1406C2A4),
                      blurRadius: 24,
                      offset: Offset(0, 8),
                    ),
                  ],
                ),
                child: const Text(
                  'ح',
                  style: TextStyle(
                    fontSize: 42,
                    fontWeight: FontWeight.w900,
                    color: HasimColors.brand,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'كاشير حاسم',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w900,
                  color: HasimColors.ink,
                ),
              ),
              const SizedBox(height: 18),
              const SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: HasimColors.brand,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Expose theme helper for MaterialApp.
ThemeData hasimCashierTheme() => HasimTheme.light();
