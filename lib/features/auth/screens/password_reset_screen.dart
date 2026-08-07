import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/auth/password_reset.dart';
import '../../../core/theme/colors.dart';
import '../../../firebase/auth_service.dart';

/// Сброс пароля — работа 5а.
///
/// **Почему экран вообще есть.** Ссылка «Şifrəni unutdum?» была снята с
/// входа 07.08 как ТУПИК: она вела `onTap: () {}` (N65). С тех пор у
/// забывшего пароль не было НИКАКОЙ двери — единственное место, где
/// состояние стало хуже, чем до правки. Экран возвращает дверь вместе с
/// ручкой: ссылка на входе ставится обратно этой же работой.
///
/// **Экран вне `AuthGate`** — человек не вошёл и войти не может, ему туда
/// нельзя. Маршрут лежит рядом с `/login`.
class PasswordResetScreen extends StatefulWidget {
  const PasswordResetScreen({super.key, this.initialEmail});

  /// Почта, набранная на входе. Человек пришёл сюда именно потому, что
  /// этот адрес его не пустил, — заставлять набирать заново незачем.
  final String? initialEmail;

  @override
  State<PasswordResetScreen> createState() => _PasswordResetScreenState();
}

class _PasswordResetScreenState extends State<PasswordResetScreen> {
  late final TextEditingController _emailController =
      TextEditingController(text: widget.initialEmail ?? '');
  final _authService = AuthService();
  bool _isLoading = false;
  String? _errorMessage;
  bool _sent = false;

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  EmailCheck get _check => checkResetEmail(_emailController.text);

  Future<void> _handleSend() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      await _authService.resetPassword(_emailController.text.trim());
      if (!mounted) return;
      setState(() => _sent = true);
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = resetErrorMessage(e.code));
    } catch (_) {
      // Не `FirebaseAuthException` — то есть причина нам неизвестна вовсе.
      // Разбор N45: неизвестный отказ НЕ получает правдоподобного
      // объяснения. `resetErrorMessage(null)` и говорит ровно это.
      if (!mounted) return;
      setState(() => _errorMessage = resetErrorMessage(null));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: kGold),
          onPressed: () => context.go('/login'),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Şifrəni bərpa et',
                style: TextStyle(
                  color: kText,
                  fontSize: 26,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'E-poçtunuzu yazın — bərpa linki oraya gələcək.',
                style: TextStyle(color: kMuted, fontSize: 14),
              ),
              const SizedBox(height: 28),
              _buildLabel('E-POÇT'),
              const SizedBox(height: 8),
              _buildEmailField(),
              _buildWarning(),
              const SizedBox(height: 28),
              if (_sent) _buildSent() else _buildSendButton(),
              if (_errorMessage != null) _buildError(),
            ],
          ),
        ),
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
      autocorrect: false,
      enabled: !_sent,
      onChanged: (_) => setState(() {}),
      style: const TextStyle(color: kText, fontSize: 15),
      decoration: InputDecoration(
        hintText: 'musiqici@mail.com',
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
      ),
    );
  }

  /// Подсказка про опечатку в домене — ВОПРОС, а не запрет.
  ///
  /// Это последнее место, где `.con` вместо `.com` ещё можно поймать:
  /// после отправки не поймает никто, Firebase отвечает успехом на любой
  /// синтаксически верный адрес. В проде такой домен уже есть (N78).
  Widget _buildWarning() {
    final warning = _check.warning;
    if (warning == null || _sent) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('🤔 ', style: TextStyle(fontSize: 14)),
          Expanded(
            child: Text(
              'Bəlkə $warning',
              style: const TextStyle(color: kTextSecondary, fontSize: 13.5),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSendButton() {
    final canSend = _check.canSend && !_isLoading;
    return Opacity(
      opacity: canSend ? 1.0 : 0.5,
      child: SizedBox(
        width: double.infinity,
        height: 52,
        child: ElevatedButton(
          onPressed: canSend ? _handleSend : null,
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
                  'Bərpa linki göndər',
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

  /// Ответ после отправки.
  ///
  /// Текст НАМЕРЕННО не утверждает, что письмо ушло именно этому человеку
  /// — см. `resetSentMessage`. Firebase отвечает успехом и на
  /// несуществующий адрес, и это его защита от подбора чужих почт: ломать
  /// её нельзя, а значит и обещать больше, чем знаем, — тоже.
  Widget _buildSent() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: kCard,
            borderRadius: BorderRadius.circular(14),
            border: const Border(left: BorderSide(color: kGold, width: 4)),
          ),
          child: const Text(
            resetSentMessage,
            style: TextStyle(color: kText, fontSize: 14.5, height: 1.4),
          ),
        ),
        const SizedBox(height: 20),
        TextButton(
          onPressed: () => context.go('/login'),
          child: const Text(
            'Girişə qayıt',
            style: TextStyle(color: kGold, fontSize: 15),
          ),
        ),
      ],
    );
  }

  Widget _buildError() {
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Text(
        _errorMessage!,
        style: const TextStyle(color: kRed, fontSize: 14),
      ),
    );
  }
}
