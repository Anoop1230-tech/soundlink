import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../engine/engine.dart';
import '../services/actions.dart';
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
    final audio = await link.encode(Packet(type, payload), repeat: store.repeat);
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

  const _SendPage({
    required this.title,
    required this.sender,
    required this.fields,
    required this.build,
    this.pinByDefault = false,
    this.pinHint,
    this.onSent,
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
      appBar: AppBar(title: Text(widget.title)),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            ...widget.fields(() => setState(() {})),
            const SizedBox(height: 8),
            SwitchListTile(
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
