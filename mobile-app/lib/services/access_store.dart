/// Saved state for the Access tab: my tickets, the event I organize, my door
/// (if this phone is a door) and doors I've joined.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../engine/engine.dart';

class AccessStore extends ChangeNotifier {
  final SharedPreferences _p;
  final List<HeldTicket> tickets = [];
  Event? event;
  Door? door;
  final Map<String, String> joinedDoors = {}; // door key hex -> name
  final List<Map<String, dynamic>> classes = []; // past attendance {title, time, count, csv}

  AccessStore._(this._p);

  static Future<AccessStore> open() async {
    final s = AccessStore._(await SharedPreferences.getInstance());
    T? load<T>(String k, T Function(dynamic) f) {
      final raw = s._p.getString(k);
      if (raw == null) return null;
      try {
        return f(jsonDecode(raw));
      } catch (_) {
        return null; // ignore broken saved data
      }
    }

    s.tickets.addAll(load('tickets_v1', (j) => [for (final e in j as List) HeldTicket.fromJson(e)]) ?? []);
    s.event = load('event_v1', (j) => Event.fromJson(j as Map<String, dynamic>));
    s.door = load('door_v1', (j) => Door.fromJson(j as Map<String, dynamic>));
    s.joinedDoors.addAll(load('joined_doors_v1', (j) => Map<String, String>.from(j as Map)) ?? {});
    s.classes.addAll(load('classes_v1', (j) => [for (final e in j as List) Map<String, dynamic>.from(e as Map)]) ?? []);
    return s;
  }

  Future<void> save() async {
    await _p.setString('tickets_v1', jsonEncode(tickets.map((t) => t.toJson()).toList()));
    if (event != null) {
      await _p.setString('event_v1', jsonEncode(event!.toJson()));
    } else {
      await _p.remove('event_v1');
    }
    if (door != null) {
      await _p.setString('door_v1', jsonEncode(door!.toJson()));
    } else {
      await _p.remove('door_v1');
    }
    await _p.setString('joined_doors_v1', jsonEncode(joinedDoors));
    await _p.setString('classes_v1', jsonEncode(classes.take(30).toList()));
    notifyListeners();
  }

  Future<void> addTicket(HeldTicket t) async {
    tickets.removeWhere((x) => x.ticket.event == t.ticket.event && x.organizer == t.organizer);
    tickets.insert(0, t);
    await save();
  }

  Future<void> saveClass(ClassSession c) async {
    classes.insert(0, {'title': c.title, 'time': c.started, 'count': c.present.length, 'csv': c.csv()});
    await save();
  }
}
