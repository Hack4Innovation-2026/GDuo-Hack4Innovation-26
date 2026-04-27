import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:google_fonts/google_fonts.dart';

import 'router.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await dotenv.load(fileName: '.env');
  } catch (_) {
    // .env is optional in debug; app can still run with --dart-define.
  }
  runApp(
    const ProviderScope(
      child: DrishtiApp(),
    ),
  );
}

class DrishtiApp extends ConsumerWidget {
  const DrishtiApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(appRouterProvider);

    return MaterialApp.router(
      title: 'DrishtiAI',
      debugShowCheckedModeBanner: false,
      theme: _buildTheme(),
      routerConfig: router,
    );
  }

  ThemeData _buildTheme() {
    final base = ThemeData.light();
    return base.copyWith(
      colorScheme: const ColorScheme.light(
        primary: Color(0xFF1A56DB),       // Deep accessible blue
        onPrimary: Color(0xFFFFFFFF),     // White text on primary
        secondary: Color(0xFF00E5CC),     // Teal accent
        onSecondary: Color(0xFF1A1A1A),
        surface: Color(0xFFFFFFFF),       // White surface
        onSurface: Color(0xFF1A1A1A),     // Dark text
        error: Color(0xFFCC0000),         // SOS Red
        onError: Color(0xFFFFFFFF),
        outline: Color(0xFFE5E5EA),
      ),
      scaffoldBackgroundColor: const Color(0xFFFFFFFF), // White background
      textTheme: GoogleFonts.outfitTextTheme(base.textTheme).copyWith(
        // All body text minimum 18 sp for readability
        bodyMedium: GoogleFonts.outfit(
          fontSize: 18,
          color: const Color(0xFF1A1A1A),
        ),
        bodyLarge: GoogleFonts.outfit(
          fontSize: 20,
          color: const Color(0xFF1A1A1A),
        ),
        titleMedium: GoogleFonts.outfit(
          fontSize: 22,
          fontWeight: FontWeight.w600,
          color: const Color(0xFF1A1A1A),
        ),
        titleLarge: GoogleFonts.outfit(
          fontSize: 26,
          fontWeight: FontWeight.w700,
          color: const Color(0xFF1A1A1A),
        ),
        labelLarge: GoogleFonts.outfit(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: const Color(0xFF1A1A1A),
        ),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: const Color(0xFFFFFFFF),
        foregroundColor: const Color(0xFF1A1A1A),
        elevation: 0,
        centerTitle: false,
        titleTextStyle: GoogleFonts.outfit(
          fontSize: 24,
          fontWeight: FontWeight.w700,
          color: const Color(0xFF1A1A1A),
        ),
      ),
      cardTheme: const CardThemeData(
        color: Color(0xFFFFFFFF),
        elevation: 2,
        shadowColor: Colors.black12,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF1A56DB),
          foregroundColor: const Color(0xFFFFFFFF),
          minimumSize: const Size.fromHeight(56), // Accessibility: large tap target
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          textStyle: GoogleFonts.outfit(fontSize: 18, fontWeight: FontWeight.w600),
        ),
      ),
      listTileTheme: const ListTileThemeData(
        minVerticalPadding: 16,  // Large touch targets
        contentPadding: EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      ),
      dividerTheme: const DividerThemeData(
        color: Color(0xFFE5E5EA),
        thickness: 1,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFFF2F2F7),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Color(0xFF1A56DB), width: 2),
        ),
        labelStyle: GoogleFonts.outfit(fontSize: 16, color: const Color(0xFF3A3A3C)),
        hintStyle: GoogleFonts.outfit(fontSize: 16, color: const Color(0xFF8E8E93)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return const Color(0xFF1A56DB);
          return const Color(0xFF8E8E93);
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return const Color(0xFF1A56DB).withValues(alpha: 0.4);
          }
          return const Color(0xFFE5E5EA);
        }),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: Colors.white,
      ),
    );
  }
}
