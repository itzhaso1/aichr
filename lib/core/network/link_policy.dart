/// Central cashier connectivity policy.
///
/// Device network and Laravel reachability are different:
/// Wi-Fi up + API down = [CashierLink.serverUnavailable], not logout.
library;

enum CashierLink {
  online,
  offline,
  serverUnavailable,
}

class LinkPolicy {
  const LinkPolicy._();

  static bool shouldLogout(int? statusCode) => statusCode == 401;

  static bool isNetworkFailure(int? statusCode) =>
      statusCode == 0 || statusCode == null;

  static bool isServerFailure(int? statusCode) =>
      statusCode != null && statusCode >= 500;

  /// Transient unavailability — keep session, pause polling, no fake success.
  static bool isUnavailable(int? statusCode) =>
      isNetworkFailure(statusCode) || isServerFailure(statusCode);

  static bool shouldPausePolling(CashierLink link) =>
      link != CashierLink.online;

  static bool allowServerMutation(CashierLink link) =>
      link == CashierLink.online;

  static CashierLink fromDevice({required bool deviceOnline}) =>
      deviceOnline ? CashierLink.online : CashierLink.offline;

  static CashierLink afterApi({
    required bool deviceOnline,
    required int? statusCode,
    required bool success,
  }) {
    if (!deviceOnline) return CashierLink.offline;
    if (success) return CashierLink.online;
    if (statusCode == 401 || statusCode == 403) {
      // Auth/permission — not a connectivity problem.
      return CashierLink.online;
    }
    if (isUnavailable(statusCode)) return CashierLink.serverUnavailable;
    return CashierLink.online;
  }

  static String bannerMessage(CashierLink link, {int pendingCount = 0}) {
    return switch (link) {
      CashierLink.offline =>
        'وضع أوفلاين — الكاشير يعمل محليًا والمزامنة عند عودة الإنترنت.',
      CashierLink.serverUnavailable =>
        'الخادم غير متاح — العرض والحفظ المحلي مستمران، أعد المحاولة للمزامنة.',
      CashierLink.online => pendingCount > 0
          ? '$pendingCount عمليات بانتظار المزامنة'
          : 'تم الاتصال بالخادم',
    };
  }
}
