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

  static bool isStandaloneRuntime({
    required bool isLocalMode,
    String? token,
  }) =>
      isLocalMode || isStandaloneToken(token);

  /// Standalone tokens never become a live session without a fresh PIN.
  static bool admitRestoredSession(String? token) =>
      token != null && token.isNotEmpty && !isStandaloneToken(token);
}
