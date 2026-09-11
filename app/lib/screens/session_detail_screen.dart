import 'dart:async';

import 'package:flutter/material.dart';

import '../models/roster_entry.dart';
import '../models/session.dart';
import '../services/openplay_api.dart';
import '../utils/error_messages.dart';
import '../utils/roster_actions.dart';
import '../widgets/countdown_text.dart';
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

  /// Participant ids the current user manages in this session (their own
  /// registered participant row, or guest rows whose management_token this
  /// device captured at join time). Never derived from the roster itself
  /// (which never carries user_id) -- only from this client's own actions.
  final Map<String, String?> _myParticipants = {}; // participantId -> managementToken

  Timer? _pollTimer;
  StreamSubscription<List<Map<String, dynamic>>>? _sessionSub;

  @override
  void initState() {
    super.initState();
    _session = widget.session;
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
      _myParticipants[result.participantId] = null;
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Joined — status: ${result.status}')));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Join failed: $e')));
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
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Join failed: $e')));
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
    final token = _myParticipants[entry.participantId];
    try {
      await widget.api.leaveSession(entry.participantId, managementToken: token);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Leave failed: $e')));
    }
    _refreshRoster();
  }

  Future<void> _confirmPromotion(RosterEntry entry) async {
    final token = _myParticipants[entry.participantId];
    try {
      await widget.api.confirmPromotion(entry.participantId, managementToken: token);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Confirm failed: $e')));
      }
    }
    _refreshRoster();
  }

  Future<void> _removeAsOrganizer(RosterEntry entry) async {
    try {
      await widget.api.removeParticipant(entry.participantId);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Remove failed: $e')));
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
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Cancel failed: $e')));
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
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Save failed: $e')));
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
    final roster = _roster;
    final confirmedCount = roster?.where((r) => r.status == 'confirmed').length ?? 0;
    final waitlistedCount = roster?.where((r) => r.status == 'waitlisted').length ?? 0;

    return Scaffold(
      appBar: AppBar(
        title: Text('${_session.sessionType} session'),
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
                    if (widget.api.isSignedIn)
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
          padding: const EdgeInsets.all(16),
          children: [
            Text('${_session.startTime.toLocal()} → ${_session.endTime.toLocal()}'),
            const SizedBox(height: 4),
            Text('Capacity: $confirmedCount / ${_session.capacity} joined'
                '${waitlistedCount > 0 ? '  •  $waitlistedCount waitlisted' : ''}'),
            if (_session.skillLevelInfo != null) Text('Skill: ${_session.skillLevelInfo}'),
            if (_session.isCancelled)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('CANCELLED: ${_session.cancellationReason ?? ''}',
                    style: TextStyle(color: Theme.of(context).colorScheme.error, fontWeight: FontWeight.bold)),
              ),
            const Divider(height: 32),
            Text('Roster', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (_rosterError != null) Text('Failed to load roster: $_rosterError'),
            if (roster == null)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (roster.isEmpty)
              const Text('No one has joined yet.')
            else
              Column(
                children: roster.map((entry) {
                  final isMine = _myParticipants.containsKey(entry.participantId);
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
                  return Card(
                    child: ListTile(
                      leading: Icon(entry.isGuest == true ? Icons.person_outline : Icons.person),
                      title: Text(entry.displayName),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              StatusBadge(entry.status),
                              if (entry.skillLevel != null) ...[
                                const SizedBox(width: 6),
                                Text(entry.skillLevel!),
                              ],
                            ],
                          ),
                          if (entry.secondsUntilExpiry != null)
                            CountdownText(seconds: entry.secondsUntilExpiry!),
                        ],
                      ),
                      isThreeLine: entry.secondsUntilExpiry != null,
                      trailing: Wrap(
                        spacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          if (isMine && entry.status == 'pending_confirmation')
                            FilledButton(
                              onPressed: () => _confirmPromotion(entry),
                              child: const Text('Confirm'),
                            ),
                          if (isMine)
                            TextButton(onPressed: () => _leave(entry), child: const Text('Leave')),
                          if (_isOrganizer && !isMine)
                            IconButton(
                              icon: const Icon(Icons.person_remove),
                              tooltip: 'Remove (organizer/staff)',
                              onPressed: () => _removeAsOrganizer(entry),
                            ),
                          if (showModeration)
                            PopupMenuButton<String>(
                              tooltip: 'Report or block',
                              onSelected: (v) => v == 'report'
                                  ? _reportParticipant(entry)
                                  : _blockParticipant(entry),
                              itemBuilder: (context) => const [
                                PopupMenuItem(value: 'report', child: Text('Report')),
                                PopupMenuItem(value: 'block', child: Text('Block')),
                              ],
                            ),
                        ],
                      ),
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
