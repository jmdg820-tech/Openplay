import 'dart:async';

import 'package:flutter/material.dart';

/// Ticks a promotion-confirmation countdown down locally between server
/// refetches, so it doesn't visibly freeze for the whole polling interval.
/// Re-syncs to [seconds] whenever the parent passes a fresh value (i.e.
/// after every roster refetch), so drift never accumulates for long.
class CountdownText extends StatefulWidget {
  const CountdownText({super.key, required this.seconds});

  final int seconds;

  @override
  State<CountdownText> createState() => _CountdownTextState();
}

class _CountdownTextState extends State<CountdownText> {
  late int _remaining;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _remaining = widget.seconds;
    _startTimer();
  }

  @override
  void didUpdateWidget(covariant CountdownText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.seconds != oldWidget.seconds) {
      _remaining = widget.seconds;
    }
  }

  void _startTimer() {
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _remaining = _remaining > 0 ? _remaining - 1 : 0);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final minutes = _remaining ~/ 60;
    final secs = _remaining % 60;
    final text = '${minutes}m ${secs.toString().padLeft(2, '0')}s left to confirm';
    final theme = Theme.of(context);
    return Text(
      text,
      style: theme.textTheme.labelMedium?.copyWith(
        color: _remaining <= 60 ? theme.colorScheme.error : theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}
