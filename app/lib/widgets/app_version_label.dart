import 'package:flutter/material.dart';

import '../config.dart';

/// Small muted "OpenPlay v1.2.3" footer, so users (and support) can tell
/// which build is running. [version] defaults to the build's
/// OPENPLAY_VERSION (see AppConfig.appVersion).
class AppVersionLabel extends StatelessWidget {
  const AppVersionLabel({super.key, this.version = AppConfig.appVersion});

  final String version;

  @override
  Widget build(BuildContext context) {
    final label = version == 'dev' ? 'OpenPlay (development build)' : 'OpenPlay v$version';
    return Center(
      child: Text(label, style: Theme.of(context).textTheme.bodySmall),
    );
  }
}
