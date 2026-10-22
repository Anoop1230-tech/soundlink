import 'package:flutter/material.dart';

import '../engine/engine.dart';
import '../services/actions.dart';
import '../services/store.dart';

IconData iconFor(int type) => switch (type) {
      PacketType.contact => Icons.person,
      PacketType.wifi => Icons.wifi,
      PacketType.offer => Icons.local_offer,
      PacketType.text => Icons.chat_bubble_outline,
      PacketType.emergency => Icons.warning_amber,
      PacketType.sensor => Icons.monitor_heart,
      PacketType.fileHandshake => Icons.insert_drive_file,
      _ => Icons.help_outline,
    };

String _when(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inSeconds < 60) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  if (d.inHours < 24) return '${d.inHours} h ago';
  return '${t.day}/${t.month}/${t.year}';
}

/// Shows one received or sent item with the right buttons for its type.
class ItemCard extends StatelessWidget {
  final int type;
  final Object? item;
  final String? signer;
  final DateTime time;
  final bool sent;

  /// For alerts: is the signer in the trusted list, and how to add it.
  final bool trusted;
  final VoidCallback? onTrust;

  const ItemCard({
    super.key,
    required this.type,
    required this.item,
    this.signer,
    required this.time,
    this.sent = false,
    this.trusted = false,
    this.onTrust,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (title, lines, actions) = _content(context);
    final who = sent ? 'Sent' : (signer == null ? 'Unsigned sender' : 'From ${fingerprintOf(bytesFromHex(signer!))}');
    final i = item;
    final danger = i is Alert && i.severity == 2;
    return Card(
      color: i is Alert && !sent ? (danger ? theme.colorScheme.errorContainer : theme.colorScheme.tertiaryContainer) : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(iconFor(type), color: theme.colorScheme.primary),
              const SizedBox(width: 12),
              Expanded(child: Text(title, style: theme.textTheme.titleMedium)),
            ]),
            const SizedBox(height: 6),
            for (final l in lines) Padding(padding: const EdgeInsets.only(left: 36, top: 2), child: SelectableText(l)),
            Padding(
              padding: const EdgeInsets.only(left: 36, top: 6),
              child: Text('$who · ${_when(time)}', style: theme.textTheme.bodySmall),
            ),
            if (actions.isNotEmpty) Wrap(alignment: WrapAlignment.end, children: actions),
          ],
        ),
      ),
    );
  }

  (String, List<String>, List<Widget>) _content(BuildContext context) {
    final i = item;
    if (i is Contact) {
      return (
        i.name,
        [
          if (i.phone.isNotEmpty) i.phone,
          if (i.email.isNotEmpty) i.email,
          if (i.org.isNotEmpty || i.title.isNotEmpty) [i.title, i.org].where((s) => s.isNotEmpty).join(', '),
          if (i.url.isNotEmpty) i.url,
          if (i.note.isNotEmpty) i.note,
        ],
        [
          if (!sent) TextButton.icon(onPressed: () => saveContact(context, i), icon: const Icon(Icons.person_add), label: const Text('Save')),
          if (i.phone.isNotEmpty)
            TextButton.icon(onPressed: () => copyText(context, i.phone, 'Number'), icon: const Icon(Icons.copy), label: const Text('Number')),
        ],
      );
    }
    if (i is Wifi) {
      return (
        i.ssid,
        [i.security.label + (i.hidden ? ' · hidden network' : ''), if (i.password.isNotEmpty) 'Password: ${'•' * i.password.length.clamp(4, 12)}'],
        [
          if (!sent) TextButton.icon(onPressed: () => connectWifi(context, i), icon: const Icon(Icons.wifi), label: const Text('Connect')),
          if (i.password.isNotEmpty)
            TextButton.icon(onPressed: () => copyText(context, i.password, 'Password'), icon: const Icon(Icons.copy), label: const Text('Password')),
        ],
      );
    }
    if (i is Offer) {
      final exp = i.expires == 0 ? null : DateTime.fromMillisecondsSinceEpoch(i.expires * 1000);
      return (
        i.title,
        [
          if (i.shop.isNotEmpty) i.shop,
          if (i.details.isNotEmpty) i.details,
          if (i.code.isNotEmpty) 'Code: ${i.code}',
          if (i.url.isNotEmpty) i.url,
          if (exp != null) i.expired() ? 'Expired' : 'Valid till ${exp.day}/${exp.month}/${exp.year}',
        ],
        [
          if (i.code.isNotEmpty)
            TextButton.icon(onPressed: () => copyText(context, i.code, 'Code'), icon: const Icon(Icons.copy), label: const Text('Code')),
        ],
      );
    }
    if (i is Alert) {
      final exp = i.expires == 0 ? null : DateTime.fromMillisecondsSinceEpoch(i.expires * 1000);
      final verified = sent || trusted;
      return (
        '${severityNames[i.severity]}: ${i.title}',
        [
          '${alertKinds[i.kind]}${i.area.isEmpty ? '' : ' ? ${i.area}'}',
          if (i.message.isNotEmpty) i.message,
          if (exp != null) i.expired() ? 'This alert has ended' : 'Until ${exp.toLocal().toString().substring(0, 16)}',
          if (!sent) verified ? '✔ VERIFIED: from a trusted authority' : '⚠ NOT VERIFIED: anyone can play a sound. Check with officials.',
        ],
        [
          if (!sent && !trusted && signer != null && onTrust != null)
            TextButton.icon(onPressed: onTrust, icon: const Icon(Icons.verified_user), label: const Text('Trust sender')),
          TextButton.icon(
              onPressed: () => copyText(context, '${i.title}\n${i.message}', 'Alert'), icon: const Icon(Icons.copy), label: const Text('Copy')),
        ],
      );
    }
    if (i is SensorReport) {
      return ('${i.name} (reading #${i.seq})', i.describe(), const <Widget>[]);
    }
    if (i is FileOffer) {
      final kb = i.size < 1024 ? '${i.size} bytes' : '${(i.size / 1024).toStringAsFixed(1)} KB';
      return (
        i.name,
        [kb, i.mode == fileInline ? 'Sent inside the sound' : 'Download over Wi-Fi from ${Uri.parse(i.url).host}'],
        [if (!sent) TextButton.icon(onPressed: () => saveFile(context, i), icon: const Icon(Icons.download), label: const Text('Save'))],
      );
    }
    if (i is String) {
      return ('Message', [i], [TextButton.icon(onPressed: () => copyText(context, i, 'Text'), icon: const Icon(Icons.copy), label: const Text('Copy'))]);
    }
    return (PacketType.name(type), ['This app version cannot open this type yet.'], const []);
  }
}

Future<String?> askPin(BuildContext context, {String title = 'Enter PIN'}) {
  final ctrl = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        obscureText: true,
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(labelText: 'PIN from the sender'),
        onSubmitted: (v) => Navigator.pop(ctx, v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('Open')),
      ],
    ),
  );
}

/// Ask for a name and add the signer to the trusted alert senders.
Future<void> trustSender(BuildContext context, AppStore store, String keyHex) async {
  final c = TextEditingController();
  final name = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Trust this sender?'),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Device ${fingerprintOf(bytesFromHex(keyHex))}\nOnly do this if you know it is an official source '
            '(e.g. the ID was shown by your college or the district office).'),
        TextField(controller: c, autofocus: true, decoration: const InputDecoration(labelText: 'Name, e.g. District Office')),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('Trust')),
      ],
    ),
  );
  if (name != null && name.isNotEmpty) await store.trust(keyHex, name);
}
