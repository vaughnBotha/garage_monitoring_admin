import 'package:flutter_test/flutter_test.dart';

import 'package:parking_garage_test/main.dart';

void main() {
  testWidgets('canvas screen loads in read-only View mode by default', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const ParkingLayoutApp());

    expect(find.text('Zone layout — route/peg test'), findsOneWidget);
    expect(find.text('Edit'), findsOneWidget);
    expect(find.text('Route'), findsNothing);
    expect(find.text('Peg'), findsNothing);
    // No mode/status text, no zoom controls -- the toolbar and canvas are
    // all that's shown in View mode.
    expect(find.textContaining('mode'), findsNothing);
  });

  testWidgets('Edit reveals the zone/mode controls and mode instructions', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const ParkingLayoutApp());

    await tester.tap(find.text('Edit'));
    await tester.pump();

    expect(find.text('View'), findsOneWidget);
    expect(find.text('Route'), findsOneWidget);
    expect(find.text('Peg'), findsOneWidget);
    expect(find.textContaining('Route mode'), findsOneWidget);
  });
}
