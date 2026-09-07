import 'dart:async';

import 'package:flutter/material.dart';

import '../util/occupied_duration.dart';

/// Ticks every second from [openedAt] without requiring a parent refresh.
class OccupiedDurationLabel extends StatefulWidget {
  const OccupiedDurationLabel({
    super.key,
    required this.openedAt,
    this.placeholder = '—',
    this.prefix = '',
    this.style,
  });

  final DateTime? openedAt;
  final String placeholder;
  final String prefix;
  final TextStyle? style;

  @override
  State<OccupiedDurationLabel> createState() => _OccupiedDurationLabelState();
}

class _OccupiedDurationLabelState extends State<OccupiedDurationLabel> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _syncTimer();
  }

  @override
  void didUpdateWidget(covariant OccupiedDurationLabel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.openedAt != widget.openedAt) {
      _syncTimer();
    }
  }

  void _syncTimer() {
    _timer?.cancel();
    _timer = null;
    if (widget.openedAt != null) {
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final opened = widget.openedAt;
    if (opened == null) {
      return Text(widget.placeholder, style: widget.style);
    }
    return Text(
      '${widget.prefix}${formatOccupiedDuration(opened, DateTime.now())}',
      style: widget.style,
    );
  }
}
