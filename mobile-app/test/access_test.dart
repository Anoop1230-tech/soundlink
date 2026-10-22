// Attendance, tickets, door and login: checked against Python (vectors.json)
// and on their own.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soundlink/engine/engine.dart';

final all = jsonDecode(File('test/fixtures/vectors.json').readAsStringSync()) as Map<String, dynamic>;
final av = all['access'] as Map<String, dynamic>;
const now = 1800000000;

Future<Packet> P(List<int> raw) => Packet.fromBytes(raw);
Uint8List h(String s) => bytesFromHex(s);

void main() {
  late Identity phone, other;
  setUpAll(() async {
    phone = await Identity.fromSeed(h(all['identity']['seed']));
    other = await Identity.fromSeed(h(av['other_seed']));
  });

  group('matches Python', () {
    test('attendance: same code, same check-in, Python ack accepted', () async {
      final a = av['attendance'];
      final cls = ClassSession('DBMS lecture', session: a['session'], secret: h(a['secret']), started: now);
      expect(hexOf(await cls.code(a['window'])), a['code']);
      final b = readBeacon(await P(h(a['beacon'])));
      expect(b.title, 'DBMS lecture');
      final ci = await P(await checkInPacket(b, 'Anoop', phone));
      expect(hexOf(ci.payload), a['checkin_payload']);
      expect(await readAck(await P(h(a['ack'])), phone, b), 1);
      // Dart teacher accepts the same check-in
      final r = await cls.checkIn(ci, other, now: now);
      expect(r.isNew, isTrue);
    });

    test('tickets: same ask/show payloads, Python ticket and result read', () async {
      final t = av['ticket'];
      expect(hexOf((await P(await askPacket('Anoop', phone))).payload), t['ask_payload']);
      final (ticket, org) = await readIssue(await P(h(t['issue'])), phone);
      expect(hexOf(ticket.toBytes()), t['ticket']);
      expect(hexOf(org), av['other_pub']);
      final (event, nonce, gatePub) = readGate(await P(h(t['gate'])));
      expect(event, t['event']);
      expect(hexOf((await P(await showPacket(nonce, ticket, phone))).payload), t['show_payload']);
      expect(readResult(await P(h(t['result'])), nonce, gatePub), (ticketOk, 1));

      // Dart organizer signs exactly the same ticket as Python
      final ev = Event('Tech Fest', t['valid_until'], event: t['event']);
      final (mine, _) = await ev.issue(await P(await askPacket('Anoop', phone)), other);
      expect(hexOf(mine.toBytes()), t['ticket']);
    });

    test('door and login payloads', () async {
      final d = av['door'];
      final (nonce, name, doorPub) = readDoorChallenge(await P(h(d['challenge'])));
      expect(name, 'Lab 3');
      expect(hexOf((await P(await openPacket(nonce, doorPub, phone))).payload), d['open_payload']);
      expect(readDoorResult(await P(h(d['result'])), nonce, doorPub), doorOk);
      expect(hexOf((await P(await enrollPacket(doorPub, 'Anoop', phone))).payload), d['enroll_payload']);

      final a = av['auth'];
      final ch = readAuthChallenge(await P(h(a['challenge'])));
      expect(ch.user, 'anoop');
      expect(ch.url, 'http://192.168.1.10:8000/site/approve');
      expect(hexOf((await P(await authResponsePacket(ch, true, phone))).payload), a['response_payload']);
    });
  });

  group('rules', () {
    test('attendance: stale code, wrong code, csv', () async {
      final teacher = await Identity.generate(), student = await Identity.generate();
      final cls = ClassSession('Lab');
      final b = readBeacon(await P(await cls.beacon(teacher, now: now)));
      final ci = await P(await checkInPacket(b, 'Asha, "A"', student));
      await expectLater(cls.checkIn(ci, teacher, now: now + 40), throwsA(isA<AccessError>()));
      final r = await cls.checkIn(ci, teacher, now: now + 5);
      expect(await readAck(await P(r.ack), student, b), 1);
      expect(cls.csv(), contains('"Asha, ""A"""'));
      final fake = Beacon(b.session, b.window, Uint8List(8), b.title, b.teacher);
      await expectLater(cls.checkIn(await P(await checkInPacket(fake, 'X', student)), teacher, now: now),
          throwsA(predicate((e) => e is AccessError && e.message.contains('wrong code'))));
    });

    test('tickets: entry once, copied ticket, replay', () async {
      final org = await Identity.generate(), holder = await Identity.generate(), thief = await Identity.generate();
      final ev = Event('Fest', now + 3600);
      final (_, issue) = await ev.issue(await P(await askPacket('Me', holder)), org);
      final (t, _) = await readIssue(await P(issue), holder);
      Future<int> enter(Identity who) async {
        final (_, nonce, _) = readGate(await P(await ev.gate(org, now: now)));
        return (await ev.check(await P(await showPacket(nonce, t, who)), org, now: now)).status;
      }

      expect(await enter(thief), ticketInvalid);
      expect(await enter(holder), ticketOk);
      expect(await enter(holder), ticketUsed);
      final (_, nonce, _) = readGate(await P(await ev.gate(org, now: now)));
      final rec = await P(await showPacket(nonce, t, holder));
      await ev.check(rec, org, now: now);
      await expectLater(ev.check(rec, org, now: now), throwsA(isA<AccessError>()));
      final ev2 = Event.fromJson(jsonDecode(jsonEncode(ev.toJson())));
      expect(ev2.used, ev.used);
    });

    test('door: allowed, denied, replay, saved', () async {
      final doorId = await Identity.generate(), me = await Identity.generate(), stranger = await Identity.generate();
      final door = Door('Lab 3');
      final (pk, name) = await door.readEnroll(await P(await enrollPacket(doorId.publicKey, 'Anoop', me)), doorId);
      door.allowed[hexOf(pk)] = name;
      var (nonce, _, dpub) = readDoorChallenge(await P(await door.challenge(doorId, now: now)));
      final opener = await P(await openPacket(nonce, dpub, me));
      final (s1, res) = await door.open(opener, doorId, now: now + 1);
      expect(s1, doorOk);
      expect(readDoorResult(await P(res), nonce, dpub), doorOk);
      expect((await door.open(opener, doorId, now: now + 2)).$1, doorStale);
      (nonce, _, dpub) = readDoorChallenge(await P(await door.challenge(doorId, now: now)));
      expect((await door.open(await P(await openPacket(nonce, dpub, stranger)), doorId, now: now)).$1, doorDenied);
      expect(Door.fromJson(jsonDecode(jsonEncode(door.toJson()))).log.map((e) => e.status), [0, 2, 1]);
    });

    test('attendance beacon over ultrasonic sound', () async {
      final teacher = await Identity.generate();
      final cls = ClassSession('Sound class');
      final link = SoundLink(profiles['ultrasonic']!);
      final heard = (await decodeAudio(link.encodeBytes(await cls.beacon(teacher)), profiles['ultrasonic']!)).single;
      expect(readBeacon(heard.packet!).title, 'Sound class');
    });
  });
}
