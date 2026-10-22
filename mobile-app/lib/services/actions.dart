/// What to do with a received contact / Wi-Fi / offer.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_contacts/flutter_contacts.dart' as fc;
import 'package:share_plus/share_plus.dart';
import 'package:wifi_iot/wifi_iot.dart';

import '../engine/engine.dart';
import 'files.dart';

void showSnack(BuildContext context, String text) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));
}

Future<void> copyText(BuildContext context, String text, String what) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (context.mounted) showSnack(context, '$what copied');
}

/// Opens the phone's "new contact" screen pre-filled. The user taps Save,
/// so the app does not need permission to read or write all contacts.
Future<void> saveContact(BuildContext context, Contact c) async {
  final parts = c.name.trim().split(RegExp(r'\s+'));
  final contact = fc.Contact(
    displayName: c.name,
    name: fc.Name(first: parts.first, last: parts.length > 1 ? parts.sublist(1).join(' ') : null),
    phones: [if (c.phone.isNotEmpty) fc.Phone(number: c.phone)],
    emails: [if (c.email.isNotEmpty) fc.Email(address: c.email)],
    organizations: [if (c.org.isNotEmpty || c.title.isNotEmpty) fc.Organization(name: c.org, jobTitle: c.title)],
    websites: [if (c.url.isNotEmpty) fc.Website(url: c.url)],
    notes: [if (c.note.isNotEmpty) fc.Note(note: c.note)],
  );
  try {
    await fc.FlutterContacts.native.showCreator(contact: contact);
  } catch (e) {
    if (context.mounted) {
      await copyText(context, c.toVcard(), 'Could not open contacts. Contact card');
    }
  }
}

/// Asks Android to add the network (the system shows a "Save network?" prompt).
Future<void> connectWifi(BuildContext context, Wifi w) async {
  final security = switch (w.security) {
    WifiSecurity.open => NetworkSecurity.NONE,
    WifiSecurity.wep => NetworkSecurity.WEP,
    _ => NetworkSecurity.WPA,
  };
  var ok = false;
  try {
    ok = await WiFiForIoTPlugin.registerWifiNetwork(
      w.ssid,
      password: w.password.isEmpty ? null : w.password,
      security: security,
      isHidden: w.hidden,
    );
  } catch (_) {
    ok = false;
  }
  if (!context.mounted) return;
  if (ok) {
    showSnack(context, 'Sent "${w.ssid}" to Wi-Fi settings');
  } else if (w.password.isNotEmpty) {
    await copyText(context, w.password, 'Could not add the network automatically. Password');
  } else {
    showSnack(context, 'Could not add the network automatically');
  }
}

/// Download / unpack, check and save a received file, then offer to open or share it.
Future<void> saveFile(BuildContext context, FileOffer offer) async {
  showSnack(context, offer.mode == fileInline ? 'Saving…' : 'Downloading ${offer.name}…');
  try {
    final f = await saveOffer(offer);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text('Saved ${f.uri.pathSegments.last} (checksum OK)'),
        action: SnackBarAction(
          label: 'Open / share',
          onPressed: () => SharePlus.instance.share(ShareParams(files: [XFile(f.path, mimeType: offer.mime)])),
        ),
      ));
  } catch (e) {
    if (context.mounted) showSnack(context, 'Could not save: $e');
  }
}
