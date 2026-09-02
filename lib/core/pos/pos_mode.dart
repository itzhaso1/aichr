import '../config/app_config.dart';

/// Operating mode. Core POS never requires Connected.
enum PosOperatingMode { standalone, connected }

class PosMode {
  const PosMode._();

  /// Reserved SQLite scope for a standalone store. Never a Laravel workspace.
  ///
  /// The real store identity is [LocalStores.localId] (UUID). This integer is
  /// only a local partition so a later Connect to Laravel workspace `1`
  /// does not collide with standalone rows.
  static const standaloneWorkspaceId = 900001;

  /// Pre-audit standalone installs used Laravel-looking workspace `1`.
  static const legacyCollidingWorkspaceId = 1;

  static bool isReservedStandaloneWorkspace(int workspaceId) =>
      workspaceId == standaloneWorkspaceId;

  static bool isStandaloneToken(String? token) =>
      token != null &&
      (token.startsWith('standalone:') || token == 'local-offline');

  /// When [AppConfig.offlineOnly] is true the entire runtime is standalone —
  /// no feature may take an API / sync path.
  static bool isStandaloneRuntime({
    required bool isLocalMode,
    String? token,
  }) =>
      AppConfig.offlineOnly || isLocalMode || isStandaloneToken(token);

  /// Standalone tokens never become a live session without a fresh PIN.
  /// In offline-only builds, never admit a remote Laravel token either.
  static bool admitRestoredSession(String? token) {
    if (AppConfig.offlineOnly) return false;
    return token != null && token.isNotEmpty && !isStandaloneToken(token);
  }
}
