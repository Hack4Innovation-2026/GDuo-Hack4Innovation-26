import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_tts/flutter_tts.dart';

/// Onboarding splash screen shown on app install.
/// Routes to the main Camera tab via "Start now".
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  // Settings State
  bool _soundEnabled = true;
  String _assistantVoice = 'Female';
  String _language = 'English';

  // SOS State
  String _contactName = '';
  String _contactPhone = '';
  late final FlutterTts _tts;

  @override
  void initState() {
    super.initState();
    _tts = FlutterTts();
    _configureTts();
    _loadPreferences();
  }

  Future<void> _configureTts() async {
    try {
      await _tts.setEngine('com.google.android.tts');
    } catch (_) {}
    try {
      await _tts.awaitSpeakCompletion(true);
    } catch (_) {}
    await _tts.setLanguage('en-IN');
    await _tts.setSpeechRate(0.5);
    await _tts.setPitch(1.0);
  }

  Future<void> _speakWelcome() async {
    try {
      await _tts.stop();
      await _tts.speak('Welcome to DrishtiAI');
    } catch (_) {}
  }

  @override
  void dispose() {
    unawaited(_tts.stop());
    super.dispose();
  }

  Future<void> _loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _soundEnabled = prefs.getBool('soundEnabled') ?? true;
      _assistantVoice = prefs.getString('assistantVoice') ?? 'Female';
      _language = prefs.getString('language') ?? 'English';
      _contactName = prefs.getString('contactName') ?? '';
      _contactPhone = prefs.getString('contactPhone') ?? '';
    });
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('soundEnabled', _soundEnabled);
    await prefs.setString('assistantVoice', _assistantVoice);
    await prefs.setString('language', _language);
  }

  Future<void> _saveSOS(String name, String phone) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('contactName', name);
    await prefs.setString('contactPhone', phone);
    setState(() {
      _contactName = name;
      _contactPhone = phone;
    });
  }

  void _showSettingsBottomSheet() {
    // Local state for bottom sheet
    bool sheetSoundEnabled = _soundEnabled;
    String sheetAssistantVoice = _assistantVoice;
    String sheetLanguage = _language;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return StatefulBuilder(builder: (context, setModalState) {
          return Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(context).viewInsets.bottom,
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Close handle bar
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 24),
                      decoration: BoxDecoration(
                        color: Colors.grey[300],
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  Text('Voice', style: GoogleFonts.outfit(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.black87)),
                  const SizedBox(height: 16),
                  
                  // Toggle Switch
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('Sound enabled', style: GoogleFonts.outfit(fontSize: 18, fontWeight: FontWeight.w500, color: Colors.black87)),
                    value: sheetSoundEnabled,
                    activeColor: const Color(0xFF1A56DB),
                    onChanged: (val) {
                      setModalState(() => sheetSoundEnabled = val);
                    },
                  ),
                  const SizedBox(height: 16),
                  
                  // Assistant Voice
                  Text('Assistant voice', style: GoogleFonts.outfit(fontSize: 18, fontWeight: FontWeight.w500, color: Colors.black87)),
                  const SizedBox(height: 12),
                  Row(
                    children: ['Female', 'Male', 'Neutral'].map((voice) {
                      final isSelected = sheetAssistantVoice == voice;
                      return Expanded(
                        child: GestureDetector(
                          onTap: () {
                            setModalState(() => sheetAssistantVoice = voice);
                          },
                          child: Container(
                            margin: const EdgeInsets.symmetric(horizontal: 4),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            decoration: BoxDecoration(
                              color: isSelected ? const Color(0xFF1A56DB) : Colors.grey[200],
                              borderRadius: BorderRadius.circular(24),
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              voice,
                              style: GoogleFonts.outfit(
                                fontSize: 16,
                                fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                                color: isSelected ? Colors.white : Colors.black87,
                              ),
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 24),
                  
                  // Language Section
                  Text('Language', style: GoogleFonts.outfit(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.black87)),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    decoration: BoxDecoration(
                      color: Colors.grey[100],
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: sheetLanguage,
                        isExpanded: true,
                        icon: const Icon(Icons.arrow_drop_down, color: Color(0xFF1A56DB)),
                        items: ['English', 'Hindi', 'Marathi'].map((lang) {
                          return DropdownMenuItem(
                            value: lang,
                            child: Text(lang, style: GoogleFonts.outfit(fontSize: 18, color: Colors.black87)),
                          );
                        }).toList(),
                        onChanged: (val) {
                          if (val != null) {
                            setModalState(() => sheetLanguage = val);
                          }
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 40),
                  
                  // Done Button
                  ElevatedButton(
                    onPressed: () {
                      setState(() {
                        _soundEnabled = sheetSoundEnabled;
                        _assistantVoice = sheetAssistantVoice;
                        _language = sheetLanguage;
                      });
                      _saveSettings();
                      Navigator.pop(context);
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1A56DB),
                      foregroundColor: Colors.white,
                      minimumSize: const Size.fromHeight(56),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      textStyle: GoogleFonts.outfit(fontSize: 20, fontWeight: FontWeight.w600),
                    ),
                    child: const Text('Done'),
                  ),
                ],
              ),
            ),
          );
        });
      },
    );
  }

  void _showSOSBottomSheet() {
    final nameController = TextEditingController(text: _contactName);
    final phoneController = TextEditingController(text: _contactPhone);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Close handle bar
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 24),
                    decoration: BoxDecoration(
                      color: Colors.grey[300],
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Text('Emergency contact', style: GoogleFonts.outfit(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.black87)),
                const SizedBox(height: 24),
                
                // Name Input
                Text('Contact name', style: GoogleFonts.outfit(fontSize: 16, fontWeight: FontWeight.w500, color: Colors.black87)),
                const SizedBox(height: 8),
                TextField(
                  controller: nameController,
                  decoration: InputDecoration(
                    hintText: 'e.g. Mom, Raju',
                    filled: true,
                    fillColor: Colors.grey[100],
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                  ),
                  style: GoogleFonts.outfit(fontSize: 18),
                ),
                const SizedBox(height: 16),
                
                // Phone Input
                Text('Phone number', style: GoogleFonts.outfit(fontSize: 16, fontWeight: FontWeight.w500, color: Colors.black87)),
                const SizedBox(height: 8),
                TextField(
                  controller: phoneController,
                  keyboardType: TextInputType.phone,
                  decoration: InputDecoration(
                    hintText: 'e.g. 9876543210',
                    filled: true,
                    fillColor: Colors.grey[100],
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                  ),
                  style: GoogleFonts.outfit(fontSize: 18),
                ),
                const SizedBox(height: 32),
                
                // Save/Update Button
                ElevatedButton(
                  onPressed: () {
                    _saveSOS(nameController.text.trim(), phoneController.text.trim());
                    Navigator.pop(context);
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1A56DB),
                    foregroundColor: Colors.white,
                    minimumSize: const Size.fromHeight(56),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    textStyle: GoogleFonts.outfit(fontSize: 20, fontWeight: FontWeight.w600),
                  ),
                  child: Text(_contactName.isNotEmpty ? 'Update' : 'Save'),
                ),
                const SizedBox(height: 16),
                
                // Helper Text
                Center(
                  child: Text(
                    'Triple-press the volume button at any time to call this contact.',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.outfit(fontSize: 14, color: Colors.grey[600]),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // Explicitly use a light theme context here since the rest of the app is dark.
    return Theme(
      data: ThemeData.light().copyWith(
        scaffoldBackgroundColor: const Color(0xFFF8F9FA), // Soft white
      ),
      child: Scaffold(
        body: SafeArea(
          child: Stack(
            children: [
              // Main centered content
              Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // ─── Top Logo ───────────────────────────────────────
                    const Spacer(flex: 2),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'DrishtiAI',
                          style: GoogleFonts.outfit(
                            fontSize: 48,
                            fontWeight: FontWeight.w600,
                            color: const Color(0xFF53A1D7), // Light blue branding
                            letterSpacing: -1.0,
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Icon(
                          Icons.visibility_rounded, // Eye icon
                          color: Color(0xFF53A1D7),
                          size: 32,
                        ),
                      ],
                    ),
                    
                    const Spacer(flex: 3),

                    // ─── Start Now Button ───────────────────────────────
                    Container(
                      margin: const EdgeInsets.symmetric(horizontal: 40),
                      child: ElevatedButton(
                        onPressed: () {
                          if (_soundEnabled) {
                            unawaited(_speakWelcome());
                          }
                          // Navigate to the main shell (Camera screen default)
                          context.go('/home');
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF63AEE2), // Light blue button
                          foregroundColor: Colors.white,
                          elevation: 4,
                          shadowColor: const Color(0xFF63AEE2).withValues(alpha: 0.5),
                          padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 24),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(24),
                          ),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.camera_alt_rounded, size: 28),
                            const SizedBox(width: 12),
                            Text(
                              'Start now',
                              style: GoogleFonts.outfit(
                                fontSize: 24,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(width: 8),
                            const Icon(Icons.chevron_right_rounded, size: 28),
                          ],
                        ),
                      ),
                    ),
                    
                    const SizedBox(height: 16),
                    
                    // ─── Helper Text ────────────────────────────────────
                    Text(
                      'Accessing camera and smart assistance',
                      style: GoogleFonts.outfit(
                        fontSize: 14,
                        color: const Color(0xFF8E8E93),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    
                    const Spacer(flex: 2),
                  ],
                ),
              ),

              // SOS Button (Top Left)
              Positioned(
                top: 16,
                left: 16,
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: _showSOSBottomSheet,
                    borderRadius: BorderRadius.circular(24),
                    child: Container(
                      width: 48,
                      height: 48,
                      decoration: const BoxDecoration(
                        color: Color(0xFFCC0000), // Red hex cc0000
                        shape: BoxShape.circle,
                      ),
                      child: const Center(
                        child: Icon(Icons.phone, color: Colors.white, size: 24),
                      ),
                    ),
                  ),
                ),
              ),

              // Settings Gear (Top Right)
              Positioned(
                top: 16,
                right: 16,
                child: Material(
                  color: Colors.transparent,
                  child: IconButton(
                    icon: const Icon(Icons.settings, color: Colors.black54, size: 32),
                    onPressed: _showSettingsBottomSheet,
                    constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                    tooltip: 'Settings',
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
