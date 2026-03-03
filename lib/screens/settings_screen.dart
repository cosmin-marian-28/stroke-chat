import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../core/supabase_client.dart';
import '../widgets/glass_pill.dart';
import 'sv_maker_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static const _storage = FlutterSecureStorage();
  final _supa = SupaConfig.client;
  String _username = '';
  String _email = '';
  bool _simpleUi = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final user = _supa.auth.currentUser;
    _email = user?.email ?? '';
    final uid = user?.id ?? '';
    final simple = await _storage.read(key: 'simple_ui');
    if (mounted) setState(() => _simpleUi = simple == 'true');
    if (uid.isNotEmpty) {
      final row = await _supa
          .from('users')
          .select('username')
          .eq('id', uid)
          .maybeSingle();
      if (mounted && row != null) {
        setState(() => _username = row['username'] as String? ?? '');
      }
    }
  }

  Future<void> _toggleSimpleUi(bool val) async {
    setState(() => _simpleUi = val);
    await _storage.write(key: 'simple_ui', value: val ? 'true' : 'false');
    // Notify the whole app
    SimpleUiNotifier.instance.value = val;
  }

  @override
  Widget build(BuildContext context) {
    final topPad = MediaQuery.of(context).padding.top;
    return Scaffold(
      backgroundColor: Colors.black,
      body: ListView(
        padding: EdgeInsets.only(
          top: topPad + 8,
          bottom: MediaQuery.of(context).padding.bottom + 40,
        ),
        children: [
          // Back button
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: GlassPill(
                    width: 42,
                    child: SvgPicture.asset('assets/back.svg',
                        width: 16, height: 16,
                        colorFilter: const ColorFilter.mode(
                            Colors.white70, BlendMode.srcIn)),
                  ),
                ),
                const SizedBox(width: 10),
                GlassPill(
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: Text('Settings',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 15,
                        )),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),
          // Avatar circle with initial
          Center(
            child: Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withValues(alpha: 0.06),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.1),
                  width: 1,
                ),
              ),
              child: Center(
                child: Text(
                  _username.isNotEmpty
                      ? _username[0].toUpperCase()
                      : _email.isNotEmpty
                          ? _email[0].toUpperCase()
                          : '?',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 30,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          // Username
          Center(
            child: Text(
              _username.isNotEmpty ? _username : '—',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.5,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Center(
            child: Text(
              _email,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.35),
                fontSize: 14,
              ),
            ),
          ),
          const SizedBox(height: 32),
          // Simple UI toggle
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.04),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.08),
                  width: 0.5,
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Simple UI',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w500,
                            )),
                        const SizedBox(height: 2),
                        Text(
                          'Disables glass effects and tilt animations for better performance',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.35),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Switch.adaptive(
                    value: _simpleUi,
                    onChanged: _toggleSimpleUi,
                    activeTrackColor: const Color(0xFF007AFF),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          // SV Maker button
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: GestureDetector(
              onTap: () => Navigator.push(
                context,
                PageRouteBuilder(
                  pageBuilder: (_, __, ___) => const SvMakerScreen(),
                  transitionsBuilder: (_, anim, __, child) =>
                      FadeTransition(opacity: anim, child: child),
                ),
              ),
              child: Container(
                height: 56,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.04),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.08),
                    width: 0.5,
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 34, height: 34,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: const Color(0xFF007AFF).withValues(alpha: 0.15),
                      ),
                      child: const Icon(Icons.music_video_outlined,
                          color: Color(0xFF007AFF), size: 18),
                    ),
                    const SizedBox(width: 14),
                    const Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('SV Maker',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.w500,
                              )),
                          Text('Create sound stickers',
                              style: TextStyle(
                                color: Colors.white38,
                                fontSize: 12,
                              )),
                        ],
                      ),
                    ),
                    Icon(Icons.chevron_right,
                        color: Colors.white.withValues(alpha: 0.2), size: 20),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Global notifier so GlassPill / GlassContainer can react without restart.
class SimpleUiNotifier extends ValueNotifier<bool> {
  SimpleUiNotifier._() : super(false);
  static final SimpleUiNotifier instance = SimpleUiNotifier._();

  /// Call once at app startup to load the persisted value.
  static Future<void> init() async {
    const storage = FlutterSecureStorage();
    final val = await storage.read(key: 'simple_ui');
    instance.value = val == 'true';
  }
}
