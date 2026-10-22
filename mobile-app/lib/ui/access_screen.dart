import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../engine/engine.dart';
import '../services/access_store.dart';
import '../services/actions.dart';
import '../services/audio.dart';
import '../services/store.dart';
import 'fallback_screens.dart';
import 'wallet_screen.dart' show waitForPacket;

/// Everything the Access pages need.
class AccessDeps {
  final AppStore app;
  final AccessStore store;
  final SoundPlayer player;
  final SoundListener mainListener;
  AccessDeps(this.app, this.store, this.player, this.mainListener);
  Identity get me => app.identity;
  Profile get profile => app.profile;
  SoundLink get link => SoundLink(app.profile, volume: app.volume);
}

class AccessScreen extends StatelessWidget {
  final AccessDeps deps;
  const AccessScreen({super.key, required this.deps});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    void go(Widget page) => Navigator.push(context, MaterialPageRoute(builder: (_) => page));
    Widget tile(IconData i, String t, String s, Widget page) => ListTile(
          leading: Icon(i),
          title: Text(t),
          subtitle: Text(s),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => go(page),
        );
    Widget head(String t) => Padding(padding: const EdgeInsets.fromLTRB(16, 20, 16, 4), child: Text(t, style: theme.textTheme.titleSmall));

    return ListenableBuilder(
      listenable: deps.store,
      builder: (context, _) => ListView(children: [
        head('Attendance'),
        tile(Icons.school, "I'm a student", 'Mark yourself present in class', StudentPage(deps: deps)),
        tile(Icons.co_present, 'Take attendance', 'Teacher: play a code only phones in the room can hear', TeacherPage(deps: deps)),
        head('Tickets'),
        tile(Icons.confirmation_number, 'My tickets (${deps.store.tickets.length})', 'Get a ticket or show one at the gate', TicketsPage(deps: deps)),
        tile(Icons.event, deps.store.event == null ? 'Organize an event' : 'My event: ${deps.store.event!.name}',
            'Give out tickets and check them at the gate, offline', OrganizerPage(deps: deps)),
        head('Doors'),
        tile(Icons.lock_open, 'Unlock a door', 'Your phone is the key', DoorKeyPage(deps: deps)),
        tile(Icons.sensor_door, deps.store.door == null ? 'Make this phone a door' : 'This phone is door: ${deps.store.door!.name}',
            'Leave a phone by the door; it checks who may enter', DoorModePage(deps: deps)),
        head('Login'),
        tile(Icons.login, 'Log in to a website', 'No password: approve the login the laptop plays', LoginPage(deps: deps)),
      ]),
    );
  }
}

// ---------------------------------------------------------------- shared flow page

/// A page that runs a sound conversation and shows its status.
abstract class FlowPage extends StatefulWidget {
  final AccessDeps deps;
  const FlowPage({super.key, required this.deps});
}

abstract class FlowState<T extends FlowPage> extends State<T> {
  final listener = SoundListener();
  String status = '';
  IconData icon = Icons.hearing;
  Color? color;
  bool running = false;
  bool cancelled = false;

  AccessDeps get deps => widget.deps;

  /// Error colour that doesn't need a BuildContext (safe after awaits).
  Color get bad => Colors.red.shade700;

  void set(String s, {IconData? i, Color? c}) {
    if (!mounted) return;
    setState(() {
      status = s;
      if (i != null) icon = i;
      color = c;
    });
  }

  /// Listen for one packet of these types (other packets are ignored).
  Future<Received?> hear(Set<int> types, Duration timeout) =>
      waitForPacket(listener, deps.profile, types, timeout, () => cancelled || !mounted);

  Future<void> say(List<int> raw, {int repeat = 1}) async {
    final l = deps.link;
    await deps.player.playPacket(l, raw, repeat: repeat);
  }

  Future<void> run(Future<void> Function() body) async {
    if (running) return;
    setState(() {
      running = true;
      cancelled = false;
    });
    await deps.mainListener.stop();
    try {
      await body();
    } catch (e) {
      set('$e', i: Icons.error_outline, c: bad);
    } finally {
      if (mounted) setState(() => running = false);
    }
  }

  void stop() => setState(() => cancelled = true);

  @override
  void dispose() {
    cancelled = true;
    listener.dispose();
    super.dispose();
  }

  Widget statusBox() => Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Column(children: [
          Icon(icon, size: 64, color: color ?? Theme.of(context).colorScheme.primary),
          const SizedBox(height: 12),
          Text(status, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
          if (running) const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator()),
        ]),
      );

  Widget startStop(String label, VoidCallback onStart) => running
      ? OutlinedButton.icon(onPressed: stop, icon: const Icon(Icons.stop), label: const Text('Stop'))
      : FilledButton.icon(onPressed: onStart, icon: const Icon(Icons.play_arrow), label: Text(label));
}

Future<String?> askText(BuildContext context, String title, String label, {String initial = ''}) {
  final c = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(controller: c, autofocus: true, maxLength: 30, decoration: InputDecoration(labelText: label)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('OK')),
      ],
    ),
  );
}

Future<bool> confirm(BuildContext context, String title, String body, {String yes = 'Yes', String no = 'No'}) async =>
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(title: Text(title), content: Text(body), actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(no)),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(yes)),
      ]),
    ) ??
    false;

String _myName(AccessDeps d) => d.app.myCard?.name ?? '';

// ---------------------------------------------------------------- attendance

class StudentPage extends FlowPage {
  const StudentPage({super.key, required super.deps});
  @override
  State<StudentPage> createState() => _StudentState();
}

class _StudentState extends FlowState<StudentPage> {
  late final name = TextEditingController(text: _myName(deps));

  void _start() {
    if (name.text.trim().isEmpty) return showSnack(context, 'Enter your name');
    run(() async {
      set('Listening for the class code…', i: Icons.hearing);
      final r = await hear({PacketType.attendance}, const Duration(minutes: 1));
      if (r == null) return set('No class code heard. Are you in the room?', i: Icons.hearing_disabled);
      final b = readBeacon(r.packet!);
      for (var attempt = 1; attempt <= 3 && !cancelled; attempt++) {
        set('Class "${b.title}"\nMarking you present…', i: Icons.volume_up);
        await say(await checkInPacket(b, name.text, deps.me));
        final ack = await hear({PacketType.attendance}, const Duration(seconds: 6));
        if (ack == null) continue;
        try {
          final n = await readAck(ack.packet!, deps.me, b);
          return set('You are marked present in "${b.title}"\n$n in class so far', i: Icons.check_circle, c: Colors.green);
        } on AccessError {
          continue; // a beacon or someone else's ack
        } on PacketError {
          continue;
        }
      }
      set('The teacher did not confirm. Try again.', i: Icons.info_outline);
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text("I'm a student"), actions: [FallbackButton(store: deps.app)]),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          TextField(controller: name, enabled: !running, decoration: const InputDecoration(labelText: 'Your name', border: OutlineInputBorder())),
          statusBox(),
          startStop('Mark me present', _start),
          const SizedBox(height: 12),
          Text('Uses the sound mode from Settings (${deps.profile.label}); ask the teacher which one.', textAlign: TextAlign.center),
        ]),
      );
}

class TeacherPage extends FlowPage {
  const TeacherPage({super.key, required super.deps});
  @override
  State<TeacherPage> createState() => _TeacherState();
}

class _TeacherState extends FlowState<TeacherPage> {
  final title = TextEditingController();
  ClassSession? cls;

  void _start() {
    if (title.text.trim().isEmpty) return showSnack(context, 'Enter the class name');
    final c = cls = ClassSession(title.text.trim());
    run(() async {
      var lastBeacon = DateTime(2000);
      while (!cancelled && mounted) {
        if (DateTime.now().difference(lastBeacon).inSeconds >= 8) {
          set('Playing class code… ${c.present.length} present', i: Icons.volume_up);
          await say(await c.beacon(deps.me));
          lastBeacon = DateTime.now();
        }
        set('Listening… ${c.present.length} present', i: Icons.hearing);
        final r = await hear({PacketType.attendance}, const Duration(seconds: 4));
        if (r == null) continue;
        try {
          final res = await c.checkIn(r.packet!, deps.me);
          setState(() {});
          await say(res.ack);
        } on AccessError catch (e) {
          set('Refused one check-in: ${e.message}', i: Icons.warning_amber);
        } on PacketError {
          // not a check-in
        }
      }
      await deps.store.saveClass(c);
      set('Finished: ${c.present.length} present. Saved below.', i: Icons.check_circle);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = cls;
    return Scaffold(
      appBar: AppBar(title: const Text('Take attendance'), actions: [FallbackButton(store: deps.app)]),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        TextField(controller: title, enabled: !running, decoration: const InputDecoration(labelText: 'Class name', border: OutlineInputBorder())),
        const SizedBox(height: 8),
        const Text('Tip: Ultrasonic mode in Settings is almost silent. The code changes every 10 seconds, '
            'so a code sent to a friend outside stops working quickly.'),
        statusBox(),
        startStop('Start class', _start),
        if (c != null) ...[
          const SizedBox(height: 12),
          for (final w in c.problems) Text('⚠ $w', style: TextStyle(color: bad)),
          for (final a in c.present.reversed)
            ListTile(leading: const Icon(Icons.person), title: Text(a.name), subtitle: Text(fingerprintOf(bytesFromHex(a.key)))),
        ],
        if (deps.store.classes.isNotEmpty) ...[
          const Divider(height: 32),
          Text('Past classes', style: Theme.of(context).textTheme.titleSmall),
          for (final k in deps.store.classes)
            ListTile(
              title: Text('${k['title']} · ${k['count']} present'),
              subtitle: Text(DateTime.fromMillisecondsSinceEpoch((k['time'] as int) * 1000).toString().substring(0, 16)),
              trailing: IconButton(
                tooltip: 'Copy list (CSV)',
                icon: const Icon(Icons.copy),
                onPressed: () => copyText(context, k['csv'] as String, 'Attendance list'),
              ),
            ),
        ],
      ]),
    );
  }
}

// ---------------------------------------------------------------- tickets

class TicketsPage extends FlowPage {
  const TicketsPage({super.key, required super.deps});
  @override
  State<TicketsPage> createState() => _TicketsState();
}

class _TicketsState extends FlowState<TicketsPage> {
  void _get() async {
    final name = await askText(context, 'Get a ticket', 'Name on the ticket', initial: _myName(deps));
    if (name == null || name.isEmpty) return;
    run(() async {
      for (var attempt = 1; attempt <= 4 && !cancelled; attempt++) {
        set('Asking the organizer for a ticket…', i: Icons.volume_up);
        await say(await askPacket(name, deps.me));
        final r = await hear({PacketType.ticket}, const Duration(seconds: 8));
        if (r == null) continue;
        try {
          final (t, org) = await readIssue(r.packet!, deps.me);
          await deps.store.addTicket(HeldTicket(t, hexOf(org), t.label));
          return set('Got ticket #${t.number} "${t.label}"', i: Icons.confirmation_number, c: Colors.green);
        } on AccessError {
          continue;
        } on PacketError {
          continue;
        }
      }
      set('No ticket received. Is the organizer giving out tickets?', i: Icons.info_outline);
    });
  }

  void _show() => run(() async {
        set('Hold your phone near the gate…', i: Icons.hearing);
        final r = await hear({PacketType.ticket}, const Duration(minutes: 1));
        if (r == null) return set('Gate not heard', i: Icons.hearing_disabled);
        final (event, nonce, gatePub) = readGate(r.packet!);
        final held = deps.store.tickets.where((t) => t.ticket.event == event && t.organizer == hexOf(gatePub)).toList();
        if (held.isEmpty) return set('You have no ticket for this event', i: Icons.block, c: bad);
        set('Showing ticket #${held.first.ticket.number}…', i: Icons.volume_up);
        await say(await showPacket(nonce, held.first.ticket, deps.me));
        final res = await hear({PacketType.ticket}, const Duration(seconds: 8));
        if (res == null) return set('The gate did not answer. Try again.', i: Icons.info_outline);
        final (status, _) = readResult(res.packet!, nonce, gatePub);
        set(ticketStatus[status] ?? 'unknown', i: status == ticketOk ? Icons.check_circle : Icons.cancel,
            c: status == ticketOk ? Colors.green : bad);
      });

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('My tickets'), actions: [FallbackButton(store: deps.app)]),
        body: ListenableBuilder(
          listenable: deps.store,
          builder: (context, _) => ListView(padding: const EdgeInsets.all(16), children: [
            Row(children: [
              Expanded(child: FilledButton.tonalIcon(onPressed: running ? null : _get, icon: const Icon(Icons.download), label: const Text('Get ticket'))),
              const SizedBox(width: 12),
              Expanded(
                  child: FilledButton.icon(
                      onPressed: running || deps.store.tickets.isEmpty ? null : _show,
                      icon: const Icon(Icons.qr_code_2),
                      label: const Text('Show at gate'))),
            ]),
            if (running) Padding(padding: const EdgeInsets.only(top: 8), child: OutlinedButton(onPressed: stop, child: const Text('Stop'))),
            if (status.isNotEmpty) statusBox(),
            const SizedBox(height: 12),
            if (deps.store.tickets.isEmpty) const Text('No tickets yet.'),
            for (final t in deps.store.tickets)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.confirmation_number),
                  title: Text('#${t.ticket.number} · ${t.ticket.label}'),
                  subtitle: Text('Valid till ${DateTime.fromMillisecondsSinceEpoch(t.ticket.validUntil * 1000).toString().substring(0, 16)}\n'
                      'Only works on this phone'),
                  isThreeLine: true,
                  trailing: IconButton(
                    tooltip: 'Delete',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () async {
                      if (await confirm(context, 'Delete ticket?', 'You cannot get it back without the organizer.')) {
                        deps.store.tickets.remove(t);
                        await deps.store.save();
                      }
                    },
                  ),
                ),
              ),
          ]),
        ),
      );
}

class OrganizerPage extends FlowPage {
  const OrganizerPage({super.key, required super.deps});
  @override
  State<OrganizerPage> createState() => _OrganizerState();
}

class _OrganizerState extends FlowState<OrganizerPage> {
  final name = TextEditingController();
  int hours = 6;
  int admitted = 0, refused = 0;

  Event? get ev => deps.store.event;

  Future<void> _create() async {
    if (name.text.trim().isEmpty) return showSnack(context, 'Enter the event name');
    deps.store.event = Event(name.text.trim(), unixNow() + hours * 3600);
    await deps.store.save();
    setState(() {});
  }

  void _issue() => run(() async {
        final e = ev!;
        while (!cancelled && mounted) {
          set('Giving out tickets… ${e.issued.length} issued\nPeople tap My tickets → Get ticket', i: Icons.hearing);
          final r = await hear({PacketType.ticket}, const Duration(seconds: 10));
          if (r == null) continue;
          try {
            final (t, issue) = await e.issue(r.packet!, deps.me);
            await deps.store.save();
            set('Ticket #${t.number} for ${t.label}', i: Icons.volume_up);
            await say(issue, repeat: 2);
          } on AccessError {
            // not an ask
          } on PacketError {
            // not an ask
          }
        }
        set('Stopped. ${e.issued.length} tickets issued.', i: Icons.check_circle);
      });

  void _gate() => run(() async {
        final e = ev!;
        while (!cancelled && mounted) {
          set('Gate open · $admitted in · $refused refused', i: Icons.volume_up);
          await say(await e.gate(deps.me));
          final r = await hear({PacketType.ticket}, const Duration(seconds: 6));
          if (r == null) continue;
          GateResult g;
          try {
            g = await e.check(r.packet!, deps.me);
          } on AccessError {
            continue;
          } on PacketError {
            continue;
          }
          await deps.store.save();
          final ok = g.status == ticketOk;
          ok ? admitted++ : refused++;
          set('${ok ? 'WELCOME' : 'STOP'}\n#${g.ticket.number} ${g.ticket.label}: ${ticketStatus[g.status]}',
              i: ok ? Icons.check_circle : Icons.cancel, c: ok ? Colors.green : bad);
          await say(g.result);
          await Future<void>.delayed(const Duration(seconds: 2));
        }
      });

  @override
  Widget build(BuildContext context) {
    final e = ev;
    return Scaffold(
      appBar: AppBar(title: Text(e == null ? 'Organize an event' : e.name), actions: [FallbackButton(store: deps.app)]),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        if (e == null) ...[
          TextField(controller: name, decoration: const InputDecoration(labelText: 'Event name', border: OutlineInputBorder())),
          const SizedBox(height: 12),
          DropdownButtonFormField<int>(
            initialValue: hours,
            decoration: const InputDecoration(labelText: 'Tickets valid for', border: OutlineInputBorder()),
            items: const [
              DropdownMenuItem(value: 3, child: Text('3 hours')),
              DropdownMenuItem(value: 6, child: Text('6 hours')),
              DropdownMenuItem(value: 24, child: Text('1 day')),
              DropdownMenuItem(value: 72, child: Text('3 days')),
            ],
            onChanged: (v) => hours = v ?? 6,
          ),
          const SizedBox(height: 12),
          FilledButton(onPressed: _create, child: const Text('Create event')),
          const SizedBox(height: 12),
          const Text('Tickets are signed by this phone and tied to each guest\'s phone, so a forwarded copy or '
              'screenshot does not work. The gate works offline.'),
        ] else ...[
          Text('${e.issued.length} issued · ${e.used.length} used · valid till '
              '${DateTime.fromMillisecondsSinceEpoch(e.validUntil * 1000).toString().substring(0, 16)}'),
          statusBox(),
          if (running)
            OutlinedButton.icon(onPressed: stop, icon: const Icon(Icons.stop), label: const Text('Stop'))
          else ...[
            FilledButton.tonalIcon(onPressed: _issue, icon: const Icon(Icons.outbox), label: const Text('Give out tickets')),
            const SizedBox(height: 8),
            FilledButton.icon(onPressed: _gate, icon: const Icon(Icons.door_front_door), label: const Text('Run the gate')),
            const SizedBox(height: 24),
            TextButton(
              onPressed: () async {
                if (await confirm(context, 'End this event?', 'Issued tickets will no longer be checked by this phone.')) {
                  deps.store.event = null;
                  await deps.store.save();
                  setState(() {});
                }
              },
              child: const Text('End event'),
            ),
          ],
          for (final x in e.issued.entries)
            ListTile(
              dense: true,
              leading: Icon(e.used.containsKey('${x.value['number']}') ? Icons.check : Icons.confirmation_number_outlined),
              title: Text('#${x.value['number']} ${x.value['label']}'),
            ),
        ],
      ]),
    );
  }
}

// ---------------------------------------------------------------- doors

class DoorKeyPage extends FlowPage {
  const DoorKeyPage({super.key, required super.deps});
  @override
  State<DoorKeyPage> createState() => _DoorKeyState();
}

class _DoorKeyState extends FlowState<DoorKeyPage> {
  void _unlock() => run(() async {
        set('Hold your phone near the door…', i: Icons.hearing);
        final r = await hear({PacketType.doorUnlock}, const Duration(minutes: 1));
        if (r == null) return set('Door not heard', i: Icons.hearing_disabled);
        final (nonce, name, doorPub) = readDoorChallenge(r.packet!);
        set('Door "$name": sending key…', i: Icons.volume_up);
        await say(await openPacket(nonce, doorPub, deps.me));
        final res = await hear({PacketType.doorUnlock}, const Duration(seconds: 8));
        if (res == null) return set('The door did not answer. Try again.', i: Icons.info_outline);
        final s = readDoorResult(res.packet!, nonce, doorPub);
        set('$name: ${doorStatus[s]}', i: s == doorOk ? Icons.lock_open : Icons.lock,
            c: s == doorOk ? Colors.green : bad);
      });

  void _join() async {
    final name = await askText(context, 'Ask to be added', 'Your name', initial: _myName(deps));
    if (name == null || name.isEmpty) return;
    run(() async {
      set('Hold your phone near the door…', i: Icons.hearing);
      final r = await hear({PacketType.doorUnlock}, const Duration(minutes: 1));
      if (r == null) return set('Door not heard', i: Icons.hearing_disabled);
      final (_, doorName, doorPub) = readDoorChallenge(r.packet!);
      set('Asking door "$doorName" to add you…', i: Icons.volume_up);
      await say(await enrollPacket(doorPub, name, deps.me), repeat: 2);
      deps.store.joinedDoors[hexOf(doorPub)] = doorName;
      await deps.store.save();
      set('Request sent. The door owner must tap Allow on the door phone.', i: Icons.person_add);
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Unlock a door'), actions: [FallbackButton(store: deps.app)]),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          statusBox(),
          if (running)
            OutlinedButton.icon(onPressed: stop, icon: const Icon(Icons.stop), label: const Text('Stop'))
          else ...[
            FilledButton.icon(onPressed: _unlock, icon: const Icon(Icons.lock_open), label: const Text('Unlock')),
            const SizedBox(height: 8),
            OutlinedButton.icon(onPressed: _join, icon: const Icon(Icons.person_add), label: const Text('Ask to be added to a door')),
          ],
          const SizedBox(height: 16),
          const Text('The door plays a fresh challenge each time and your phone signs it, '
              'so recording the sound and playing it later does not open the door.'),
          if (deps.store.joinedDoors.isNotEmpty) ...[
            const Divider(height: 32),
            for (final d in deps.store.joinedDoors.values) ListTile(leading: const Icon(Icons.sensor_door), title: Text(d)),
          ],
        ]),
      );
}

class DoorModePage extends FlowPage {
  const DoorModePage({super.key, required super.deps});
  @override
  State<DoorModePage> createState() => _DoorModeState();
}

class _DoorModeState extends FlowState<DoorModePage> {
  final name = TextEditingController();

  void _run() => run(() async {
        final d = deps.store.door!;
        while (!cancelled && mounted) {
          set('Door "${d.name}" is listening · ${d.allowed.length} allowed', i: Icons.sensor_door);
          await say(await d.challenge(deps.me));
          final r = await hear({PacketType.doorUnlock}, const Duration(seconds: 6));
          if (r == null) continue;
          final p = r.packet!;
          try {
            if (p.payload.isNotEmpty && p.payload[0] == doorEnrollKind) {
              final (pk, who) = await d.readEnroll(p, deps.me);
              if (!mounted) return;
              if (await confirm(context, 'Allow $who?', 'Phone ${fingerprintOf(pk)} wants to open "${d.name}".', yes: 'Allow', no: 'Ignore')) {
                d.allowed[hexOf(pk)] = who;
                await deps.store.save();
              }
              continue;
            }
            final (s, res) = await d.open(p, deps.me);
            await deps.store.save();
            set('${d.log.last.who}: ${doorStatus[s]}', i: s == doorOk ? Icons.lock_open : Icons.lock,
                c: s == doorOk ? Colors.green : bad);
            await say(res);
            await Future<void>.delayed(Duration(seconds: s == doorOk ? 3 : 1));
          } on AccessError {
            continue;
          } on PacketError {
            continue;
          }
        }
        set('Door stopped', i: Icons.sensor_door);
      });

  @override
  Widget build(BuildContext context) {
    final d = deps.store.door;
    return Scaffold(
      appBar: AppBar(title: Text(d == null ? 'Make this phone a door' : 'Door: ${d.name}'), actions: [FallbackButton(store: deps.app)]),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        if (d == null) ...[
          TextField(controller: name, decoration: const InputDecoration(labelText: 'Door name (e.g. Lab 3)', border: OutlineInputBorder())),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: () async {
              if (name.text.trim().isEmpty) return;
              deps.store.door = Door(name.text.trim());
              await deps.store.save();
              setState(() {});
            },
            child: const Text('Create door'),
          ),
          const SizedBox(height: 12),
          const Text('Demo: the phone shows "opened" instead of moving a real lock. An ESP32 lock comes in a later phase.'),
        ] else ...[
          statusBox(),
          startStop('Start door', _run),
          const Divider(height: 32),
          Text('Allowed phones', style: Theme.of(context).textTheme.titleSmall),
          if (d.allowed.isEmpty) const Text('None yet. People tap "Ask to be added to a door" near this phone.'),
          for (final e in d.allowed.entries)
            ListTile(
              leading: const Icon(Icons.person),
              title: Text(e.value),
              subtitle: Text(fingerprintOf(bytesFromHex(e.key))),
              trailing: IconButton(
                tooltip: 'Remove',
                icon: const Icon(Icons.person_remove),
                onPressed: () async {
                  d.allowed.remove(e.key);
                  await deps.store.save();
                  setState(() {});
                },
              ),
            ),
          const Divider(height: 32),
          Text('Recent', style: Theme.of(context).textTheme.titleSmall),
          for (final l in d.log.reversed.take(15))
            ListTile(
              dense: true,
              leading: Icon(l.status == doorOk ? Icons.lock_open : Icons.lock),
              title: Text('${l.who}: ${doorStatus[l.status]}'),
              subtitle: Text(DateTime.fromMillisecondsSinceEpoch(l.time * 1000).toString().substring(0, 19)),
            ),
          if (!running)
            TextButton(
              onPressed: () async {
                if (await confirm(context, 'Remove this door?', 'All allowed phones will be forgotten.')) {
                  deps.store.door = null;
                  await deps.store.save();
                  setState(() {});
                }
              },
              child: const Text('Remove door'),
            ),
        ],
      ]),
    );
  }
}

// ---------------------------------------------------------------- login

class LoginPage extends FlowPage {
  const LoginPage({super.key, required super.deps});
  @override
  State<LoginPage> createState() => _LoginState();
}

class _LoginState extends FlowState<LoginPage> {
  void _listen() => run(() async {
        set('Press "Log in with SoundLink" on the website and hold the phone near the laptop…', i: Icons.hearing);
        final r = await hear({PacketType.authChallenge}, const Duration(minutes: 1));
        if (r == null) return set('No login heard', i: Icons.hearing_disabled);
        final ch = readAuthChallenge(r.packet!);
        if (unixNow() > ch.expires) return set('That login has expired. Start again on the website.', i: Icons.timer_off);
        final uri = Uri.tryParse(ch.url);
        if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) {
          return set('The login has a bad address, ignored.', i: Icons.block);
        }
        if (!mounted) return;
        final ok = await confirm(
          context,
          'Log in as "${ch.user}"?',
          'Website: ${ch.site}\nServer: ${uri.host}${uri.hasPort ? ':${uri.port}' : ''}\nSite ID: ${fingerprintOf(ch.sitePub)}\n\n'
              'Only approve if you just pressed login on that screen.',
          yes: 'Approve',
          no: 'Deny',
        );
        final resp = await authResponsePacket(ch, ok, deps.me);
        set('Sending your answer to the website…', i: Icons.cloud_upload);
        http.Response res;
        try {
          res = await http
              .post(uri, headers: {'Content-Type': 'application/json'}, body: jsonEncode({'response': hexOf(resp)}))
              .timeout(const Duration(seconds: 15));
        } catch (_) {
          return set('Could not reach ${uri.host}. The phone needs internet or the same Wi-Fi as the website.',
              i: Icons.wifi_off, c: bad);
        }
        String detail = '';
        try {
          detail = (jsonDecode(res.body) as Map)['detail']?.toString() ?? '';
        } catch (_) {}
        if (res.statusCode == 200) {
          set(ok ? 'Approved. The website is now logged in as ${ch.user}.' : 'Denied.',
              i: ok ? Icons.check_circle : Icons.block, c: ok ? Colors.green : null);
        } else {
          set('Website refused: ${detail.isEmpty ? res.statusCode : detail}', i: Icons.error_outline, c: bad);
        }
      });

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Log in to a website'), actions: [FallbackButton(store: deps.app)]),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          statusBox(),
          startStop('Listen for login', _listen),
          const SizedBox(height: 16),
          const Text('Try it: run "python -m soundbank serve" on a laptop and open http://<laptop-ip>:8000/site in its browser. '
              'Your device key is your login: the first phone that approves a username is linked to it.'),
        ]),
      );
}
