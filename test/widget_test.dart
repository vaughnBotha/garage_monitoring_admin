import 'package:flutter_test/flutter_test.dart';

import 'package:parking_garage_test/main.dart';

void main() {
  testWidgets('canvas screen loads with mode toggle and instructions', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const ParkingLayoutApp());

    expect(find.text('Zone layout — route/peg test'), findsOneWidget);
    expect(find.text('Route'), findsOneWidget);
    expect(find.text('Peg'), findsOneWidget);
    expect(find.textContaining('Route mode'), findsOneWidget);
  });
}
