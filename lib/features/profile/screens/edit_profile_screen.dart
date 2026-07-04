import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart' hide User;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import '../../../core/constants/musician_options.dart';
import '../../../core/theme/colors.dart';
import '../../../firebase/firestore_service.dart';
import '../../../firebase/models.dart';

class EditProfileScreen extends ConsumerStatefulWidget {
  final User musician;

  const EditProfileScreen({super.key, required this.musician});

  @override
  ConsumerState<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends ConsumerState<EditProfileScreen> {
  late final TextEditingController _nameController;
  late final TextEditingController _bioController;
  String? _instrument;
  String? _city;
  late bool _available;
  String? _localAvatarPath;
  bool _isSaving = false;
  String? _errorMessage;

  final _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.musician.name);
    _bioController = TextEditingController(text: widget.musician.bio);
    _instrument = kInstruments.firstWhere(
      (i) => i == widget.musician.instrument,
      orElse: () => widget.musician.instrument,
    );
    if (_instrument != null && _instrument!.isEmpty) _instrument = null;
    _city = widget.musician.city.isEmpty ? null : widget.musician.city;
    _available = widget.musician.available;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _bioController.dispose();
    super.dispose();
  }

  Future<void> _pickAvatar() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      backgroundColor: kBg2,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera, color: kGold),
              title: const Text('Kamera', style: TextStyle(color: kText)),
              onTap: () => Navigator.pop(context, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library, color: kGold),
              title: const Text('Qalereya', style: TextStyle(color: kText)),
              onTap: () => Navigator.pop(context, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null) return;
    final picked = await _picker.pickImage(
      source: source,
      imageQuality: 80,
      maxWidth: 800,
    );
    if (picked == null) return;
    setState(() => _localAvatarPath = picked.path);
  }

  Future<void> _handleSave() async {
    if (_isSaving) return;
    if (_nameController.text.trim().isEmpty) {
      setState(() => _errorMessage = 'Ad daxil edin');
      return;
    }
    setState(() {
      _isSaving = true;
      _errorMessage = null;
    });
    try {
      final service = ref.read(firestoreServiceProvider);
      String? photoURL;
      if (_localAvatarPath != null) {
        photoURL = await service.uploadAvatar(
          uid: widget.musician.id,
          filePath: _localAvatarPath!,
        );
      }
      await service.updateUserProfile(
        uid: widget.musician.id,
        displayName: _nameController.text.trim(),
        bio: _bioController.text.trim(),
        instrument: _instrument ?? '',
        city: _city ?? '',
        available: _available,
        photoURL: photoURL,
      );
      await FirebaseAuth.instance.currentUser?.updateDisplayName(
        _nameController.text.trim(),
      );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) setState(() => _errorMessage = 'Yadda saxlanmadı: $e');
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg2,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: kGold),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          'Profili redaktə et',
          style: GoogleFonts.playfairDisplay(fontSize: 18, color: kText),
        ),
        actions: [
          TextButton(
            onPressed: _isSaving ? null : _handleSave,
            child: _isSaving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: kGold,
                    ),
                  )
                : const Text(
                    'Yadda saxla',
                    style: TextStyle(color: kGold, fontWeight: FontWeight.bold),
                  ),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_errorMessage != null) ...[
                _buildErrorBox(),
                const SizedBox(height: 16),
              ],
              Center(child: _buildAvatarPicker()),
              const SizedBox(height: 28),
              _buildLabel('AD SOYAD'),
              const SizedBox(height: 8),
              _buildNameField(),
              const SizedBox(height: 16),
              _buildLabel('HAQQINDA'),
              const SizedBox(height: 8),
              _buildBioField(),
              const SizedBox(height: 20),
              _buildLabel('ALƏT'),
              const SizedBox(height: 10),
              _buildInstrumentGrid(),
              const SizedBox(height: 20),
              _buildLabel('ŞƏHƏR'),
              const SizedBox(height: 10),
              _buildCityGrid(),
              const SizedBox(height: 20),
              _buildAvailabilityToggle(),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
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

  Widget _buildAvatarPicker() {
    ImageProvider? image;
    if (_localAvatarPath != null) {
      image = FileImage(File(_localAvatarPath!));
    } else if (widget.musician.photoURL != null) {
      image = NetworkImage(widget.musician.photoURL!);
    }
    return GestureDetector(
      onTap: _pickAvatar,
      child: Stack(
        children: [
          Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              color: kBg3,
              shape: BoxShape.circle,
              border: Border.all(color: kGold, width: 3),
              image: image != null
                  ? DecorationImage(image: image, fit: BoxFit.cover)
                  : null,
            ),
            alignment: Alignment.center,
            child: image == null
                ? Text(
                    widget.musician.emoji,
                    style: const TextStyle(fontSize: 40),
                  )
                : null,
          ),
          Positioned(
            bottom: 0,
            right: 0,
            child: Container(
              width: 28,
              height: 28,
              decoration: const BoxDecoration(
                color: kGold,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.camera_alt,
                size: 14,
                color: Color(0xFF1A0E00),
              ),
            ),
          ),
        ],
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

  Widget _buildNameField() {
    return TextField(
      controller: _nameController,
      style: const TextStyle(color: kText, fontSize: 15),
      decoration: _inputDecoration('Adınızı daxil edin'),
    );
  }

  Widget _buildBioField() {
    return TextField(
      controller: _bioController,
      maxLines: 4,
      style: const TextStyle(color: kText, fontSize: 14),
      decoration: _inputDecoration('Özünüz haqqında qısa məlumat'),
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

  Widget _buildAvailabilityToggle() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      decoration: BoxDecoration(
        color: kCard,
        border: Border.all(color: kBorder),
        borderRadius: BorderRadius.circular(14),
      ),
      child: SwitchListTile(
        contentPadding: EdgeInsets.zero,
        activeThumbColor: kGold,
        title: const Text(
          'İşə hazıram',
          style: TextStyle(color: kText, fontSize: 14),
        ),
        value: _available,
        onChanged: (v) => setState(() => _available = v),
      ),
    );
  }

  InputDecoration _inputDecoration(String hint) {
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: kMuted, fontSize: 15),
      filled: true,
      fillColor: kCard,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: 16,
        vertical: 14,
      ),
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
}
