import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../lib/main.dart'; // Ensure correct import for DrishtiApp
import '../lib/screens/home_screen.dart';

void main() {
  testWidgets('App renders onboarding and can navigate to home', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: DrishtiApp()));
    await tester.pumpAndSettle(); // Settle initial render
    
    // Tap anywhere text should not be visible initially as we are on onboarding
    expect(find.text('Start now'), findsOneWidget);
    
    // Tap "Start now"
    await tester.tap(find.text('Start now'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2)); // wait for navigation
    
    // Now we should be on HomeScreen (Idle State)
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.text('Tap anywhere to start'), findsOneWidget);
  });
}
