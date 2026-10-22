import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../engine/engine.dart';
import 'package:file_picker/file_picker.dart';

import '../services/actions.dart';
import '../services/fallback.dart';
import 'fallback_screens.dart';
import '../services/files.dart';
import '../services/audio.dart';
import '../services/store.dart';

/// Shared "build packet -> play it" logic for every send form.
class Sender {
  final AppStore store;
  final SoundPlayer player;
  final SoundListener listener;
  Sender(this.store, this.player, this.listener);

  /// Returns the air time in seconds.
  Future<double> send(int type, List<int> payload, {String pin = ''}) async {
    // Our own mic would hear us and we can't play and listen well at once.
    if (listener.listening) await listener.stop();
    final key = pin.isEmpty ? null : await keyFromPin(pin);
    final link = SoundLink(store.profile, identity: store.identity, key: key, volume: store.volume);
    final raw = await Packet(type, payload).toBytes(signWith: store.identity, key: key);
    final audio = link.encodeBytes(raw, repeat: store.repeat);
    FallbackHub.instance.remember(raw);
    await store.addHistory(HistoryItem(
      sent: true,
      type: type,
      payload: Uint8List.fromList(payload),
      time: DateTime.now(),
      profile: store.profileName,
    ));
    await player.play(audio, link.sampleRate);
    return audio.length / link.sampleRate;
  }
}

class SendScreen extends StatelessWidget {
  final Sender sender;
  const SendScreen({super.key, required this.sender});

  @override
  Widget build(BuildContext context) {
    Widget tile(IconData icon, String title, String sub, Widget Function() page) => Card(
          child: ListTile(
            leading: Icon(icon, size: 32),
            title: Text(title),
            subtitle: Text(sub),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => page())),
          ),
        );
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        tile(Icons.person, 'Contact card', 'Share your name, number and email', () => ContactForm(sender: sender)),
        tile(Icons.wifi, 'Wi-Fi network', 'Let guests join without typing the password', () => WifiForm(sender: sender)),
        tile(Icons.local_offer, 'Offer / coupon', 'Shops: send a deal to nearby phones', () => OfferForm(sender: sender)),
        tile(Icons.chat_bubble_outline, 'Text message', 'Any short text', () => TextForm(sender: sender)),
        tile(Icons.insert_drive_file, 'File', 'Photo, PDF… small files go by sound, big ones over Wi-Fi', () => FileForm(sender: sender)),
        tile(Icons.campaign, 'Emergency alert', 'Broadcast a warning to every phone in range', () => AlertForm(sender: sender)),
      ],
    );
  }
}

/// Common page layout: form fields + PIN option + send button with status.
class _SendPage extends StatefulWidget {
  final String title;
  final Sender sender;
  final List<Widget> Function(void Function()) fields;
  final (int, List<int>) Function() build;
  final bool pinByDefault;
  final String? pinHint;
  final void Function()? onSent;
  final bool allowPin;

  const _SendPage({
    required this.title,
    required this.sender,
    required this.fields,
    required this.build,
    this.pinByDefault = false,
    this.pinHint,
    this.onSent,
    this.allowPin = true,
  });

  @override
  State<_SendPage> createState() => _SendPageState();
}

class _SendPageState extends State<_SendPage> {
  final _form = GlobalKey<FormState>();
  final _pin = TextEditingController();
  late bool _usePin = widget.pinByDefault;
  bool _busy = false;
  String? _status;

  Future<void> _send() async {
    if (!_form.currentState!.validate()) return;
    final (int, List<int>) packet;
    try {
      packet = widget.build();
    } on ArgumentError catch (e) {
      showSnack(context, e.message.toString());
      return;
    }
    setState(() {
      _busy = true;
      _status = 'Playing… keep the phones close';
    });
    try {
      final secs = await widget.sender.send(packet.$1, packet.$2, pin: _usePin ? _pin.text : '');
      widget.onSent?.call();
      _status = 'Sent (${secs.toStringAsFixed(1)} s of sound)';
    } catch (e) {
      _status = 'Could not play: $e';
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.sender.store;
    return Scaffold(
      appBar: AppBar(title: Text(widget.title), actions: [FallbackButton(store: widget.sender.store)]),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            ...widget.fields(() => setState(() {})),
            const SizedBox(height: 8),
            if (widget.allowPin) SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Lock with a PIN'),
              subtitle: Text(widget.pinHint ?? 'Only people you tell the PIN can open it'),
              value: _usePin,
              onChanged: (v) => setState(() => _usePin = v),
            ),
            if (_usePin)
              TextFormField(
                controller: _pin,
                obscureText: true,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'PIN', border: OutlineInputBorder()),
                validator: (v) => (v == null || v.length < 4) ? 'Use at least 4 digits' : null,
              ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _busy ? null : _send,
              icon: _busy
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.volume_up),
              label: Text(_busy ? 'Sending…' : 'Send by sound'),
            ),
            if (_status != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_status!, textAlign: TextAlign.center)),
            const SizedBox(height: 8),
            Text(
              'Mode: ${store.profile.label} · volume ${(store.volume * 100).round()}% · plays ${store.repeat}x',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

Widget _field(TextEditingController c, String label,
        {bool required = false, TextInputType? type, int maxLines = 1, String? Function(String?)? validator}) =>
    Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        controller: c,
        keyboardType: type,
        maxLines: maxLines,
        decoration: InputDecoration(labelText: required ? '$label *' : label, border: const OutlineInputBorder()),
        validator: validator ?? (required ? (v) => (v == null || v.trim().isEmpty) ? '$label is required' : null : null),
      ),
    );

class ContactForm extends StatefulWidget {
  final Sender sender;
  const ContactForm({super.key, required this.sender});
  @override
  State<ContactForm> createState() => _ContactFormState();
}

class _ContactFormState extends State<ContactForm> {
  late final Contact? card = widget.sender.store.myCard;
  late final name = TextEditingController(text: card?.name);
  late final phone = TextEditingController(text: card?.phone);
  late final email = TextEditingController(text: card?.email);
  late final org = TextEditingController(text: card?.org);
  late final title = TextEditingController(text: card?.title);
  bool remember = true;

  Contact get _contact => Contact(
        name: name.text.trim(),
        phone: phone.text.trim(),
        email: email.text.trim(),
        org: org.text.trim(),
        title: title.text.trim(),
      );

  @override
  Widget build(BuildContext context) => _SendPage(
        title: 'Share contact',
        sender: widget.sender,
        fields: (refresh) => [
          _field(name, 'Name', required: true),
          _field(phone, 'Phone', type: TextInputType.phone),
          _field(email, 'Email', type: TextInputType.emailAddress),
          _field(org, 'Company / college'),
          _field(title, 'Job title'),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Remember as my card'),
            value: remember,
            onChanged: (v) => setState(() => remember = v ?? false),
          ),
        ],
        build: () => (PacketType.contact, _contact.toBytes()),
        onSent: () {
          if (remember) widget.sender.store.myCard = _contact;
        },
      );
}

class WifiForm extends StatefulWidget {
  final Sender sender;
  const WifiForm({super.key, required this.sender});
  @override
  State<WifiForm> createState() => _WifiFormState();
}

class _WifiFormState extends State<WifiForm> {
  final ssid = TextEditingController();
  final password = TextEditingController();
  WifiSecurity security = WifiSecurity.wpa;
  bool hidden = false;

  @override
  Widget build(BuildContext context) => _SendPage(
        title: 'Share Wi-Fi',
        sender: widget.sender,
        pinByDefault: true,
        pinHint: 'Recommended: anyone nearby could record the sound',
        fields: (refresh) => [
          _field(ssid, 'Network name (SSID)', required: true,
              validator: (v) => (v == null || v.isEmpty) ? 'Network name is required' : (v.length > 32 ? 'Max 32 characters' : null)),
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: DropdownButtonFormField<WifiSecurity>(
              initialValue: security,
              decoration: const InputDecoration(labelText: 'Security', border: OutlineInputBorder()),
              items: [for (final s in WifiSecurity.values) DropdownMenuItem(value: s, child: Text(s.label))],
              onChanged: (v) => setState(() => security = v ?? WifiSecurity.wpa),
            ),
          ),
          if (security != WifiSecurity.open)
            _field(password, 'Password', required: true,
                validator: (v) => (v == null || v.isEmpty) ? 'Password is required' : null),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Hidden network'),
            value: hidden,
            onChanged: (v) => setState(() => hidden = v),
          ),
        ],
        build: () => (
          PacketType.wifi,
          Wifi(ssid.text, password: security == WifiSecurity.open ? '' : password.text, security: security, hidden: hidden).toBytes(),
        ),
      );
}

class OfferForm extends StatefulWidget {
  final Sender sender;
  const OfferForm({super.key, required this.sender});
  @override
  State<OfferForm> createState() => _OfferFormState();
}

class _OfferFormState extends State<OfferForm> {
  final title = TextEditingController();
  final shop = TextEditingController();
  final details = TextEditingController();
  final code = TextEditingController();
  int days = 7;

  @override
  Widget build(BuildContext context) => _SendPage(
        title: 'Send offer',
        sender: widget.sender,
        fields: (refresh) => [
          _field(title, 'Offer (e.g. 20% off)', required: true),
          _field(shop, 'Shop name'),
          _field(details, 'Details', maxLines: 3),
          _field(code, 'Coupon code'),
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: DropdownButtonFormField<int>(
              initialValue: days,
              decoration: const InputDecoration(labelText: 'Valid for', border: OutlineInputBorder()),
              items: const [
                DropdownMenuItem(value: 1, child: Text('1 day')),
                DropdownMenuItem(value: 7, child: Text('1 week')),
                DropdownMenuItem(value: 30, child: Text('1 month')),
                DropdownMenuItem(value: 0, child: Text('No end date')),
              ],
              onChanged: (v) => setState(() => days = v ?? 7),
            ),
          ),
        ],
        build: () => (
          PacketType.offer,
          Offer(
            title.text,
            shop: shop.text,
            details: details.text,
            code: code.text,
            expires: days == 0 ? 0 : unixNow() + days * 86400,
          ).toBytes(),
        ),
      );
}

class TextForm extends StatefulWidget {
  final Sender sender;
  const TextForm({super.key, required this.sender});
  @override
  State<TextForm> createState() => _TextFormState();
}

class _TextFormState extends State<TextForm> {
  final text = TextEditingController();

  @override
  Widget build(BuildContext context) => _SendPage(
        title: 'Send text',
        sender: widget.sender,
        fields: (refresh) => [_field(text, 'Message', required: true, maxLines: 4)],
        build: () => (PacketType.text, utf8.encode(text.text)),
      );
}

class AlertForm extends StatefulWidget {
  final Sender sender;
  const AlertForm({super.key, required this.sender});
  @override
  State<AlertForm> createState() => _AlertFormState();
}

class _AlertFormState extends State<AlertForm> {
  final title = TextEditingController();
  final message = TextEditingController();
  final area = TextEditingController();
  int severity = 1, kind = 0, hours = 6;

  Widget _drop<T>(String label, T value, Map<T, String> items, void Function(T) on) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: DropdownButtonFormField<T>(
          initialValue: value,
          decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
          items: [for (final e in items.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
          onChanged: (v) => setState(() => on(v as T)),
        ),
      );

  @override
  Widget build(BuildContext context) => _SendPage(
        title: 'Emergency alert',
        sender: widget.sender,
        allowPin: false,
        fields: (refresh) => [
          const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: Text('Signed with this phone\'s key. Receivers see "VERIFIED" only if they trust your device ID '
                '(Settings shows it). Tip: play it through a loudspeaker or radio for a whole area.'),
          ),
          _field(title, 'Title (e.g. Flood warning)', required: true),
          _field(message, 'What should people do?', maxLines: 4,
              validator: (v) => (v != null && utf8.encode(v.trim()).length > messageMax) ? 'Too long' : null),
          _field(area, 'Area (e.g. Ward 12)'),
          _drop('Type', kind, alertKinds, (v) => kind = v),
          _drop('Severity', severity, severityNames, (v) => severity = v),
          _drop('Ends after', hours, const {1: '1 hour', 6: '6 hours', 24: '1 day', 0: 'No end'}, (v) => hours = v),
        ],
        build: () => (
          PacketType.emergency,
          Alert(title.text, message: message.text, severity: severity, kind: kind, area: area.text,
                  expires: hours == 0 ? 0 : unixNow() + hours * 3600)
              .toBytes(),
        ),
      );
}

class FileForm extends StatefulWidget {
  final Sender sender;
  const FileForm({super.key, required this.sender});
  @override
  State<FileForm> createState() => _FileFormState();
}

class _FileFormState extends State<FileForm> {
  String? name;
  Uint8List? data;
  FileShare? share;
  String status = '';
  bool busy = false;

  /// Biggest file that goes inside the sound for the current mode.
  int get inlineLimit => widget.sender.store.profile.isOfdm ? inlineMax : 1500;

  Future<void> _pick() async {
    final f = await FilePicker.pickFile();
    if (f == null) return;
    final bytes = await f.readAsBytes();
    if (bytes.length > maxDownload) {
      if (mounted) showSnack(context, 'File is too big (max 200 MB)');
      return;
    }
    setState(() {
      name = f.name;
      data = bytes;
      status = '';
    });
  }

  Future<void> _send() async {
    final d = data!, n = name!;
    setState(() => busy = true);
    try {
      FileOffer offer;
      if (d.length <= inlineLimit) {
        offer = await FileOffer.inline(n, d, mime: mimeOf(n));
        setState(() => status = 'Sending the file inside the sound…');
      } else {
        await share?.stop();
        final s = share = await FileShare.start(n, d);
        offer = await s.offer(mimeOf(n));
        setState(() => status = 'Sharing on ${s.host}. Playing the link…');
      }
      final secs = await widget.sender.send(PacketType.fileHandshake, offer.toBytes());
      setState(() => status = offer.mode == fileInline
          ? 'Sent (${secs.toStringAsFixed(1)} s of sound)'
          : 'Link sent. Keep this page open while they download (same Wi-Fi). ${share!.downloads} download(s) so far.');
    } catch (e) {
      setState(() => status = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    share?.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = data;
    return Scaffold(
      appBar: AppBar(title: const Text('Send a file')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        OutlinedButton.icon(onPressed: busy ? null : _pick, icon: const Icon(Icons.attach_file), label: Text(name ?? 'Choose a file')),
        if (d != null) ...[
          const SizedBox(height: 8),
          Text('${(d.length / 1024).toStringAsFixed(1)} KB ? '
              '${d.length <= inlineLimit ? 'goes inside the sound' : 'link by sound, file over Wi-Fi'}'),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: busy ? null : _send,
            icon: busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.volume_up),
            label: const Text('Send by sound'),
          ),
        ],
        if (status.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 16), child: Text(status, textAlign: TextAlign.center)),
        const SizedBox(height: 16),
        Text('Up to ${(inlineLimit / 1024).toStringAsFixed(1)} KB goes inside the sound in this mode '
            '(Turbo mode in Settings allows ${(inlineMax / 1024).toStringAsFixed(1)} KB). Bigger files are served from '
            'this phone over the local Wi-Fi and checked with a checksum on arrival.'),
      ]),
    );
  }
}
