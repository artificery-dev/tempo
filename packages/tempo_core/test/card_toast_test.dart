import 'package:flutter_test/flutter_test.dart';
import 'package:tempo_core/tempo_core.dart';
import 'package:tomeui/tomeui.dart';

void main() {
  testWidgets('the card coming and going is a notice; the first reading is '
      'not', (tester) async {
    final storage = ValueNotifier(StorageReading.empty);
    await tester.pumpWidget(
      TomeApp(
        home: Stack(
          children: [CardToasts(storage: storage), const OsdLayer()],
        ),
      ),
    );
    addTearDown(Osd.hide);
    expect(find.byKey(OsdToast.cardKey), findsNothing);

    storage.value = const StorageReading(present: true, label: 'SD card');
    await tester.pump();
    await tester.pump(Osd.fade);
    expect(find.text('SD card inserted'), findsOneWidget);

    await tester.pump(Osd.linger);
    await tester.pump(Osd.fade);
    await tester.pumpAndSettle();
    expect(find.byKey(OsdToast.cardKey), findsNothing);

    storage.value = StorageReading.empty;
    await tester.pump();
    await tester.pump(Osd.fade);
    expect(find.text('SD card removed'), findsOneWidget);
    await tester.pump(Osd.linger);
    await tester.pumpAndSettle();
  });
}
