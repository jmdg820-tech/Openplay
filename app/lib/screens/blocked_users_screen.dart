import 'package:flutter/material.dart';

import '../models/public_profile.dart';
import '../services/openplay_api.dart';

/// Lightweight moderation surface: the registered user's own blocks
/// (`blocks_select_own` -- never who blocked *them*, see the security
/// gate's affected-user case) with an unblock action. No full moderation
/// review workflow -- out of scope for this MVP.
class BlockedUsersScreen extends StatefulWidget {
  const BlockedUsersScreen({super.key, required this.api});

  final OpenPlayApi api;

  @override
  State<BlockedUsersScreen> createState() => _BlockedUsersScreenState();
}

class _BlockedUsersScreenState extends State<BlockedUsersScreen> {
  late Future<Map<String, PublicProfile>> _blockedFuture;

  @override
  void initState() {
    super.initState();
    _blockedFuture = _load();
  }

  Future<Map<String, PublicProfile>> _load() async {
    final ids = await widget.api.listMyBlockedUserIds();
    return widget.api.getPublicProfiles(ids);
  }

  void _refresh() => setState(() => _blockedFuture = _load());

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Blocked users')),
      body: FutureBuilder<Map<String, PublicProfile>>(
        future: _blockedFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) return Center(child: Text('Failed to load: ${snapshot.error}'));
          final blocked = snapshot.data!.values.toList();
          if (blocked.isEmpty) {
            return const Center(child: Text("You haven't blocked anyone."));
          }
          return ListView(
            children: blocked
                .map((p) => ListTile(
                      title: Text(p.name),
                      trailing: TextButton(
                        onPressed: () async {
                          await widget.api.unblockUser(p.id);
                          _refresh();
                        },
                        child: const Text('Unblock'),
                      ),
                    ))
                .toList(),
          );
        },
      ),
    );
  }
}
