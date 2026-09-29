import 'dart:async';

import 'package:flutter/material.dart';

import '../models/roster_entry.dart';
import '../models/session.dart';
import '../models/venue.dart';
import '../services/openplay_api.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../utils/error_messages.dart';
import '../utils/roster_actions.dart';
import '../widgets/app_state_views.dart';
import '../widgets/countdown_text.dart';
import '../widgets/initials_avatar.dart';
import '../widgets/status_badge.dart';

class SessionDetailScreen extends StatefulWidget {
  const SessionDetailScreen({super.key, required this.api, required this.session});

  final OpenPlayApi api;
  final Session session;

  @override
  State<SessionDetailScreen> createState() => _SessionDetailScreenState();
}

class _SessionDetailScreenState extends State<SessionDetailScreen> {
  late Session _session;
  List<RosterEntry>? _roster;
  Object? _rosterError;
  late Future<Venue> _venueFuture;

  /// Rows this screen instance knows it manages: participantId ->
  /// management_token. Mainly GUEST rows (token captured at guest-join time
  /// or re-entered from a saved guest code); a registered join is also noted
  /// with a null token as a same-screen fallback. Ownership of registered
  /// rows is primarily the server's `is_self` on every roster fetch (see
  /// isMyEntry()), which is what keeps Leave/Confirm available after
  /// navigating away or restarting -- this map is never relied on for that.
  final Map<String, String?> _myParticipants = {};

  /// Guards Leave/Confirm against double taps while a request is in flight.
  bool _actionInFlight = false;

  Timer? _pollTimer;
  StreamSubscription<List<Map<String, dynamic>>>? _sessionSub;

  @override
  void initState() {
    super.initState();
    _session = widget.session;
    _venueFuture = widget.api.getVenue(_session.venueId);
    _refreshRoster();
    // Roster changes (new joins, waitlist promotion, leaves) are never
    // pushed -- get_session_roster() is the sole read surface and it is a
    // plain RPC, not a Realtime-streamed one (session_participants is
    // deliberately excluded from Realtime). Poll it instead, exactly as the
    // approved architecture specifies ("roster changes should refetch
    // get_session_roster(); polling may be used").
    _pollTimer = Timer.periodic(const Duration(seconds: 8), (_) => _refreshRoster());
    // `sessions` itself IS Realtime-enabled, so status/time changes (e.g.
    // organizer cancels, or edits the start time) can update live.
    _sessionSub = widget.api.watchSessions().listen((rows) {
      final match = rows.where((r) => r['id'] == _session.id);
      if (match.isEmpty || !mounted) return;
      setState(() => _session = Session.fromRow(match.first));
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _sessionSub?.cancel();
    super.dispose();
  }

  Future<void> _refreshRoster() async {
    try {
      final roster = await widget.api.getSessionRoster(_session.id);
      if (!mounted) return;
      setState(() {
        _roster = roster;
        _rosterError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _rosterError = e);
    }
  }

  bool get _isOrganizer => widget.api.currentUserId == _session.createdBy;

  Future<void> _joinAsSelf() async {
    try {
      final result = await widget.api.joinAsSelf(_session.id);
      // Same-screen fallback only (null token = registered row). With
      // migration 028 the server's is_self already covers this and also
      // survives navigation/restarts; without it (a backend not yet
      // migrated) this keeps Leave available right after joining, exactly
      // as before the fix -- never worse.
      _myParticipants[result.participantId] = null;
      if (mounted) {
        final message = result.status == 'waitlisted'
            ? "This session is full -- you're on the waitlist."
            : "You're in!";
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Join failed: ${friendlyActionError(e)}')));
    }
    _refreshRoster();
  }

  Future<void> _joinAsGuest() async {
    final nameCtrl = TextEditingController();
    final contactCtrl = TextEditingController();
    var method = 'phone';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setStateDialog) => AlertDialog(
          title: const Text('Join as guest'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Your name')),
              DropdownButtonFormField<String>(
                initialValue: method,
                items: const [
                  DropdownMenuItem(value: 'phone', child: Text('Phone')),
                  DropdownMenuItem(value: 'email', child: Text('Email')),
                ],
                onChanged: (v) => setStateDialog(() => method = v ?? 'phone'),
                decoration: const InputDecoration(labelText: 'Contact method'),
              ),
              TextField(
                  controller: contactCtrl,
                  decoration: const InputDecoration(labelText: 'Contact value')),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Join')),
          ],
        ),
      ),
    );
    if (confirmed != true || nameCtrl.text.trim().isEmpty || contactCtrl.text.trim().isEmpty) return;

    try {
      final result = await widget.api.joinAsGuest(
        _session.id,
        guestName: nameCtrl.text.trim(),
        contactMethod: method,
        contactValue: contactCtrl.text.trim(),
      );
      _myParticipants[result.participantId] = result.managementToken;
      if (mounted && result.managementToken != null) {
        await _showTokenOnce(result.participantId, result.managementToken!);
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Join failed: ${friendlyActionError(e)}')));
    }
    _refreshRoster();
  }

  /// Shown exactly once, right after a guest join. Both values are required
  /// together to leave/confirm later (leave_session()/confirm_promotion()
  /// both take participant_id AND management_token) -- showing only the
  /// token here, as an earlier version of this screen did, left a guest
  /// with no way to ever use "I already have a guest code for this
  /// session" (below), since they were never told the other half they'd
  /// need.
  Future<void> _showTokenOnce(String participantId, String token) {
    final combined = '$participantId:$token';
    return showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Save this code'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'This is your ONLY way to manage your registration (leave, or confirm a '
              'waitlist promotion) as a guest. It is shown once, right now, and is never '
              'sent anywhere else -- not by email, not by SMS. Copy the whole code below -- '
              "you'll paste it back in via \"I already have a guest code for this session\" "
              'if you come back later.',
            ),
            const SizedBox(height: 12),
            SelectableText(
              combined,
              style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            Text(
              'If you lose this code, there is no way to recover it. An organizer or venue '
              'staff member can still remove you from the session if needed.',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ),
        actions: [
          FilledButton(onPressed: () => Navigator.pop(context), child: const Text('I saved it')),
        ],
      ),
    );
  }

  /// Re-entry path for a guest who saved their code (participant_id +
  /// management_token, see _showTokenOnce) and is now back in a fresh app
  /// session -- `_myParticipants` only lives in this State's memory, so
  /// without this there was no way to ever leave/confirm again after
  /// navigating away once.
  Future<void> _manageGuestRegistration() async {
    final codeCtrl = TextEditingController();
    final action = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Manage your guest registration'),
        content: TextField(
          controller: codeCtrl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Your guest code',
            hintText: 'Paste the code you saved when you joined',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, null), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, 'leave'), child: const Text('Leave')),
          FilledButton(
            onPressed: () => Navigator.pop(context, 'confirm'),
            child: const Text('Confirm my spot'),
          ),
        ],
      ),
    );
    if (action == null) return;

    final parts = codeCtrl.text.trim().split(':');
    if (parts.length != 2 || parts[0].isEmpty || parts[1].isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text("That doesn't look like a valid guest code.")));
      }
      return;
    }
    final participantId = parts[0];
    final token = parts[1];
    _myParticipants[participantId] = token; // so Leave/Confirm show on their row from now on

    try {
      if (action == 'leave') {
        await widget.api.leaveSession(participantId, managementToken: token);
      } else {
        await widget.api.confirmPromotion(participantId, managementToken: token);
      }
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(action == 'leave' ? 'Left the session.' : 'Confirmed.')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text("Couldn't complete that -- check your code and try again.")));
      }
    }
    _refreshRoster();
  }

  Future<void> _leave(RosterEntry entry) async {
    if (_actionInFlight) return;
    setState(() => _actionInFlight = true);
    final token = _myParticipants[entry.participantId];
    try {
      await widget.api.leaveSession(entry.participantId, managementToken: token);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Leave failed: ${friendlyActionError(e)}')));
    }
    await _refreshRoster();
    if (mounted) setState(() => _actionInFlight = false);
  }

  Future<void> _confirmPromotion(RosterEntry entry) async {
    if (_actionInFlight) return;
    setState(() => _actionInFlight = true);
    final token = _myParticipants[entry.participantId];
    try {
      await widget.api.confirmPromotion(entry.participantId, managementToken: token);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text("Spot confirmed -- you're in!")));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Confirm failed: ${friendlyActionError(e)}')));
      }
    }
    await _refreshRoster();
    if (mounted) setState(() => _actionInFlight = false);
  }

  Future<void> _removeAsOrganizer(RosterEntry entry) async {
    try {
      await widget.api.removeParticipant(entry.participantId);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Remove failed: ${friendlyActionError(e)}')));
    }
    _refreshRoster();
  }

  Future<void> _cancelSession() async {
    final reasonCtrl = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancel session'),
        content: TextField(
          controller: reasonCtrl,
          decoration: const InputDecoration(labelText: 'Reason (required)'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Back')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Cancel session'),
          ),
        ],
      ),
    );
    if (confirmed != true || reasonCtrl.text.trim().isEmpty) return;
    try {
      await widget.api.cancelSession(_session.id, reasonCtrl.text.trim());
      final updated = await widget.api.getSession(_session.id);
      if (mounted) setState(() => _session = updated);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Cancel failed: ${friendlyActionError(e)}')));
      }
    }
  }

  Future<void> _editSession() async {
    final capacityCtrl = TextEditingController(text: '${_session.capacity}');
    var start = _session.startTime;
    var end = _session.endTime;
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setStateDialog) => AlertDialog(
          title: const Text('Edit session'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('Starts: ${start.toLocal()}'),
                trailing: const Icon(Icons.edit_calendar),
                onTap: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: start,
                    firstDate: DateTime.now(),
                    lastDate: DateTime.now().add(const Duration(days: 365)),
                  );
                  if (picked == null || !context.mounted) return;
                  final time = await showTimePicker(
                      context: context, initialTime: TimeOfDay.fromDateTime(start));
                  if (time == null) return;
                  setStateDialog(() {
                    start = DateTime(picked.year, picked.month, picked.day, time.hour, time.minute);
                    if (end.isBefore(start)) end = start.add(const Duration(minutes: 90));
                  });
                },
              ),
              Text('Ends: ${end.toLocal()}'),
              TextField(
                controller: capacityCtrl,
                decoration: const InputDecoration(labelText: 'Capacity'),
                keyboardType: TextInputType.number,
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
          ],
        ),
      ),
    );
    if (saved != true) return;
    try {
      await widget.api.updateSession(
        _session.id,
        startTime: start,
        endTime: end,
        capacity: int.tryParse(capacityCtrl.text),
      );
      final updated = await widget.api.getSession(_session.id);
      if (mounted) setState(() => _session = updated);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Save failed: ${friendlyActionError(e)}')));
    }
  }

  /// Shared reason-collection UI for report actions -- used for both the
  /// organizer (still targeted via sessions.created_by + submit_report(),
  /// since an organizer who never joined their own session as a player has
  /// no participant_id for report_session_participant() to resolve -- see
  /// the "why the organizer path isn't replaced" note in build() below) and
  /// roster participants (targeted via participant_id +
  /// report_session_participant()). submit_report() itself always requires
  /// a non-empty reason; this enforces that client-side for both paths
  /// rather than only the newer one.
  Future<String?> _askForReportReason(String targetLabel) async {
    final reasonCtrl = TextEditingController();
    String? error;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setStateDialog) => AlertDialog(
          title: Text('Report $targetLabel'),
          content: TextField(
            controller: reasonCtrl,
            autofocus: true,
            decoration: InputDecoration(labelText: 'Reason', errorText: error),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                if (reasonCtrl.text.trim().isEmpty) {
                  setStateDialog(() => error = 'A reason is required.');
                  return;
                }
                Navigator.pop(context, true);
              },
              child: const Text('Submit'),
            ),
          ],
        ),
      ),
    );
    return confirmed == true ? reasonCtrl.text.trim() : null;
  }

  Future<bool> _confirmBlock(String targetLabel) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Block $targetLabel?'),
        content: const Text(
          "You won't be shown this person's sessions as prominently, and this affects how "
          "you two interact across OpenPlay going forward. You can undo this later from "
          'Account → Blocked users.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Block'),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  Future<void> _reportOrganizer() async {
    final reason = await _askForReportReason("this session's organizer");
    if (reason == null) return;
    try {
      await widget.api.submitReport(
        reportedUserId: _session.createdBy,
        sessionId: _session.id,
        reason: reason,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Report submitted.')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(friendlyReportBlockError(e))));
      }
    }
  }

  Future<void> _blockOrganizer() async {
    if (!await _confirmBlock("this session's organizer")) return;
    try {
      await widget.api.blockUser(_session.createdBy);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Blocked.')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(friendlyReportBlockError(e))));
      }
    }
  }

  /// Targets a roster row by participant_id only -- report_session_participant()
  /// resolves the underlying user_id server-side and this client never
  /// learns it, before or after.
  Future<void> _reportParticipant(RosterEntry entry) async {
    final reason = await _askForReportReason(entry.displayName);
    if (reason == null) return;
    try {
      await widget.api.reportParticipant(entry.participantId, reason);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Report submitted.')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(friendlyReportBlockError(e))));
      }
    }
    _refreshRoster();
  }

  Future<void> _blockParticipant(RosterEntry entry) async {
    if (!await _confirmBlock(entry.displayName)) return;
    try {
      await widget.api.blockParticipant(entry.participantId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Blocked.')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(friendlyReportBlockError(e))));
      }
    }
    _refreshRoster();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final roster = _roster;
    final confirmedCount = roster?.where((r) => r.status == 'confirmed').length ?? 0;
    final waitlistedCount = roster?.where((r) => r.status == 'waitlisted').length ?? 0;
    // Pending offers hold a spot too -- same rule the server applies.
    final isFull = occupiedSpots(roster ?? const []) >= _session.capacity;
    final alreadyJoined = hasActiveSelfEntry(roster ?? const []);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          '${_session.sessionType[0].toUpperCase()}${_session.sessionType.substring(1)} session',
        ),
        actions: [
          if (_isOrganizer && !_session.isCancelled) ...[
            IconButton(icon: const Icon(Icons.edit), tooltip: 'Edit session', onPressed: _editSession),
            IconButton(icon: const Icon(Icons.cancel), tooltip: 'Cancel session', onPressed: _cancelSession),
          ],
          // Kept as its own path rather than routed through
          // report_session_participant()/block_session_participant(): an
          // organizer does NOT automatically get a session_participants row
          // (they only get one if they also join as a player), so there is
          // no guaranteed participant_id to resolve them by. sessions.created_by
          // is already public, so targeting the organizer directly via
          // submit_report()/blocks (as before) remains the only reliable path
          // for this specific case -- not a duplicate of the roster action
          // below, which needs a real roster row to exist.
          PopupMenuButton<String>(
            tooltip: 'Report or block organizer',
            onSelected: (v) => v == 'report' ? _reportOrganizer() : _blockOrganizer(),
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'report', child: Text('Report organizer')),
              PopupMenuItem(value: 'block', child: Text('Block organizer')),
            ],
          ),
        ],
      ),
      floatingActionButton: _session.isCancelled
          ? null
          : FloatingActionButton.extended(
              onPressed: () => showModalBottomSheet(
                context: context,
                builder: (context) => SafeArea(
                  child: Wrap(children: [
                    // Only offered when signed in -- join_session() requires
                    // either a real auth.uid() or guest fields; an anonymous
                    // browser tapping "Join" here would just get a
                    // guest-fields-required error, so don't offer it.
                    // Hidden once the server reports the viewer already
                    // holds an active registration (is_self) -- a second
                    // join would only be rejected with "already joined".
                    if (widget.api.isSignedIn && !alreadyJoined)
                      ListTile(
                        leading: const Icon(Icons.person),
                        title: const Text('Join'),
                        onTap: () {
                          Navigator.pop(context);
                          _joinAsSelf();
                        },
                      ),
                    ListTile(
                      leading: const Icon(Icons.person_add_alt),
                      title: const Text('Join as guest'),
                      onTap: () {
                        Navigator.pop(context);
                        _joinAsGuest();
                      },
                    ),
                    ListTile(
                      leading: const Icon(Icons.key_outlined),
                      title: const Text('I already have a guest code for this session'),
                      onTap: () {
                        Navigator.pop(context);
                        _manageGuestRegistration();
                      },
                    ),
                  ]),
                ),
              ),
              icon: const Icon(Icons.add),
              label: const Text('Join'),
            ),
      body: RefreshIndicator(
        onRefresh: _refreshRoster,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.xxxl + 64),
          children: [
            if (_session.isCancelled) ...[
              _CancelledBanner(reason: _session.cancellationReason),
              const SizedBox(height: AppSpacing.lg),
            ],
            _SessionInfoCard(
              session: _session,
              venueFuture: _venueFuture,
              confirmedCount: confirmedCount,
              waitlistedCount: waitlistedCount,
              isFull: isFull,
            ),
            const SizedBox(height: AppSpacing.xl),
            Row(
              children: [
                Text('Roster', style: theme.textTheme.headlineSmall),
                const SizedBox(width: AppSpacing.sm),
                if (roster != null)
                  Text('(${roster.length})', style: theme.textTheme.bodyMedium?.copyWith(color: AppColors.slate)),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            if (_rosterError != null)
              ErrorStateView(message: friendlyActionError(_rosterError!), onRetry: _refreshRoster)
            else if (roster == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: AppSpacing.xxl),
                child: LoadingStateView(),
              )
            else if (roster.isEmpty)
              const EmptyStateView(
                icon: Icons.groups_outlined,
                title: 'No one has joined yet',
                message: 'Be the first -- tap Join below.',
              )
            else
              Column(
                children: roster.map((entry) {
                  final isMine = isMyEntry(entry, _myParticipants);
                  // See utils/roster_actions.dart for exactly why this is a
                  // deny-list on isGuest==true rather than an allow-list on
                  // isGuest==false: an ordinary joined participant is never
                  // told is_guest by the server (only organizer/staff are),
                  // so it's usually null even for a real guest row -- the
                  // RPC itself is the actual, reliable enforcement point.
                  final showModeration = canReportOrBlock(
                    entry,
                    isMine: isMine,
                    isSignedIn: widget.api.isSignedIn,
                  );
                  return Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                    child: _RosterRow(
                      entry: entry,
                      isMine: isMine,
                      canLeave: canLeave(entry, _myParticipants),
                      canConfirm: canConfirm(entry, _myParticipants),
                      actionsEnabled: !_actionInFlight,
                      isOrganizer: _isOrganizer,
                      showModeration: showModeration,
                      onConfirm: () => _confirmPromotion(entry),
                      onLeave: () => _leave(entry),
                      onRemove: () => _removeAsOrganizer(entry),
                      onReport: () => _reportParticipant(entry),
                      onBlock: () => _blockParticipant(entry),
                    ),
                  );
                }).toList(),
              ),
          ],
        ),
      ),
    );
  }
}

class _SessionInfoCard extends StatelessWidget {
  const _SessionInfoCard({
    required this.session,
    required this.venueFuture,
    required this.confirmedCount,
    required this.waitlistedCount,
    required this.isFull,
  });

  final Session session;
  final Future<Venue> venueFuture;
  final int confirmedCount;
  final int waitlistedCount;
  final bool isFull;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: AppColors.courtTealPale,
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                  child: Icon(
                    session.sessionType == 'singles' ? Icons.person_rounded : Icons.groups_2_rounded,
                    color: AppColors.courtTealDeep,
                    size: 24,
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: FutureBuilder<Venue>(
                    future: venueFuture,
                    builder: (context, snapshot) => Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '${session.sessionType[0].toUpperCase()}${session.sessionType.substring(1)} pickleball',
                          style: theme.textTheme.titleLarge,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          snapshot.data?.name ?? 'Loading venue…',
                          style: theme.textTheme.bodyMedium?.copyWith(color: AppColors.slate),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ),
                if (!session.isCancelled) StatusBadge(isFull ? 'full' : 'active'),
              ],
            ),
            const SizedBox(height: AppSpacing.lg),
            const Divider(height: 1),
            const SizedBox(height: AppSpacing.lg),
            Wrap(
              spacing: AppSpacing.xl,
              runSpacing: AppSpacing.md,
              children: [
                SessionStat(
                  icon: Icons.schedule_rounded,
                  label: 'When',
                  value: '${_fmt(session.startTime)} – ${_fmtTime(session.endTime)}',
                ),
                SessionStat(
                  icon: Icons.groups_rounded,
                  label: 'Players',
                  value: '$confirmedCount / ${session.capacity} joined'
                      '${waitlistedCount > 0 ? ' · $waitlistedCount waiting' : ''}',
                ),
                if (session.skillLevelInfo != null)
                  SessionStat(icon: Icons.bar_chart_rounded, label: 'Skill level', value: session.skillLevelInfo!),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _fmtTime(DateTime t) {
    final l = t.toLocal();
    return '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
  }

  static String _fmt(DateTime t) {
    final l = t.toLocal();
    return '${l.year}-${l.month.toString().padLeft(2, '0')}-${l.day.toString().padLeft(2, '0')} ${_fmtTime(t)}';
  }
}

class SessionStat extends StatelessWidget {
  const SessionStat({super.key, required this.icon, required this.label, required this.value});
  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 140),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: AppColors.slate),
          const SizedBox(width: AppSpacing.sm),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(label, style: theme.textTheme.labelSmall),
                Text(value, style: theme.textTheme.bodyMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CancelledBanner extends StatelessWidget {
  const _CancelledBanner({required this.reason});
  final String? reason;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: AppColors.statusCancelledBg,
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Row(
        children: [
          const Icon(Icons.event_busy_rounded, color: AppColors.statusCancelled),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('This session was cancelled',
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(color: AppColors.statusCancelled)),
                if (reason != null && reason!.isNotEmpty)
                  Text(reason!, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RosterRow extends StatelessWidget {
  const _RosterRow({
    required this.entry,
    required this.isMine,
    required this.canLeave,
    required this.canConfirm,
    required this.actionsEnabled,
    required this.isOrganizer,
    required this.showModeration,
    required this.onConfirm,
    required this.onLeave,
    required this.onRemove,
    required this.onReport,
    required this.onBlock,
  });

  final RosterEntry entry;
  final bool isMine;
  final bool canLeave;
  final bool canConfirm;
  final bool actionsEnabled;
  final bool isOrganizer;
  final bool showModeration;
  final VoidCallback onConfirm;
  final VoidCallback onLeave;
  final VoidCallback onRemove;
  final VoidCallback onReport;
  final VoidCallback onBlock;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            InitialsAvatar(entry.displayName, muted: entry.isGuest == true),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(entry.displayName,
                            style: theme.textTheme.titleMedium, overflow: TextOverflow.ellipsis),
                      ),
                      if (isMine) ...[
                        const SizedBox(width: AppSpacing.xs),
                        Text('(you)', style: theme.textTheme.bodySmall),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: AppSpacing.sm,
                    runSpacing: 4,
                    children: [
                      StatusBadge(entry.status, dense: true),
                      if (isMine && entry.waitlistPosition != null)
                        Text('#${entry.waitlistPosition} in line', style: theme.textTheme.bodySmall),
                      if (entry.skillLevel != null)
                        Text(entry.skillLevel!, style: theme.textTheme.bodySmall),
                    ],
                  ),
                  if (entry.secondsUntilExpiry != null) ...[
                    const SizedBox(height: 4),
                    CountdownText(seconds: entry.secondsUntilExpiry!),
                  ],
                ],
              ),
            ),
            if (canConfirm)
              FilledButton(onPressed: actionsEnabled ? onConfirm : null, child: const Text('Confirm')),
            if (canLeave)
              TextButton(onPressed: actionsEnabled ? onLeave : null, child: const Text('Leave')),
            if (isOrganizer && !isMine)
              IconButton(
                icon: const Icon(Icons.person_remove_outlined),
                tooltip: 'Remove (organizer/staff)',
                onPressed: onRemove,
              ),
            if (showModeration)
              PopupMenuButton<String>(
                tooltip: 'Report or block',
                onSelected: (v) => v == 'report' ? onReport() : onBlock(),
                itemBuilder: (context) => const [
                  PopupMenuItem(value: 'report', child: Text('Report')),
                  PopupMenuItem(value: 'block', child: Text('Block')),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
