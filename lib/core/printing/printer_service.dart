import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../util/json_numbers.dart';

/// Connection transports supported by the cashier print architecture.
enum PrinterTransport { bluetooth, usb, network, system }

enum PrinterReadyState { notConfigured, configuredDisconnected, ready }

class PrinterProfile {
  const PrinterProfile({
    required this.id,
    required this.name,
    required this.transport,
    this.address,
    this.paperChars = 32,
  });

  final String id;
  final String name;
  final PrinterTransport transport;
  final String? address;
  final int paperChars;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'transport': transport.name,
    'address': address,
    'paper_chars': paperChars,
  };

  factory PrinterProfile.fromJson(Map<String, dynamic> json) => PrinterProfile(
    id: json['id'] as String? ?? 'default',
    name: json['name'] as String? ?? 'طابعة',
    transport: PrinterTransport.values.firstWhere(
      (e) => e.name == json['transport'],
      orElse: () => PrinterTransport.network,
    ),
    address: json['address'] as String?,
    paperChars: asIntOr(json['paper_chars'], 32),
  );
}

class PrintJobResult {
  const PrintJobResult.ok() : success = true, message = 'تمت الطباعة.';
  const PrintJobResult.fail(this.message) : success = false;

  final bool success;
  final String message;
}

/// Builds ESC/POS byte payloads for thermal receipts (does not send them).
class EscPosReceiptBuilder {
  EscPosReceiptBuilder({this.charsPerLine = 32});

  final int charsPerLine;

  static final List<int> _init = [0x1B, 0x40];
  static final List<int> _cut = [0x1D, 0x56, 0x00];
  static final List<int> _alignCenter = [0x1B, 0x61, 0x01];
  static final List<int> _alignLeft = [0x1B, 0x61, 0x00];
  static final List<int> _boldOn = [0x1B, 0x45, 0x01];
  static final List<int> _boldOff = [0x1B, 0x45, 0x00];

  Uint8List buildInvoice(Map<String, dynamic> invoice) {
    final out = BytesBuilder();
    out.add(_init);
    out.add(_alignCenter);
    out.add(_boldOn);
    out.add(_line(invoice['store_name'] as String? ?? 'كاشير حاسم'));
    out.add(_boldOff);
    out.add(_line(invoice['invoice_number'] as String? ?? ''));
    out.add(_line(invoice['closed_at'] as String? ?? ''));
    out.add(_alignLeft);
    out.add(_line('-' * charsPerLine));
    final items = invoice['items'];
    if (items is List) {
      for (final raw in items.whereType<Map>()) {
        final name = '${raw['item_name'] ?? raw['product_name'] ?? 'صنف'}';
        final qty = raw['quantity'] ?? 1;
        final total = asDoubleOr(raw['total_amount']).toStringAsFixed(2);
        out.add(_line('$name x$qty'));
        out.add(_line(_pad('', total)));
      }
    }
    out.add(_line('-' * charsPerLine));
    final subtotal = asDoubleOr(invoice['subtotal']).toStringAsFixed(2);
    final discount = asDoubleOr(invoice['discount_amount']).toStringAsFixed(2);
    final total = asDoubleOr(invoice['total_amount']).toStringAsFixed(2);
    out.add(_line(_pad('المجموع الفرعي', subtotal)));
    out.add(_line(_pad('الخصم', discount)));
    if (invoice['tax_amount'] != null) {
      out.add(
        _line(
          _pad(
            'الضريبة',
            asDoubleOr(invoice['tax_amount']).toStringAsFixed(2),
          ),
        ),
      );
    }
    out.add(_boldOn);
    out.add(_line(_pad('الإجمالي', total)));
    out.add(_boldOff);
    if (invoice['payment_method'] != null) {
      out.add(_line('الدفع: ${invoice['payment_method']}'));
    }
    out.add(_line(''));
    out.add(_line(''));
    out.add(_cut);
    return out.toBytes();
  }

  Uint8List buildTestPage(String printerName) {
    final out = BytesBuilder();
    out.add(_init);
    out.add(_alignCenter);
    out.add(_line('اختبار طابعة كاشير حاسم'));
    out.add(_line(printerName));
    out.add(_line(DateTime.now().toIso8601String()));
    out.add(_line(''));
    out.add(_cut);
    return out.toBytes();
  }

  List<int> _line(String text) {
    final encoded = utf8.encode('$text\n');
    return encoded;
  }

  String _pad(String left, String right) {
    final space = charsPerLine - left.length - right.length;
    if (space <= 0) return '$left $right';
    return '$left${' ' * space}$right';
  }
}

/// Sends ESC/POS bytes to a physical device.
///
/// Default implementation is intentionally **not** a fake success:
/// it refuses to print until a real transport plugin is configured.
abstract class PrinterTransportGateway {
  Future<PrintJobResult> send(Uint8List bytes, PrinterProfile profile);
  Future<List<PrinterProfile>> discover(PrinterTransport transport);
}

class UnconfiguredPrinterGateway implements PrinterTransportGateway {
  @override
  Future<List<PrinterProfile>> discover(PrinterTransport transport) async {
    return const [];
  }

  @override
  Future<PrintJobResult> send(Uint8List bytes, PrinterProfile profile) async {
    return PrintJobResult.fail(
      'الطابعة غير متصلة أو غير مُعدة. '
      'اضبط الطابعة من الإعدادات (Bluetooth / USB / Network). '
      'لا يتم ادعاء نجاح الطباعة بدون جهاز حقيقي.',
    );
  }
}

class NetworkPrinterGateway implements PrinterTransportGateway {
  @override
  Future<List<PrinterProfile>> discover(PrinterTransport transport) async {
    return const [];
  }

  @override
  Future<PrintJobResult> send(Uint8List bytes, PrinterProfile profile) async {
    final raw = profile.address?.trim() ?? '';
    if (raw.isEmpty) {
      return const PrintJobResult.fail('عنوان طابعة الشبكة فارغ.');
    }
    try {
      final parts = raw.split(':');
      final host = parts.first;
      final port = parts.length > 1 ? int.tryParse(parts[1]) ?? 9100 : 9100;
      final socket = await Socket.connect(
        host,
        port,
        timeout: const Duration(seconds: 5),
      );
      socket.add(bytes);
      await socket.flush();
      await socket.close();
      return const PrintJobResult.ok();
    } catch (e) {
      return PrintJobResult.fail('فشل الاتصال بطابعة الشبكة: $e');
    }
  }
}

class BluetoothPrinterGateway implements PrinterTransportGateway {
  @override
  Future<List<PrinterProfile>> discover(PrinterTransport transport) async {
    return const [];
  }

  @override
  Future<PrintJobResult> send(Uint8List bytes, PrinterProfile profile) async {
    return const PrintJobResult.fail(
      'طابعة Bluetooth غير مُفعّلة على هذه المنصة. استخدم طابعة شبكة TCP:9100.',
    );
  }
}

class UsbPrinterGateway implements PrinterTransportGateway {
  @override
  Future<List<PrinterProfile>> discover(PrinterTransport transport) async {
    return const [];
  }

  @override
  Future<PrintJobResult> send(Uint8List bytes, PrinterProfile profile) async {
    return const PrintJobResult.fail(
      'طابعة USB غير مُفعّلة على هذه المنصة. استخدم طابعة شبكة TCP:9100.',
    );
  }
}

class CompositePrinterGateway implements PrinterTransportGateway {
  CompositePrinterGateway({
    NetworkPrinterGateway? network,
    BluetoothPrinterGateway? bluetooth,
    UsbPrinterGateway? usb,
  }) : _network = network ?? NetworkPrinterGateway(),
       _bluetooth = bluetooth ?? BluetoothPrinterGateway(),
       _usb = usb ?? UsbPrinterGateway();

  final NetworkPrinterGateway _network;
  final BluetoothPrinterGateway _bluetooth;
  final UsbPrinterGateway _usb;

  PrinterTransportGateway _for(PrinterTransport transport) {
    return switch (transport) {
      PrinterTransport.network || PrinterTransport.system => _network,
      PrinterTransport.bluetooth => _bluetooth,
      PrinterTransport.usb => _usb,
    };
  }

  @override
  Future<List<PrinterProfile>> discover(PrinterTransport transport) {
    return _for(transport).discover(transport);
  }

  @override
  Future<PrintJobResult> send(Uint8List bytes, PrinterProfile profile) {
    return _for(profile.transport).send(bytes, profile);
  }
}

class PrinterService {
  PrinterService(this._gateway, this._prefs);

  final PrinterTransportGateway _gateway;
  final SharedPreferences _prefs;
  final _builder = EscPosReceiptBuilder();

  static const _prefsKey = 'hasim_cashier_printer_profile';

  PrinterProfile? get selected {
    final raw = _prefs.getString(_prefsKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      return PrinterProfile.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
      );
    } catch (_) {
      return null;
    }
  }

  PrinterReadyState get readyState {
    final profile = selected;
    if (profile == null) return PrinterReadyState.notConfigured;
    if (profile.address == null || profile.address!.isEmpty) {
      return PrinterReadyState.configuredDisconnected;
    }
    return PrinterReadyState.ready;
  }

  Future<void> saveProfile(PrinterProfile profile) async {
    await _prefs.setString(_prefsKey, jsonEncode(profile.toJson()));
  }

  Future<void> clearProfile() async {
    await _prefs.remove(_prefsKey);
  }

  Future<PrintJobResult> testPrint() async {
    final profile = selected;
    if (profile == null) {
      return const PrintJobResult.fail('لم يتم اختيار طابعة.');
    }
    final bytes = _builder.buildTestPage(profile.name);
    return _gateway.send(bytes, profile);
  }

  Future<PrintJobResult> printInvoice(Map<String, dynamic> invoice) async {
    final profile = selected;
    if (profile == null) {
      return const PrintJobResult.fail(
        'لم يتم اختيار طابعة. افتح إعدادات الطباعة أولًا.',
      );
    }
    if (profile.address == null || profile.address!.trim().isEmpty) {
      return const PrintJobResult.fail(
        'عنوان الطابعة فارغ (IP / MAC / USB). الطابعة تعتبر غير متصلة.',
      );
    }
    final bytes = EscPosReceiptBuilder(
      charsPerLine: profile.paperChars,
    ).buildInvoice(invoice);
    return _gateway.send(bytes, profile);
  }

  Future<List<PrinterProfile>> discover(PrinterTransport transport) {
    return _gateway.discover(transport);
  }
}

final printerGatewayProvider = Provider<PrinterTransportGateway>((ref) {
  return CompositePrinterGateway();
});

final printerServiceProvider = Provider<PrinterService>((ref) {
  throw UnimplementedError('Initialize SharedPreferences before use.');
});

final printerServiceFutureProvider = FutureProvider<PrinterService>((
  ref,
) async {
  final prefs = await SharedPreferences.getInstance();
  return PrinterService(ref.watch(printerGatewayProvider), prefs);
});
