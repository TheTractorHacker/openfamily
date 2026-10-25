import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../models/user_profile.dart';
import '../services/api_client.dart';
import '../theme/app_theme.dart';

/// The authenticated user's account profile and private profile photo.
///
/// Photos are selected from the device gallery, resized before reading when the
/// platform supports it, and uploaded as raw authenticated bytes. This screen
/// intentionally does not use a public avatar URL or persist a local file path.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  static const double _pickerMaxDimension = 1600;

  final ImagePicker _imagePicker = ImagePicker();
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _currentPasswordController =
      TextEditingController();
  final TextEditingController _newPasswordController = TextEditingController();
  final TextEditingController _confirmPasswordController =
      TextEditingController();

  UserProfile? _profile;
  Uint8List? _avatarBytes;
  Uint8List? _pendingAvatarBytes;
  bool _loading = true;
  bool _avatarSaving = false;
  bool _nameSaving = false;
  bool _nameDirty = false;
  int _profileLoadGeneration = 0;
  String? _error;
  String? _avatarError;
  String? _nameError;
  String? _passwordError;
  bool _passwordSaving = false;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    _currentPasswordController.dispose();
    _newPasswordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _changePassword() async {
    final String current = _currentPasswordController.text;
    final String next = _newPasswordController.text;
    final String confirm = _confirmPasswordController.text;
    if (current.isEmpty || next.isEmpty || confirm.isEmpty) {
      setState(() => _passwordError = 'Fill in all password fields.');
      return;
    }
    if (next.length < 8) {
      setState(() => _passwordError = 'New password must be at least 8 characters.');
      return;
    }
    if (next != confirm) {
      setState(() => _passwordError = 'New passwords do not match.');
      return;
    }
    setState(() {
      _passwordSaving = true;
      _passwordError = null;
    });
    try {
      await ApiClient.changePassword(
        currentPassword: current,
        newPassword: next,
      );
      if (!mounted) return;
      _currentPasswordController.clear();
      _newPasswordController.clear();
      _confirmPasswordController.clear();
      setState(() => _passwordSaving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Password updated. Other devices will need to sign in again.')),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _passwordSaving = false;
        _passwordError = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _passwordSaving = false;
        _passwordError = 'Could not change password. Try again.';
      });
    }
  }

  Future<void> _loadProfile() async {
    // Avoid a pull-to-refresh racing an in-flight save and replacing a local
    // preview or name edit with a stale server response.
    if (_avatarSaving || _nameSaving) return;

    final int generation = ++_profileLoadGeneration;

    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
        _avatarError = null;
      });
    }

    try {
      final UserProfile profile = await ApiClient.getProfile();
      if (!mounted || generation != _profileLoadGeneration) return;
      Uint8List? avatarBytes;
      String? avatarError;

      if (profile.hasAvatar) {
        try {
          avatarBytes = await ApiClient.getProfileAvatar();
        } on SessionExpiredException {
          // ApiClient has already started the root redirect to login.
          rethrow;
        } on ApiException catch (error) {
          // A profile can still be useful if just its image is temporarily
          // unavailable. Keep identity details on screen and offer retry.
          avatarError = error.message;
        } catch (_) {
          avatarError = 'Couldn\'t load your profile photo. Please try again.';
        }
      }

      if (!mounted || generation != _profileLoadGeneration) return;
      setState(() {
        // A 404 means the profile metadata was stale, but a transient image
        // request failure should not hide the available Change/Remove actions.
        _profile = profile.copyWith(
          hasAvatar:
              avatarError == null ? avatarBytes != null : profile.hasAvatar,
        );
        if (!_nameDirty) {
          _nameController.value = TextEditingValue(
            text: profile.name,
            selection: TextSelection.collapsed(offset: profile.name.length),
          );
          final String phone = profile.phone ?? '';
          _phoneController.value = TextEditingValue(
            text: phone,
            selection: TextSelection.collapsed(offset: phone.length),
          );
        }
        _avatarBytes = avatarBytes;
        _loading = false;
        _avatarError = avatarError;
      });
    } on SessionExpiredException {
      // ApiClient has already started the root redirect to login.
      return;
    } on ApiException catch (error) {
      if (!mounted || generation != _profileLoadGeneration) return;
      setState(() {
        _loading = false;
        _error = error.message;
      });
    } catch (_) {
      if (!mounted || generation != _profileLoadGeneration) return;
      setState(() {
        _loading = false;
        _error = 'Couldn\'t load your profile. Please try again.';
      });
    }
  }

  Future<void> _saveName() async {
    if (_avatarSaving || _nameSaving) return;

    final String name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _nameError = 'Name is required.');
      return;
    }

    setState(() {
      // An older profile GET must not overwrite this new name when it finishes.
      _profileLoadGeneration++;
      _nameSaving = true;
      _nameError = null;
    });

    try {
      final dynamic response = await ApiClient.patch(
        '/me',
        body: <String, dynamic>{
          'name': name,
          'phone': _phoneController.text.trim(),
        },
      );
      final Map<String, dynamic> updated = response as Map<String, dynamic>;
      final String savedName = updated['name'] as String? ?? name;
      final String? savedPhone = updated['phone'] as String?;
      if (!mounted) return;
      setState(() {
        _profile = _profile?.copyWith(
          name: savedName,
          phone: savedPhone,
          clearPhone: savedPhone == null,
        );
        _nameController.value = TextEditingValue(
          text: savedName,
          selection: TextSelection.collapsed(offset: savedName.length),
        );
        final String phoneText = savedPhone ?? '';
        _phoneController.value = TextEditingValue(
          text: phoneText,
          selection: TextSelection.collapsed(offset: phoneText.length),
        );
        _nameDirty = false;
        _nameSaving = false;
      });
      _showSnackBar('Profile updated.');
    } on SessionExpiredException {
      // ApiClient has already started the root redirect to login.
      return;
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _nameSaving = false;
        _nameError = error.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _nameSaving = false;
        _nameError = 'Couldn\'t update your profile. Please try again.';
      });
    }
  }

  Future<void> _chooseAndUploadAvatar() async {
    if (_loading || _avatarSaving || _nameSaving) return;

    try {
      final XFile? image = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        maxWidth: _pickerMaxDimension,
        maxHeight: _pickerMaxDimension,
        // Smaller, appropriately sized uploads are friendlier to both a
        // mobile connection and the 5 MiB API limit. PNGs may remain large,
        // so their byte size is always checked below.
        imageQuality: 85,
        requestFullMetadata: false,
      );
      if (image == null) return;

      // Reject a large picker result before reading it fully into memory. The
      // byte check below remains necessary because this is still an external
      // platform result.
      final int length = await image.length();
      if (!mounted) return;
      if (length <= 0 || length > ApiClient.maxProfileAvatarBytes) {
        _setAvatarError('Profile photos must be 5 MB or smaller.');
        return;
      }

      final Uint8List bytes = await image.readAsBytes();
      if (!mounted) return;

      final String? contentType = _avatarContentType(bytes);
      if (contentType == null) {
        _setAvatarError('Choose a JPEG or PNG image.');
        return;
      }
      if (bytes.isEmpty || bytes.length > ApiClient.maxProfileAvatarBytes) {
        _setAvatarError('Profile photos must be 5 MB or smaller.');
        return;
      }

      // Show a local byte preview as soon as the selection is valid, while the
      // upload is in progress. If uploading fails it is rolled back below.
      setState(() {
        // Any older refresh must not overwrite the selected-image preview.
        _profileLoadGeneration++;
        _pendingAvatarBytes = bytes;
        _avatarSaving = true;
        _avatarError = null;
      });

      await ApiClient.uploadProfileAvatar(
        bytes: bytes,
        contentType: contentType,
      );
      if (!mounted) return;
      setState(() {
        _avatarBytes = bytes;
        _pendingAvatarBytes = null;
        _avatarSaving = false;
        _profile = _profile?.copyWith(
          hasAvatar: true,
          avatarUpdatedAt: DateTime.now().toUtc(),
        );
      });
      _showSnackBar('Profile photo updated.');
    } on SessionExpiredException {
      // ApiClient has already started the root redirect to login.
      return;
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _pendingAvatarBytes = null;
        _avatarSaving = false;
        _avatarError = error.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _pendingAvatarBytes = null;
        _avatarSaving = false;
        _avatarError = 'Couldn\'t update your profile photo. Please try again.';
      });
    }
  }

  Future<void> _removeAvatar() async {
    if (_avatarSaving || _nameSaving || _profile?.hasAvatar != true) return;

    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Remove profile photo?'),
        content: const Text(
          'Your photo will be removed from this device view and your server.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.sosRed,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      // Any older refresh must not reintroduce the avatar while deletion is
      // in progress.
      _profileLoadGeneration++;
      _avatarSaving = true;
      _avatarError = null;
    });
    try {
      await ApiClient.deleteProfileAvatar();
      if (!mounted) return;
      setState(() {
        _avatarBytes = null;
        _pendingAvatarBytes = null;
        _avatarSaving = false;
        _profile = _profile?.copyWith(
          hasAvatar: false,
          clearAvatarUpdatedAt: true,
        );
      });
      _showSnackBar('Profile photo removed.');
    } on SessionExpiredException {
      // ApiClient has already started the root redirect to login.
      return;
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _avatarSaving = false;
        _avatarError = error.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _avatarSaving = false;
        _avatarError = 'Couldn\'t remove your profile photo. Please try again.';
      });
    }
  }

  void _setAvatarError(String message) {
    if (!mounted) return;
    setState(() => _avatarError = message);
  }

  void _onNameChanged(String _) {
    if (_nameDirty && _nameError == null) return;
    setState(() {
      _nameDirty = true;
      _nameError = null;
    });
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// Identifies only the two API-supported formats from their bytes. A file
  /// extension or picker MIME label can be misleading, so neither is trusted.
  static String? _avatarContentType(Uint8List bytes) {
    final bool jpeg = bytes.length >= 3 &&
        bytes[0] == 0xff &&
        bytes[1] == 0xd8 &&
        bytes[2] == 0xff;
    if (jpeg) return 'image/jpeg';

    final bool png = bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4e &&
        bytes[3] == 0x47 &&
        bytes[4] == 0x0d &&
        bytes[5] == 0x0a &&
        bytes[6] == 0x1a &&
        bytes[7] == 0x0a;
    return png ? 'image/png' : null;
  }

  @override
  Widget build(BuildContext context) {
    final UserProfile? profile = _profile;
    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : profile == null
              ? _ProfileLoadError(message: _error, onRetry: _loadProfile)
              : RefreshIndicator(
                  onRefresh: _loadProfile,
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(
                        AppSpace.xxl, AppSpace.xxl, AppSpace.xxl, AppSpace.xxxl),
                    children: [
                      _AvatarEditor(
                        name: profile.name,
                        avatarBytes: _pendingAvatarBytes ?? _avatarBytes,
                        saving: _avatarSaving,
                      ),
                      const SizedBox(height: 20),
                      TextField(
                        controller: _nameController,
                        enabled: !_nameSaving && !_avatarSaving,
                        textCapitalization: TextCapitalization.words,
                        onChanged: _onNameChanged,
                        decoration: const InputDecoration(
                          labelText: 'Name',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _phoneController,
                        enabled: !_nameSaving && !_avatarSaving,
                        keyboardType: TextInputType.phone,
                        onChanged: _onNameChanged,
                        decoration: const InputDecoration(
                          labelText: 'Phone (SMS alerts)',
                          hintText: '+15551234567',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      if (_nameError != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          _nameError!,
                          style: const TextStyle(color: AppColors.sosRed),
                        ),
                      ],
                      const SizedBox(height: 12),
                      FilledButton(
                        onPressed:
                            _nameSaving || _avatarSaving ? null : _saveName,
                        child: _nameSaving
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Text('Save changes'),
                      ),
                      const SizedBox(height: 16),
                      InputDecorator(
                        decoration: const InputDecoration(
                          labelText: 'Email',
                          border: OutlineInputBorder(),
                        ),
                        child: Text(profile.email),
                      ),
                      const SizedBox(height: 16),
                      InputDecorator(
                        decoration: const InputDecoration(
                          labelText: 'Family role',
                          border: OutlineInputBorder(),
                        ),
                        child: Text(_roleLabel(profile.role)),
                      ),
                      const SizedBox(height: 20),
                      Wrap(
                        alignment: WrapAlignment.center,
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          OutlinedButton.icon(
                            onPressed: _avatarSaving || _nameSaving
                                ? null
                                : _chooseAndUploadAvatar,
                            icon: const Icon(Icons.photo_library_outlined),
                            label: Text(
                              !profile.hasAvatar ? 'Add photo' : 'Change photo',
                            ),
                          ),
                          if (profile.hasAvatar)
                            TextButton.icon(
                              onPressed: _avatarSaving || _nameSaving
                                  ? null
                                  : _removeAvatar,
                              icon: const Icon(Icons.delete_outline),
                              label: const Text('Remove photo'),
                              style: TextButton.styleFrom(
                                foregroundColor: AppColors.sosRed,
                              ),
                            ),
                        ],
                      ),
                      if (_avatarError != null) ...[
                        const SizedBox(height: 16),
                        _AvatarError(
                          message: _avatarError!,
                          onRetry: _loadProfile,
                        ),
                      ],
                      const SizedBox(height: 28),
                      const Divider(),
                      const SizedBox(height: 16),
                      Text('Change password', style: AppType.headline),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _currentPasswordController,
                        obscureText: true,
                        decoration: const InputDecoration(
                          labelText: 'Current password',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _newPasswordController,
                        obscureText: true,
                        decoration: const InputDecoration(
                          labelText: 'New password',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _confirmPasswordController,
                        obscureText: true,
                        decoration: const InputDecoration(
                          labelText: 'Confirm new password',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      if (_passwordError != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          _passwordError!,
                          style: const TextStyle(color: AppColors.sosRed),
                        ),
                      ],
                      const SizedBox(height: 12),
                      OutlinedButton(
                        onPressed: _passwordSaving ? null : _changePassword,
                        child: _passwordSaving
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Text('Update password'),
                      ),
                      const SizedBox(height: 28),
                      const Divider(),
                      const SizedBox(height: 16),
                      Text('Profile photo privacy', style: AppType.headline),
                      const SizedBox(height: 6),
                      Text(
                        'Your photo is stored privately on your OpenFamily server '
                        'and shared only with authenticated family members and '
                        'platform administrators.',
                        style: AppType.secondary.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
    );
  }

  static String _roleLabel(String role) {
    if (role.isEmpty) return 'Member';
    return role
        .split(RegExp(r'\s+|_|-'))
        .where((String word) => word.isNotEmpty)
        .map((String word) => '${word[0].toUpperCase()}${word.substring(1)}')
        .join(' ');
  }
}

class _AvatarEditor extends StatelessWidget {
  const _AvatarEditor({
    required this.name,
    required this.avatarBytes,
    required this.saving,
  });

  final String name;
  final Uint8List? avatarBytes;
  final bool saving;

  @override
  Widget build(BuildContext context) {
    final BrandTheme brand = BrandTheme.of(context);
    final String initials = _initials(name);
    final String semanticLabel = avatarBytes == null
        ? 'No profile photo. Initials $initials.'
        : 'Profile photo for $name.';
    return Center(
      child: Semantics(
        image: true,
        label: saving ? '$semanticLabel Uploading.' : semanticLabel,
        child: SizedBox(
          width: 120,
          height: 120,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: 112,
                height: 112,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: brand.paper,
                  border: Border.all(color: brand.accent, width: 3),
                ),
                child: ClipOval(
                  child: avatarBytes == null
                      ? Center(
                          child: Text(
                            initials,
                            style: TextStyle(
                              color: brand.accentInk,
                              fontSize: 38,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        )
                      : Image.memory(
                          avatarBytes!,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => Center(
                            child: Text(
                              initials,
                              style: TextStyle(
                                color: brand.accentInk,
                                fontSize: 38,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ),
                ),
              ),
              if (saving)
                Container(
                  width: 112,
                  height: 112,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.black.withValues(alpha: 0.35),
                  ),
                  child: const Center(
                    child: SizedBox(
                      width: 28,
                      height: 28,
                      child: CircularProgressIndicator(
                        strokeWidth: 3,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  static String _initials(String name) {
    final List<String> parts = name.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) return '?';
    if (parts.length == 1) return parts.first[0].toUpperCase();
    return (parts.first[0] + parts.last[0]).toUpperCase();
  }
}

class _AvatarError extends StatelessWidget {
  const _AvatarError({required this.message, required this.onRetry});

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.sosRed.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: AppColors.sosRed),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(color: AppColors.sosRed),
            ),
          ),
          TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}

class _ProfileLoadError extends StatelessWidget {
  const _ProfileLoadError({required this.message, required this.onRetry});

  final String? message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: AppColors.sosRed, size: 36),
            const SizedBox(height: 12),
            Text(
              message ?? 'Couldn\'t load your profile. Please try again.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.sosRed),
            ),
            const SizedBox(height: 12),
            FilledButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}
