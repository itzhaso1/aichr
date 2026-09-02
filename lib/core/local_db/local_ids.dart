/// Workspace-scoped local primary keys for catalog / tables / customers.
/// Prevents cross-tenant collisions when the same server id exists in two workspaces.
class LocalIds {
  const LocalIds._();

  static String category(int workspaceId, int serverId) =>
      'w${workspaceId}_cat_$serverId';

  static String product(int workspaceId, int serverId) =>
      'w${workspaceId}_prod_$serverId';

  static String table(int workspaceId, int serverId) =>
      'w${workspaceId}_table_$serverId';

  static String customer(int workspaceId, int serverId) =>
      'w${workspaceId}_cust_$serverId';

  static bool looksScoped(String localId) =>
      RegExp(r'^w\d+_(cat|prod|table|cust)_').hasMatch(localId);
}
