import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:logger/logger.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sms_autofill/sms_autofill.dart';
import '../theme.dart';

final riderProfileProvider = StreamProvider<DocumentSnapshot<Object?>?>((ref) {
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) return Stream.value(null);
  return FirebaseFirestore.instance
      .collection('users')
      .doc(user.uid)
      .snapshots();
});

class RiderProfilePage extends ConsumerStatefulWidget {
  const RiderProfilePage({super.key});
  @override
  ConsumerState<RiderProfilePage> createState() => _RiderProfilePageState();
}

class OtpInputField extends StatefulWidget {
  final int length;
  final void Function(String) onCompleted;
  final bool enabled;
  const OtpInputField({
    super.key,
    this.length = 6,
    required this.onCompleted,
    this.enabled = true,
  });

  @override
  State<OtpInputField> createState() => _OtpInputFieldState();
}

class _OtpInputFieldState extends State<OtpInputField> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      enabled: widget.enabled,
      controller: _controller,
      keyboardType: TextInputType.number,
      maxLength: widget.length,
      textAlign: TextAlign.center,
      style: const TextStyle(letterSpacing: 20, fontSize: 20),
      decoration: InputDecoration(
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        counterText: "",
        prefixIcon: const Icon(Icons.lock),
        filled: true,
        fillColor: Theme.of(context).colorScheme.surfaceContainer,
      ),
      onChanged: (value) {
        if (value.length == widget.length) {
          widget.onCompleted(value);
        }
      },
    ).animate().fadeIn(duration: 400.ms);
  }
}

class _RiderProfilePageState extends ConsumerState<RiderProfilePage> with CodeAutoFill {
  final _logger = Logger();
  final _nameController = TextEditingController();
  final _homeController = TextEditingController();
  final _workController = TextEditingController();
  final _phoneController = TextEditingController();
  bool _isEditing = false;
  bool _isLoading = false;
  bool _isDialogLoading = false;
  String? _localPhotoPath;
  String? _cnicNumber;
  String? _originalPhone;
  bool _isOtpSent = false;
  String? _verificationId;
  String _enteredOtp = "";
  bool _canResend = false;
  int _resendSeconds = 60;
  Timer? _resendTimer;
  String? _pendingPhone;

  @override
  void initState() {
    super.initState();
    listenForCode();
  }

  @override
  void codeUpdated() {
    final received = code ?? '';
    if (received.isEmpty) return;

    final clean = received.replaceAll(RegExp(r'\D'), '');
    setState(() => _enteredOtp = clean);

    if (clean.length >= 6) {
      _confirmOtp(isAutoFilled: true);
    }
  }

  Future<String> _getProfileFilePath() async {
    final dir = await getApplicationDocumentsDirectory();
    return '${dir.path}/profile_${FirebaseAuth.instance.currentUser?.uid}.json';
  }

  Future<void> _loadProfileImage() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    try {
      final dir = await getApplicationDocumentsDirectory();
      final photoPath = '${dir.path}/profile_${user.uid}.jpg';
      if (File(photoPath).existsSync()) {
        setState(() {
          _localPhotoPath = photoPath;
        });
      }
    } catch (e) {
      _logger.e('Failed to load profile image: $e');
    }
  }

  Future<void> _pickAndSavePhoto() async {
    try {
      final picker = ImagePicker();
      final picked = await picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 512,
        maxHeight: 512,
        imageQuality: 85,
      );
      if (picked == null) return;

      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;

      final dir = await getApplicationDocumentsDirectory();
      final filePath = '${dir.path}/profile_${user.uid}.jpg';
      final file = File(filePath);
      await file.writeAsBytes(await picked.readAsBytes());

      setState(() => _localPhotoPath = filePath);

      if (mounted) {
        showSuccess('Profile picture updated');
      }
    } catch (e) {
      _logger.e('Photo save failed: $e');
      if (mounted) {
        showError('Failed to update photo: $e');
      }
    }
  }

  void showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: Theme.of(context).colorScheme.error,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  void showSuccess(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: Theme.of(context).colorScheme.primary,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  String formatPhoneNumber(String input) {
    final digits = input.replaceAll(RegExp(r'\D'), '');
    if (digits.length != 11 || !digits.startsWith('03')) {
      throw Exception("Must be 11 digits starting with 03");
    }
    return '+92${digits.substring(1)}';
  }

  String maskPhoneNumber(String phone) {
    if (phone.length < 12) return phone;
    return '+92XXXXXXX${phone.substring(9)}';
  }

  Future<bool> phoneNumberExists(String phone, String currentUid) async {
    final digitsOnly = phone.replaceAll(RegExp(r'\D'), '');
    final snap = await FirebaseFirestore.instance
        .collection('phones')
        .doc(digitsOnly)
        .get();
    if (snap.exists) {
      final data = snap.data() as Map<String, dynamic>;
      return data['uid'] != currentUid;
    }
    return false;
  }

  void startResendTimer() {
    _resendTimer?.cancel();
    setState(() {
      _canResend = false;
      _resendSeconds = 60;
    });
    _resendTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_resendSeconds == 0) {
        timer.cancel();
        setState(() => _canResend = true);
      } else {
        setState(() => _resendSeconds--);
      }
    });
  }

  Future<bool> _showOtpConfirmationDialog(String phoneNumber) async {
    final maskedPhone = maskPhoneNumber(phoneNumber);
    return await showDialog<bool>(
          context: context,
          barrierDismissible: !_isDialogLoading,
          builder: (context) => AlertDialog(
            title: const Text('Verify New Phone Number'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Send OTP to $maskedPhone to verify your new phone number?'),
                if (_isDialogLoading) ...[
                  const SizedBox(height: 16),
                  const CircularProgressIndicator(),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: _isDialogLoading ? null : () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: _isDialogLoading ? null : () => Navigator.pop(context, true),
                child: const Text('Confirm'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _sendOtp(String phoneNumber) async {
    if (_isLoading) return;
    setState(() {
      _isLoading = true;
      _isDialogLoading = true;
    });

    try {
      await FirebaseAuth.instance.verifyPhoneNumber(
        phoneNumber: phoneNumber,
        timeout: const Duration(seconds: 60),
        verificationCompleted: (PhoneAuthCredential credential) async {
          await _confirmOtp(autoCredential: credential, isAutoFilled: true);
        },
        verificationFailed: (FirebaseAuthException e) {
          showError(e.message ?? 'OTP verification failed');
          setState(() {
            _isLoading = false;
            _isOtpSent = false;
            _pendingPhone = null;
            _isDialogLoading = false;
          });
        },
        codeSent: (id, _) {
          setState(() {
            _verificationId = id;
            _isOtpSent = true;
            _pendingPhone = phoneNumber;
            _isDialogLoading = false;
          });
          startResendTimer();
        },
        codeAutoRetrievalTimeout: (id) => _verificationId = id,
      );
    } catch (e) {
      showError('Unexpected error sending OTP: $e');
      setState(() {
        _isLoading = false;
        _isOtpSent = false;
        _pendingPhone = null;
        _isDialogLoading = false;
      });
    } finally {
      if (!_isOtpSent) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _confirmOtp({PhoneAuthCredential? autoCredential, required bool isAutoFilled}) async {
    if (_isLoading || _pendingPhone == null) return;
    setState(() => _isLoading = true);

    try {
      if (autoCredential == null && _enteredOtp.length != 6) {
        showError('Please enter the full OTP');
        setState(() => _isLoading = false);
        return;
      }

      if (_verificationId == null && autoCredential == null) {
        showError('Verification ID missing. Please resend OTP.');
        setState(() => _isLoading = false);
        return;
      }

      final credential = autoCredential ??
          PhoneAuthProvider.credential(
            verificationId: _verificationId!,
            smsCode: _enteredOtp,
          );

      try {
        await FirebaseAuth.instance.currentUser!.updatePhoneNumber(credential);
        await _completeProfileUpdate();
      } on FirebaseAuthException catch (e) {
        if (isAutoFilled && e.code == 'invalid-verification-code') {
          showError('Auto-filled OTP is invalid. Please enter manually.');
          setState(() => _isLoading = false);
        } else {
          rethrow;
        }
      }
    } catch (e) {
      showError('OTP verification failed: $e');
      setState(() {
        _isLoading = false;
        _isOtpSent = false;
        _pendingPhone = null;
      });
    }
  }

  Future<void> _completeProfileUpdate() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      showError('No user logged in');
      setState(() {
        _isLoading = false;
        _isOtpSent = false;
        _pendingPhone = null;
      });
      return;
    }

    try {
      final primaryDigits = _phoneController.text.replaceAll(RegExp(r'\D'), '');

      // Update Firebase Auth displayName
      await user.updateDisplayName(_nameController.text.trim());

      // Prepare Firestore update data
      final updateData = {
        'username': _nameController.text.trim(),
        'phone': primaryDigits,
        'savedLocations': {
          'home': _homeController.text.trim(),
          'work': _workController.text.trim(),
        },
      };

      // Update phones collection
      if (_originalPhone != null && _originalPhone != primaryDigits) {
        await FirebaseFirestore.instance
            .collection('phones')
            .doc(_originalPhone)
            .delete();
      }
      await FirebaseFirestore.instance
          .collection('phones')
          .doc(primaryDigits)
          .set({'uid': user.uid, 'type': 'primary'});

      // Update users collection
      await FirebaseFirestore.instance.collection('users').doc(user.uid).set(updateData, SetOptions(merge: true));

      // Update local JSON for backward compatibility
      final profileFilePath = await _getProfileFilePath();
      final profileFile = File(profileFilePath);
      final profileData = {
        'username': _nameController.text.trim(),
        'savedLocations': {
          'home': _homeController.text.trim(),
          'work': _workController.text.trim(),
        },
      };
      await profileFile.writeAsString(jsonEncode(profileData));

      // Refresh UI
      ref.invalidate(riderProfileProvider);

      setState(() {
        _isEditing = false;
        _isOtpSent = false;
        _pendingPhone = null;
        _originalPhone = primaryDigits;
        _enteredOtp = "";
        _verificationId = null;
        _resendTimer?.cancel();
      });

      showSuccess('Profile updated successfully');
    } catch (e) {
      _logger.e('Failed to save profile: $e');
      showError('Failed to save profile: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _saveProfile() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      showError('No user logged in');
      return;
    }

    // Validate name
    if (_nameController.text.trim().isEmpty) {
      showError('Name cannot be empty');
      return;
    }

    // Validate phone number
    String? primaryPhoneFormatted;
    try {
      primaryPhoneFormatted = formatPhoneNumber(_phoneController.text);
    } catch (e) {
      showError('Phone number: $e');
      return;
    }

    final primaryDigits = primaryPhoneFormatted.replaceAll('+92', '0');

    // Check for duplicate phone number
    if (primaryDigits != _originalPhone && await phoneNumberExists(primaryPhoneFormatted, user.uid)) {
      showError('Phone number is already registered');
      return;
    }

    // Trigger OTP if phone number changed
    if (primaryDigits != _originalPhone) {
      final shouldSendOtp = await _showOtpConfirmationDialog(primaryPhoneFormatted);
      if (shouldSendOtp) {
        await _sendOtp(primaryPhoneFormatted);
      } else {
        setState(() {
          _isLoading = false;
          _isDialogLoading = false;
        });
      }
    } else {
      await _completeProfileUpdate();
    }
  }

  void _cancelEdit() {
    setState(() {
      _isEditing = false;
      _isOtpSent = false;
      _pendingPhone = null;
      _enteredOtp = "";
      _verificationId = null;
      _resendTimer?.cancel();
    });
    ref.invalidate(riderProfileProvider); // Reset controllers to Firestore values
  }

  @override
  void dispose() {
    _nameController.dispose();
    _homeController.dispose();
    _workController.dispose();
    _phoneController.dispose();
    _resendTimer?.cancel();
    cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final profileAsync = ref.watch(riderProfileProvider);
    final imageFile = _localPhotoPath != null ? File(_localPhotoPath!) : null;
    final theme = Theme.of(context).copyWith(
      colorScheme: femLightTheme.colorScheme,
      cardTheme: femLightTheme.cardTheme,
      elevatedButtonTheme: femLightTheme.elevatedButtonTheme,
    );

    return Theme(
      data: theme,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Rider Profile'),
          actions: [
            if (_isEditing)
              TextButton(
                onPressed: _cancelEdit,
                child: const Text('Cancel'),
              ),
            IconButton(
              icon: Icon(_isEditing && !_isOtpSent ? Icons.save : Icons.edit),
              onPressed: _isLoading
                  ? null
                  : () {
                      if (_isEditing && !_isOtpSent) {
                        _saveProfile();
                      } else if (!_isOtpSent) {
                        setState(() => _isEditing = true);
                      }
                    },
            ),
            IconButton(
              icon: const Icon(Icons.logout),
              onPressed: () async {
                final shouldLogout = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Logout'),
                    content: const Text('Are you sure you want to logout?'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Cancel'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('Logout'),
                      ),
                    ],
                  ),
                );
                if (shouldLogout == true) {
                  await FirebaseAuth.instance.signOut();
                  // ignore: use_build_context_synchronously
                  if (mounted) Navigator.of(context).pop();
                }
              },
            ),
          ],
        ),
        body: Stack(
          children: [
            profileAsync.when(
              data: (doc) {
                if (doc == null || !doc.exists) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.error_outline, size: 64, color: Colors.grey),
                        const SizedBox(height: 16),
                        const Text('Profile not found'),
                        const SizedBox(height: 16),
                        ElevatedButton.icon(
                          onPressed: () => ref.refresh(riderProfileProvider),
                          icon: const Icon(Icons.refresh),
                          label: const Text('Retry'),
                        ),
                      ],
                    ),
                  );
                }
                final data = doc.data() as Map<String, dynamic>;

                if (!_isEditing) {
                  _nameController.text = data['username'] ?? '';
                  _homeController.text = data['savedLocations']?['home'] ?? '';
                  _workController.text = data['savedLocations']?['work'] ?? '';
                  _phoneController.text = data['phone'] ?? '';
                  _originalPhone = data['phone'] ?? '';
                  _cnicNumber = data['cnicNumber'] ?? '';
                }

                _loadProfileImage();

                return SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      GestureDetector(
                        onTap: _isEditing ? _pickAndSavePhoto : null,
                        child: Stack(
                          alignment: Alignment.bottomRight,
                          children: [
                            CircleAvatar(
                              radius: 60,
                              backgroundColor: theme.colorScheme.primaryContainer,
                              backgroundImage: imageFile != null && imageFile.existsSync()
                                  ? FileImage(imageFile)
                                  : null,
                              child: imageFile == null
                                  ? Icon(
                                      Icons.person,
                                      size: 60,
                                      color: theme.colorScheme.onPrimaryContainer,
                                    )
                                  : null,
                            ),
                            if (_isEditing)
                              Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: theme.colorScheme.primary,
                                  shape: BoxShape.circle,
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withValues(alpha: 0.7),
                                      blurRadius: 4,
                                      offset: const Offset(0, 2),
                                    ),
                                  ],
                                ),
                                child: const Icon(Icons.camera_alt, color: Colors.white, size: 20),
                              ),
                          ],
                        ),
                      ).animate().fadeIn(duration: 400.ms).scale(delay: 100.ms),
                      const SizedBox(height: 8),
                      if (_isEditing)
                        Text(
                          'Tap to change photo',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.primary,
                          ),
                        ).animate().fadeIn(),
                      const SizedBox(height: 24),
                      Card(
                        elevation: 2,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    Icons.person_outline,
                                    color: theme.colorScheme.primary,
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    'Personal Information',
                                    style: theme.textTheme.titleMedium?.copyWith(
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 16),
                              TextField(
                                controller: _nameController,
                                decoration: const InputDecoration(
                                  labelText: 'Name',
                                  border: OutlineInputBorder(),
                                  prefixIcon: Icon(Icons.person),
                                ),
                                enabled: _isEditing && !_isOtpSent,
                              ),
                              const SizedBox(height: 12),
                              TextField(
                                controller: _phoneController,
                                decoration: const InputDecoration(
                                  labelText: 'Phone Number',
                                  border: OutlineInputBorder(),
                                  prefixIcon: Icon(Icons.phone),
                                ),
                                enabled: _isEditing && !_isOtpSent,
                                keyboardType: TextInputType.phone,
                              ),
                              const SizedBox(height: 12),
                              TextField(
                                controller: TextEditingController(text: _cnicNumber),
                                decoration: const InputDecoration(
                                  labelText: 'CNIC Number',
                                  border: OutlineInputBorder(),
                                  prefixIcon: Icon(Icons.card_membership),
                                ),
                                enabled: false,
                              ),
                              if (_isOtpSent) ...[
                                const SizedBox(height: 16),
                                Text(
                                  'Enter OTP sent to ${maskPhoneNumber(_pendingPhone!)}',
                                  style: theme.textTheme.titleMedium,
                                ),
                                const SizedBox(height: 16),
                                OtpInputField(
                                  length: 6,
                                  enabled: !_isLoading,
                                  onCompleted: (code) => setState(() => _enteredOtp = code),
                                ),
                                const SizedBox(height: 16),
                                ElevatedButton(
                                  onPressed: _isLoading || _enteredOtp.length != 6
                                      ? null
                                      : () => _confirmOtp(isAutoFilled: false),
                                  style: ElevatedButton.styleFrom(
                                    minimumSize: const Size(double.infinity, 48),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                  ),
                                  child: _isLoading
                                      ? const CircularProgressIndicator()
                                      : const Text('Confirm OTP'),
                                ).animate().fadeIn(duration: 400.ms, delay: 200.ms),
                                const SizedBox(height: 16),
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                      _canResend ? 'Resend OTP' : 'Resend in $_resendSeconds seconds',
                                      style: TextStyle(
                                        color: _canResend
                                            ? theme.colorScheme.primary
                                            : theme.colorScheme.onSurfaceVariant,
                                      ),
                                    ),
                                    TextButton(
                                      onPressed: (!_isLoading && _canResend)
                                          ? () => _sendOtp(_pendingPhone!)
                                          : null,
                                      child: const Text('Resend OTP'),
                                    ),
                                  ],
                                ).animate().fadeIn(duration: 400.ms, delay: 200.ms),
                                const SizedBox(height: 8),
                                TextButton(
                                  onPressed: _isLoading ? null : _cancelEdit,
                                  style: TextButton.styleFrom(
                                    foregroundColor: theme.colorScheme.error,
                                  ),
                                  child: const Text('Cancel'),
                                ).animate().fadeIn(duration: 400.ms, delay: 300.ms),
                              ],
                            ],
                          ),
                        ),
                      ).animate().fadeIn(duration: 400.ms).slideY(begin: 0.1, end: 0),
                      const SizedBox(height: 16),
                      Card(
                        elevation: 2,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    Icons.location_on_outlined,
                                    color: theme.colorScheme.primary,
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    'Saved Locations',
                                    style: theme.textTheme.titleMedium?.copyWith(
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 16),
                              TextField(
                                controller: _homeController,
                                decoration: const InputDecoration(
                                  labelText: 'Home Address',
                                  border: OutlineInputBorder(),
                                  prefixIcon: Icon(Icons.home),
                                ),
                                enabled: _isEditing && !_isOtpSent,
                                maxLines: 2,
                              ),
                              const SizedBox(height: 12),
                              TextField(
                                controller: _workController,
                                decoration: const InputDecoration(
                                  labelText: 'Work Address',
                                  border: OutlineInputBorder(),
                                  prefixIcon: Icon(Icons.work),
                                ),
                                enabled: _isEditing && !_isOtpSent,
                                maxLines: 2,
                              ),
                            ],
                          ),
                        ),
                      ).animate().fadeIn(duration: 400.ms, delay: 200.ms).slideY(begin: 0.1, end: 0),
                      if (_isLoading && !_isOtpSent)
                        Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            children: [
                              const CircularProgressIndicator(),
                              const SizedBox(height: 16),
                              Text(
                                'Saving profile...',
                                style: theme.textTheme.bodyMedium,
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                );
              },
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, stack) {
                _logger.e('Profile error: $e', error: e, stackTrace: stack);
                return Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.error_outline, size: 64, color: Colors.red),
                      const SizedBox(height: 16),
                      Text('Error loading profile', style: theme.textTheme.titleMedium),
                      const SizedBox(height: 8),
                      Text(
                        e.toString(),
                        style: theme.textTheme.bodySmall,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 16),
                      ElevatedButton.icon(
                        onPressed: () => ref.refresh(riderProfileProvider),
                        icon: const Icon(Icons.refresh),
                        label: const Text('Retry'),
                      ),
                    ],
                  ),
                );
              },
            ),
            if (_isLoading && _isOtpSent)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: LinearProgressIndicator(
                  minHeight: 4,
                  backgroundColor: theme.colorScheme.surfaceContainer,
                  valueColor: AlwaysStoppedAnimation<Color>(theme.colorScheme.primary),
                ),
              ).animate().fadeIn(duration: 300.ms),
          ],
        ),
      ),
    );
  }
}