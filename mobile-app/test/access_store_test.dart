import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:soundlink/engine/engine.dart';
import 'package:soundlink/services/access_store.dart';

void main() {
  test('access store saves tickets, event, door and classes', () async {
    SharedPreferences.setMockInitialValues({});
    final org = await Identity.generate(), me = await Identity.generate();
    final s = await AccessStore.open();
    final ev = Event('Fest', unixNow() + 3600);
    final (t, _) = await ev.issue(await Packet.fromBytes(await askPacket('Me', me)), org);
    await s.addTicket(HeldTicket(t, hexOf(org.publicKey), 'Fest'));
    await s.addTicket(HeldTicket(t, hexOf(org.publicKey), 'Fest')); // same ticket again is not doubled
    s.event = ev;
    s.door = Door('Lab')..allowed['ab'] = 'Asha';
    await s.saveClass(ClassSession('DBMS'));

    final again = await AccessStore.open();
    expect(again.tickets, hasLength(1));
    expect(again.tickets.single.ticket.number, 1);
    expect(again.event!.issued, hasLength(1));
    expect(again.door!.allowed['ab'], 'Asha');
    expect(again.classes.single['title'], 'DBMS');
  });
}
