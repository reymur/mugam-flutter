import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../core/theme/colors.dart';
import '../../../firebase/auth_service.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _authService = AuthService();
  bool _showPassword = false;
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  bool get _canSubmit =>
      _emailController.text.isNotEmpty &&
      _passwordController.text.isNotEmpty &&
      !_isLoading;

  Future<void> _handleLogin() async {
    if (!_canSubmit) return;
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      await _authService.loginWithEmail(
        _emailController.text.trim(),
        _passwordController.text,
      );
      if (mounted) context.go('/home');
    } on FirebaseAuthException catch (e) {
      final msg = switch (e.code) {
        'user-not-found' || 'wrong-password' || 'invalid-credential' =>
          'E-poçt və ya şifrə yanlışdır',
        'invalid-email' => 'E-poçt düzgün deyil',
        'too-many-requests' => 'Çox cəhd edildi, bir az gözləyin',
        _ => 'Giriş xətası baş verdi',
      };
      if (mounted) setState(() => _errorMessage = msg);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 48),
              const _Logo(),
              const SizedBox(height: 32),
              _buildTitle(),
              const SizedBox(height: 32),
              if (_errorMessage != null) ...[
                _buildErrorBox(),
                const SizedBox(height: 16),
              ],
              _buildLabel('E-POÇT'),
              const SizedBox(height: 8),
              _buildEmailField(),
              const SizedBox(height: 16),
              _buildLabel('ŞİFRƏ'),
              const SizedBox(height: 8),
              _buildPasswordField(),
              const SizedBox(height: 12),
              _buildForgotPassword(),
              const SizedBox(height: 28),
              _buildLoginButton(),
              const SizedBox(height: 24),
              _buildRegisterRow(),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTitle() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Daxil ol',
          style: GoogleFonts.playfairDisplay(
            fontSize: 26,
            fontWeight: FontWeight.bold,
            color: kText,
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          'Hesabına giriş et',
          style: TextStyle(fontSize: 14, color: kMuted),
        ),
      ],
    );
  }

  Widget _buildErrorBox() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: kRed.withAlpha(30),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kRed.withAlpha(80)),
      ),
      child: Text(
        '⚠️ $_errorMessage',
        style: const TextStyle(color: kRed, fontSize: 13),
      ),
    );
  }

  Widget _buildLabel(String text) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: 11,
        letterSpacing: 0.8,
        color: kMuted,
        fontWeight: FontWeight.w600,
      ),
    );
  }

  Widget _buildEmailField() {
    return TextFormField(
      controller: _emailController,
      keyboardType: TextInputType.emailAddress,
      onChanged: (_) => setState(() {}),
      style: const TextStyle(color: kText, fontSize: 15),
      decoration: _inputDecoration('musiqici@mail.com'),
    );
  }

  Widget _buildPasswordField() {
    return TextFormField(
      controller: _passwordController,
      obscureText: !_showPassword,
      onChanged: (_) => setState(() {}),
      style: const TextStyle(color: kText, fontSize: 15),
      decoration: _inputDecoration('••••••••').copyWith(
        suffixIcon: GestureDetector(
          onTap: () => setState(() => _showPassword = !_showPassword),
          child: Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Text(
              _showPassword ? '👁' : '🙈',
              style: const TextStyle(fontSize: 20),
            ),
          ),
        ),
      ),
    );
  }

  InputDecoration _inputDecoration(String hint) {
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: kMuted, fontSize: 15),
      filled: true,
      fillColor: kCard,
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: kBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: kBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: kGold, width: 1.5),
      ),
    );
  }

  Widget _buildForgotPassword() {
    return Align(
      alignment: Alignment.centerRight,
      child: GestureDetector(
        onTap: () {},
        child: const Text(
          'Şifrəni unutdum?',
          style: TextStyle(
            color: kGold,
            fontSize: 13,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }

  Widget _buildLoginButton() {
    return Opacity(
      opacity: _canSubmit ? 1.0 : 0.5,
      child: SizedBox(
        height: 52,
        child: ElevatedButton(
          onPressed: _canSubmit ? _handleLogin : null,
          style: ElevatedButton.styleFrom(
            backgroundColor: kGold,
            disabledBackgroundColor: kGold,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(28),
            ),
            elevation: 0,
          ),
          child: _isLoading
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    color: Color(0xFF1A0E00),
                  ),
                )
              : const Text(
                  '🎵 Daxil ol',
                  style: TextStyle(
                    color: Color(0xFF1A0E00),
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.3,
                  ),
                ),
        ),
      ),
    );
  }

  Widget _buildRegisterRow() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Text(
          'Hesabın yoxdur? ',
          style: TextStyle(color: kMuted, fontSize: 14),
        ),
        GestureDetector(
          onTap: () {},
          child: const Text(
            'Qeydiyyat',
            style: TextStyle(
              color: kGold,
              fontSize: 14,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ],
    );
  }
}

class _Logo extends StatelessWidget {
  const _Logo();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: 80,
          height: 80,
          decoration: BoxDecoration(
            color: const Color(0xFF2A1E08),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: kGold, width: 2),
          ),
          child: const Center(
            child: Text('🎵', style: TextStyle(fontSize: 36)),
          ),
        ),
        const SizedBox(height: 14),
        Text(
          'Muğam Club',
          style: GoogleFonts.playfairDisplay(
            fontSize: 28,
            color: kGold2,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          'AZƏRBAYCAN MUSİQİSİ',
          style: TextStyle(
            fontSize: 11,
            letterSpacing: 2.5,
            color: kMuted,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}
