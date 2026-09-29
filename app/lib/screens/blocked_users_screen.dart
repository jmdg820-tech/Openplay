import 'package:flutter/material.dart';

import '../models/public_profile.dart';
import '../services/openplay_api.dart';
import '../theme/app_spacing.dart';
import '../utils/error_messages.dart';
import '../widgets/app_state_views.dart';
import '../widgets/initials_avatar.dart';

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

  void _refresh() {
    // Same fix as venue_list_screen.dart's _refresh(): a block body, not an
    // arrow-expression assignment, so the setState callback's inferred
    // return type is void rather than the Future _load() assigns.
    setState(() {
      _blockedFuture = _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Blocked users')),
      body: FutureBuilder<Map<String, PublicProfile>>(
        future: _blockedFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const LoadingStateView();
          }
          if (snapshot.hasError) {
            return ErrorStateView(message: friendlyActionError(snapshot.error!), onRetry: _refresh);
          }
          final blocked = snapshot.data!.values.toList();
          if (blocked.isEmpty) {
            return const EmptyStateView(
              icon: Icons.shield_outlined,
              title: "You haven't blocked anyone",
              message: 'People you block from a session will show up here.',
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.all(AppSpacing.lg),
            itemCount: blocked.length,
            itemBuilder: (context, i) {
              final p = blocked[i];
              return Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.sm),
                    child: Row(
                      children: [
                        InitialsAvatar(p.name, muted: true),
                        const SizedBox(width: AppSpacing.md),
                        Expanded(
                          child: Text(p.name, style: Theme.of(context).textTheme.bodyLarge),
                        ),
                        TextButton(
                          onPressed: () async {
                            await widget.api.unblockUser(p.id);
                            _refresh();
                          },
                          child: const Text('Unblock'),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
