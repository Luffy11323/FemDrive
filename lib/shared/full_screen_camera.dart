// ignore_for_file: use_build_context_synchronously, avoid_print

import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

class FullScreenCamera extends StatefulWidget {
  final bool isSelfie;
  const FullScreenCamera({super.key, this.isSelfie = false});

  @override
  State<FullScreenCamera> createState() => _FullScreenCameraState();
}

class _FullScreenCameraState extends State<FullScreenCamera>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  CameraController? _controller;
  List<CameraDescription>? _cameras;
  bool _isCameraReady = false;
  bool _isCapturing = false;
  bool _frontCamera = true;
  late CameraDescription _currentCamera;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initCamera();

    // Show privacy notice for selfie mode
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.isSelfie) {
        _showPrivacySheet();
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  void _showPrivacySheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return SafeArea(
          child: Container(
            margin: const EdgeInsets.all(12),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Selfie verification',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                const Text(
                  'We use your selfie to verify authenticity and protect our community. '
                  'Images are processed for face detection and trust scoring. '
                  'By continuing, you consent to this processing.',
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    TextButton(
                      onPressed: () => Navigator.of(ctx).pop(),
                      child: const Text('Cancel'),
                    ),
                    const Spacer(),
                    ElevatedButton(
                      onPressed: () => Navigator.of(ctx).pop(),
                      child: const Text('I Agree'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _initCamera() async {
    final status = await Permission.camera.request();
    if (status.isDenied || status.isPermanentlyDenied) {
      _showPermissionDialog();
      return;
    }

    try {
      _cameras = await availableCameras();
      if (_cameras == null || _cameras!.isEmpty) {
        _showError('No cameras available');
        return;
      }

      // Default to front for selfie, back for document
      final preferredDirection = widget.isSelfie
          ? CameraLensDirection.front
          : CameraLensDirection.back;

      _currentCamera = _cameras!.firstWhere(
        (c) => c.lensDirection == preferredDirection,
        orElse: () => _cameras!.first,
      );

      _frontCamera = _currentCamera.lensDirection == CameraLensDirection.front;

      await _initController(_currentCamera);
    } catch (e) {
      _showError('Camera initialization error: $e');
    }
  }

  Future<void> _initController(CameraDescription camera) async {
    _controller?.dispose();
    _controller = CameraController(
      camera,
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );

    try {
      await _controller!.initialize();
      if (mounted) {
        setState(() => _isCameraReady = true);
      }
    } catch (e) {
      _showError('Failed to start camera: $e');
    }
  }

  void _showPermissionDialog() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Camera Permission Required'),
        content: const Text(
            'Please enable camera access in settings to take your selfie.'),
        actions: [
          TextButton(
            onPressed: () {
              openAppSettings();
              Navigator.pop(context);
            },
            child: const Text('Open Settings'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  void _showError(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Theme.of(context).colorScheme.error,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      );
      Navigator.pop(context);
    }
  }

  Future<void> _flipCamera() async {
    if (_cameras == null || _cameras!.length < 2 || _isCapturing) return;

    setState(() => _isCameraReady = false);

    _frontCamera = !_frontCamera;
    final newDirection = _frontCamera
        ? CameraLensDirection.front
        : CameraLensDirection.back;

    final newCamera = _cameras!.firstWhere(
      (c) => c.lensDirection == newDirection,
      orElse: () => _cameras!.first,
    );

    _currentCamera = newCamera;
    await _initController(newCamera);
  }

  Future<void> _captureImage() async {
    if (_controller == null || !_controller!.value.isInitialized || _isCapturing) return;

    setState(() => _isCapturing = true);
    try {
      final XFile image = await _controller!.takePicture();
      final tempDir = await getTemporaryDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final fileType = widget.isSelfie ? 'selfie' : 'document';
      final tempPath = '${tempDir.path}/${fileType}_$timestamp.jpg';

      final compressed = await FlutterImageCompress.compressAndGetFile(
        image.path,
        tempPath,
        quality: 60,
        minWidth: 800,
        minHeight: 800,
        keepExif: false,
      );

      if (compressed != null && mounted) {
        Navigator.pop(context, File(compressed.path));
      } else {
        _showError('Failed to compress image');
      }
    } catch (e) {
      _showError('Failed to capture image: $e');
    } finally {
      if (mounted) {
        setState(() => _isCapturing = false);
      }
    }
  }

  Widget _buildCameraPreview() {
    if (!_isCameraReady || _controller == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(
              valueColor: AlwaysStoppedAnimation<Color>(
                Theme.of(context).colorScheme.primary,
              ),
            ).animate().fadeIn(duration: 400.ms),
            const SizedBox(height: 16),
            Text(
              'Initializing camera...',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ).animate().fadeIn(duration: 400.ms, delay: 200.ms),
          ],
        ),
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        // Camera Preview
        CameraPreview(_controller!).animate().fadeIn(duration: 400.ms),

        // Close Button
        Positioned(
          top: 40,
          left: 16,
          child: IconButton(
            icon: const Icon(Icons.close, color: Colors.white, size: 30),
            onPressed: () => Navigator.pop(context),
          ).animate().fadeIn(duration: 400.ms, delay: 100.ms),
        ),

        // Selfie Guide (Only for Selfie Mode)
        if (widget.isSelfie)
          Positioned(
            top: 100,
            left: 0,
            right: 0,
            child: Container(
              padding: const EdgeInsets.all(16),
              color: Colors.black54,
              child: const Text(
                'Center your face in the frame',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
            ).animate().fadeIn(duration: 400.ms, delay: 200.ms),
          ),

        // Face Frame
        Center(
          child: Container(
            width: MediaQuery.of(context).size.width * 0.9,
            height: MediaQuery.of(context).size.height * 0.4,
            decoration: BoxDecoration(
              border: Border.all(color: Colors.white, width: 2),
              borderRadius: BorderRadius.circular(8),
            ),
          ).animate().fadeIn(duration: 400.ms, delay: 300.ms),
        ),

        // Flip Button (only if 2+ cameras)
        if (_cameras != null && _cameras!.length > 1)
          Positioned(
            top: 40,
            right: 16,
            child: IconButton(
              icon: Icon(
                _frontCamera ? Icons.flip_camera_android : Icons.flip_camera_ios,
                color: Colors.white,
                size: 30,
              ),
              onPressed: _flipCamera,
              tooltip: 'Switch camera',
            ).animate().fadeIn(delay: 150.ms),
          ),

        // Capture Button
        Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: GestureDetector(
              onTap: _isCapturing ? null : _captureImage,
              child: Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.9),
                  border: Border.all(color: Colors.white, width: 4),
                ),
                child: AnimatedOpacity(
                  opacity: _isCapturing ? 0.4 : 1.0,
                  duration: const Duration(milliseconds: 300),
                  child: const Icon(
                    Icons.camera_alt,
                    color: Colors.white,
                    size: 40,
                  ),
                ),
              ),
            ).animate().scale(duration: 400.ms, delay: 400.ms),
          ),
        ),
      ],
    );
  }

  Widget _buildPrivacyNotice() {
    return Align(
      alignment: Alignment.bottomCenter,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.6),
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(16),
            topRight: Radius.circular(16),
          ),
        ),
        child: const Text(
          'Your selfie is used only for identity verification and stored securely on your device.',
          style: TextStyle(color: Colors.white, fontSize: 13),
          textAlign: TextAlign.center,
        ),
      ).animate().slideY(begin: 0.2, end: 0.0, duration: 400.ms, delay: 500.ms),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          _buildCameraPreview(),
          if (widget.isSelfie) _buildPrivacyNotice(),
        ],
      ),
    );
  }
}