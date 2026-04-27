import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

/// Provider for the currently active intent string.
/// Empty string = no active intent.
/// Will be wired to real logic in Phase 5.
final activeIntentProvider = StateProvider<String>((ref) => '');

/// Provider for whether the app is currently listening (voice input active).
/// Will be wired to real logic in Phase 5.
final isListeningProvider = StateProvider<bool>((ref) => false);

/// Thin banner at the top of non-camera screens.
/// Shows the active intent (if set) and a listening indicator dot.
class StatusBar extends ConsumerWidget {
  const StatusBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activeIntent = ref.watch(activeIntentProvider);
    final isListening = ref.watch(isListeningProvider);
    final hasIntent = activeIntent.isNotEmpty;
    final hasStatus = hasIntent || isListening;

    if (!hasStatus) {
      // Reserve a small amount of spacing even when empty
      return const SizedBox(height: 4);
    }

    return SafeArea(
      bottom: false,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        color: const Color(0xFF1C1C1E),
        child: Row(
          children: [
            if (isListening) ...[
              _ListeningDot(),
              const SizedBox(width: 8),
            ],
            if (hasIntent) ...[
              const Icon(
                Icons.my_location_rounded,
                color: Color(0xFFFFBF00),
                size: 16,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Finding: $activeIntent',
                  style: GoogleFonts.outfit(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: const Color(0xFFFFBF00),
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              // Dismiss chip
              GestureDetector(
                onTap: () => ref.read(activeIntentProvider.notifier).state = '',
                child: const Icon(
                  Icons.close_rounded,
                  size: 18,
                  color: Color(0xFF8E8E93),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Animated green pulsing dot for listening indicator
class _ListeningDot extends StatefulWidget {
  @override
  State<_ListeningDot> createState() => _ListeningDotState();
}

class _ListeningDotState extends State<_ListeningDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _anim = Tween<double>(begin: 0.3, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _anim,
      builder: (_, __) => Opacity(
        opacity: _anim.value,
        child: Container(
          width: 10,
          height: 10,
          decoration: const BoxDecoration(
            color: Color(0xFF34C759),
            shape: BoxShape.circle,
          ),
        ),
      ),
    );
  }
}
