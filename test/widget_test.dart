import 'package:flutter_test/flutter_test.dart';
import 'package:audiomind/main.dart';

void main() {
  testWidgets('AudioMind app smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const AudioMindApp());
    expect(find.text('Mi Biblioteca'), findsOneWidget);
  });
}
