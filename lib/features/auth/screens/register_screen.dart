import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../core/constants/musician_options.dart';
import '../../../core/theme/colors.dart';
import '../../../firebase/auth_service.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();
  final _authService = AuthService();

  String? _role;
  String? _instrument;
  String? _city;
  bool _showPassword = false;
  bool _showConfirmPassword = false;
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _handleRegister() async {
    if (_isLoading) return;

    if (_role == null) {
      setState(() => _errorMessage = 'Rol seçin');
      return;
    }
    if (_nameController.text.trim().isEmpty) {
      setState(() => _errorMessage = 'Ad daxil edin');
      return;
    }
    if (_emailController.text.trim().isEmpty) {
      setState(() => _errorMessage = 'E-poçt daxil edin');
      return;
    }
    if (_passwordController.text.length < 6) {
      setState(() => _errorMessage = 'Şifrə ən azı 6 simvol olmalıdır');
      return;
    }
    if (_passwordController.text != _confirmController.text) {
      setState(() => _errorMessage = 'Şifrələr uyğun gəlmir');
      return;
    }
    if (_role == 'musiqici' && _instrument == null) {
      setState(() => _errorMessage = 'Alət seçin');
      return;
    }
    if (_city == null) {
      setState(() => _errorMessage = 'Şəhər seçin');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      await _authService.registerWithEmail(
        email: _emailController.text.trim(),
        password: _passwordController.text,
        displayName: _nameController.text.trim(),
        instrument: _instrument ?? '',
        city: _city!,
        role: _role!,
      );
      if (mounted) context.go('/home');
    } on FirebaseAuthException catch (e) {
      final msg = switch (e.code) {
        'email-already-in-use' => 'Bu e-poçt artıq istifadə olunur',
        'weak-password' => 'Şifrə çox zəifdir',
        'invalid-email' => 'E-poçt düzgün deyil',
        'too-many-requests' => 'Çox cəhd edildi, bir az gözləyin',
        _ => 'Qeydiyyat xətası baş verdi',
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
              const SizedBox(height: 24),
              if (_errorMessage != null) ...[
                _buildErrorBox(),
                const SizedBox(height: 16),
              ],
              _buildLabel('ROL SEÇ'),
              const SizedBox(height: 10),
              _buildRoleSelector(),
              const SizedBox(height: 20),
              _buildLabel('AD SOYAD'),
              const SizedBox(height: 8),
              _buildNameField(),
              const SizedBox(height: 16),
              _buildLabel('E-POÇT'),
              const SizedBox(height: 8),
              _buildEmailField(),
              const SizedBox(height: 16),
              _buildLabel('ŞİFRƏ'),
              const SizedBox(height: 8),
              _buildPasswordField(),
              const SizedBox(height: 16),
              _buildLabel('ŞİFRƏNİ TƏKRAR ET'),
              const SizedBox(height: 8),
              _buildConfirmPasswordField(),
              if (_role == 'musiqici') ...[
                const SizedBox(height: 20),
                _buildLabel('ALƏT SEÇ'),
                const SizedBox(height: 10),
                _buildInstrumentGrid(),
              ],
              const SizedBox(height: 20),
              _buildLabel('ŞƏHƏRİ SEÇ'),
              const SizedBox(height: 10),
              _buildCityGrid(),
              const SizedBox(height: 28),
              _buildRegisterButton(),
              const SizedBox(height: 24),
              _buildLoginRow(),
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
          'Qeydiyyat',
          style: GoogleFonts.playfairDisplay(
            fontSize: 26,
            fontWeight: FontWeight.bold,
            color: kText,
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          'Yeni hesab yarat',
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

  Widget _buildRoleSelector() {
    return Row(
      children: [
        Expanded(
          child: _buildRoleCard(
            'musiqici',
            '🎵',
            'Musiqiçi',
            'Siyahıda görünərəm',
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _buildRoleCard(
            'qonaq',
            '👤',
            'Qonaq',
            'Musiqiçi dəvət edərəm',
          ),
        ),
      ],
    );
  }

  Widget _buildRoleCard(
    String value,
    String emoji,
    String title,
    String subtitle,
  ) {
    final selected = _role == value;
    return GestureDetector(
      onTap: () => setState(() {
        _role = value;
        if (value == 'qonaq') _instrument = null;
      }),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
        decoration: BoxDecoration(
          color: selected ? kGoldDim : kCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? kGold : kBorder,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Column(
          children: [
            Text(emoji, style: const TextStyle(fontSize: 26)),
            const SizedBox(height: 6),
            Text(
              title,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: selected ? kGold : kText,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              subtitle,
              style: const TextStyle(fontSize: 10, color: kMuted),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNameField() {
    return TextFormField(
      controller: _nameController,
      onChanged: (_) => setState(() {}),
      style: const TextStyle(color: kText, fontSize: 15),
      decoration: _inputDecoration('Adınızı daxil edin'),
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

  Widget _buildConfirmPasswordField() {
    return TextFormField(
      controller: _confirmController,
      obscureText: !_showConfirmPassword,
      onChanged: (_) => setState(() {}),
      style: const TextStyle(color: kText, fontSize: 15),
      decoration: _inputDecoration('••••••••').copyWith(
        suffixIcon: GestureDetector(
          onTap: () =>
              setState(() => _showConfirmPassword = !_showConfirmPassword),
          child: Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Text(
              _showConfirmPassword ? '👁' : '🙈',
              style: const TextStyle(fontSize: 20),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildInstrumentGrid() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: kInstruments.map((instr) {
        final selected = _instrument == instr;
        return GestureDetector(
          onTap: () => setState(() => _instrument = instr),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: selected ? kGoldDim : kCard,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: selected ? kGold : kBorder,
                width: selected ? 1.5 : 1,
              ),
            ),
            child: Text(
              instr,
              style: TextStyle(
                fontSize: 13,
                color: selected ? kGold : kText,
                fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildCityGrid() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: kCities.map((cityName) {
        final selected = _city == cityName;
        return GestureDetector(
          onTap: () => setState(() => _city = cityName),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: selected ? kGoldDim : kCard,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: selected ? kGold : kBorder,
                width: selected ? 1.5 : 1,
              ),
            ),
            child: Text(
              '📍 $cityName',
              style: TextStyle(
                fontSize: 13,
                color: selected ? kGold : kText,
                fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ),
        );
      }).toList(),
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

  Widget _buildRegisterButton() {
    return Opacity(
      opacity: _isLoading ? 0.5 : 1.0,
      child: SizedBox(
        height: 52,
        child: ElevatedButton(
          onPressed: _isLoading ? null : _handleRegister,
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
                  '🎵 Qeydiyyatdan keç',
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

  Widget _buildLoginRow() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Text(
          'Artıq hesabın var? ',
          style: TextStyle(color: kMuted, fontSize: 14),
        ),
        GestureDetector(
          onTap: () => context.go('/login'),
          child: const Text(
            'Daxil ol',
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
