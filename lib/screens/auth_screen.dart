import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../core/supabase_client.dart';
import '../widgets/glass_container.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _usernameController = TextEditingController();
  bool _isLogin = true;
  bool _loading = false;
  String? _error;
  bool _obscure = true;

  @override
  void initState() {
    super.initState();
  }

  Future<void> _submit() async {
    setState(() { _loading = true; _error = null; });
    try {
      final email = _emailController.text.trim();
      final password = _passwordController.text.trim();
      if (_isLogin) {
        await SupaConfig.client.auth.signInWithPassword(
          email: email, password: password,
        );
      } else {
        final username = _usernameController.text.trim();
        if (username.isEmpty) {
          setState(() => _error = 'Username is required');
          return;
        }
        // Check if username is taken
        final existing = await SupaConfig.client
            .from('users')
            .select('id')
            .eq('username', username)
            .maybeSingle();
        if (existing != null) {
          setState(() => _error = 'Username already taken');
          return;
        }
        final res = await SupaConfig.client.auth.signUp(
          email: email, password: password,
        );
        // Create user profile with username
        if (res.user != null) {
          await SupaConfig.client.from('users').upsert({
            'id': res.user!.id,
            'email': email,
            'username': username,
          });
        }
      }
    } on AuthException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 52),
                  const Text(
                    'strochat',
                    style: TextStyle(
                      color: Colors.white, fontSize: 32,
                      fontWeight: FontWeight.w800, letterSpacing: -1,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Private by design',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.4),
                      fontSize: 15, letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 52),
                  if (!_isLogin)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 14),
                      child: _buildPillField(
                        controller: _usernameController,
                        hint: 'Username',
                        icon: Icons.alternate_email_rounded,
                      ),
                    ),
                  _buildPillField(
                    controller: _emailController,
                    hint: 'Email address',
                    icon: Icons.mail_outline_rounded,
                    keyboardType: TextInputType.emailAddress,
                  ),
                  const SizedBox(height: 14),
                  _buildPillField(
                    controller: _passwordController,
                    hint: 'Password',
                    icon: Icons.lock_outline_rounded,
                    obscure: _obscure,
                    suffix: GestureDetector(
                      onTap: () => setState(() => _obscure = !_obscure),
                      child: Icon(
                        _obscure ? Icons.visibility_off_rounded : Icons.visibility_rounded,
                        color: Colors.white.withValues(alpha: 0.3),
                        size: 20,
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 20),
                      child: GlassContainer(
                        borderRadius: 50,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFF453A).withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(50),
                          ),
                          child: Text(
                            _error!,
                            style: const TextStyle(color: Color(0xFFFF453A), fontSize: 13),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                    ),
                  GestureDetector(
                    onTap: _loading ? null : _submit,
                    child: GlassContainer(
                      borderRadius: 50,
                      child: Container(
                        width: double.infinity,
                        height: 54,
                        decoration: BoxDecoration(
                          color: const Color(0xFF007AFF).withValues(alpha: 0.45),
                          borderRadius: BorderRadius.circular(50),
                        ),
                        alignment: Alignment.center,
                        child: _loading
                            ? const SizedBox(
                                width: 22, height: 22,
                                child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
                              )
                            : Text(
                                _isLogin ? 'Sign In' : 'Create Account',
                                style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600, letterSpacing: -0.3),
                              ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  GestureDetector(
                    onTap: () => setState(() => _isLogin = !_isLogin),
                    child: RichText(
                      text: TextSpan(
                        style: TextStyle(color: Colors.white.withValues(alpha: 0.45), fontSize: 14),
                        children: [
                          TextSpan(text: _isLogin ? "Don't have an account? " : 'Already have an account? '),
                          TextSpan(
                            text: _isLogin ? 'Sign up' : 'Sign in',
                            style: const TextStyle(color: Color(0xFF007AFF), fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 40),
                ],
              ),
            ),
          ),
    );
  }

  Widget _buildPillField({
    required TextEditingController controller,
    required String hint,
    required IconData icon,
    bool obscure = false,
    TextInputType? keyboardType,
    Widget? suffix,
  }) {
    return GlassContainer(
      borderRadius: 50,
      child: SizedBox(
        height: 54,
        child: TextField(
          controller: controller,
          obscureText: obscure,
          keyboardType: keyboardType,
          style: const TextStyle(color: Colors.white, fontSize: 16, letterSpacing: -0.2),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.25), fontSize: 16, letterSpacing: -0.2),
            prefixIcon: Padding(
              padding: const EdgeInsets.only(left: 18, right: 10),
              child: Icon(icon, color: Colors.white.withValues(alpha: 0.35), size: 20),
            ),
            prefixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
            suffixIcon: suffix != null ? Padding(padding: const EdgeInsets.only(right: 16), child: suffix) : null,
            suffixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
            border: InputBorder.none,
            contentPadding: const EdgeInsets.symmetric(vertical: 16),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _usernameController.dispose();
    super.dispose();
  }
}
