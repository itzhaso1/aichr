import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'link_policy.dart';

class CashierLinkState {
  const CashierLinkState({
    this.link = CashierLink.online,
    this.deviceOnline = true,
  });

  final CashierLink link;
  final bool deviceOnline;

  bool get isOnline => link == CashierLink.online;
  bool get pausePolling => LinkPolicy.shouldPausePolling(link);
  bool get allowMutations => LinkPolicy.allowServerMutation(link);
}

class CashierLinkController extends StateNotifier<CashierLinkState> {
  CashierLinkController() : super(const CashierLinkState());

  void setDeviceOnline(bool online) {
    if (!online) {
      if (!state.deviceOnline && state.link == CashierLink.offline) return;
      state = const CashierLinkState(
        link: CashierLink.offline,
        deviceOnline: false,
      );
      return;
    }
    if (state.deviceOnline) return;
    // Device recovered — wait for an API success before claiming online.
    state = const CashierLinkState(
      link: CashierLink.serverUnavailable,
      deviceOnline: true,
    );
  }

  void onApiSuccess() {
    if (state.link == CashierLink.online && state.deviceOnline) return;
    state = CashierLinkState(
      link: state.deviceOnline ? CashierLink.online : CashierLink.offline,
      deviceOnline: state.deviceOnline,
    );
  }

  void onApiFailure({int? statusCode}) {
    final next = LinkPolicy.afterApi(
      deviceOnline: state.deviceOnline,
      statusCode: statusCode,
      success: false,
    );
    if (next == state.link) return;
    state = CashierLinkState(link: next, deviceOnline: state.deviceOnline);
  }
}

final cashierLinkProvider =
    StateNotifierProvider<CashierLinkController, CashierLinkState>((ref) {
  return CashierLinkController();
});
