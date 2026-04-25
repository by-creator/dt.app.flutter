import 'package:flutter_test/flutter_test.dart';
import 'package:dt_xprinter/main.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const DtXprinterApp());
    expect(find.text('Dakar Terminal'), findsOneWidget);
  });
}
