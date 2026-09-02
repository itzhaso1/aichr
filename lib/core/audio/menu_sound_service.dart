import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _prefsKey = 'hasim_cashier_menu_sound_enabled';

final menuSoundServiceProvider = Provider<MenuSoundService>((ref) {
  return MenuSoundService();
});

/// Plays the Menu Order chime when enabled in settings.
class MenuSoundService {
  MenuSoundService() {
    _load();
  }

  final AudioPlayer _player = AudioPlayer();
  bool _enabled = true;
  bool _ready = false;

  bool get enabled => _enabled;

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool(_prefsKey) ?? true;
    _ready = true;
  }

  Future<void> setEnabled(bool value) async {
    _enabled = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsKey, value);
  }

  Future<void> playNewOrder() async {
    if (!_ready) await _load();
    if (!_enabled) return;
    try {
      await _player.stop();
      await _player.play(AssetSource('sounds/menu_order.wav'));
    } catch (_) {
      // Fallback when asset/player unavailable (e.g. tests).
      await SystemSound.play(SystemSoundType.alert);
    }
  }
}
