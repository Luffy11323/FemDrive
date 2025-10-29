// ignore_for_file: use_build_context_synchronously, avoid_print

import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';

class FullScreenCamera extends StatefulWidget {
  final bool isSelfie;

  const FullScreenCamera({super.key, this.isSelfie = false});

  @override
  State<FullScreenCamera> createState() => _FullScreenCameraState();
}

class _FullScreenCameraState extends State<FullScreenCamera>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  CameraController? _controller;
  late List<CameraDescription> _cameras;
  bool _isCameraReady = false;
  bool _isCapturing = false;
  bool _frontCamera = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _initCamera() async {
    try {
      final status = await Permission.camera.request();
      if (!status.isGranted) {
        _showPermissionDialog();
        return;
      }

      _cameras = await availableCameras();

      // ✅ Default to front camera for selfies
      CameraDescription camera = _cameras.firstWhere(
        (c) =>
            c.lensDirection ==
            (widget.isSelfie
                ? CameraLensDirection.front
                : CameraLensDirection.back),
        orElse: () => _cameras.first,
      );

      _controller = CameraController(
        camera,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );

      await _controller!.initialize();
      setState(() => _isCameraReady = true);
    } catch (e) {
      print('Camera initialization error: $e');
    }
  }

  void _showPermissionDialog() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Camera Permission Required'),
        content: const Text(
          'Please enable camera access in settings to take your selfie.',
        ),
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

  Future<void> _flipCamera() async {
    if (_cameras.length < 2 || _controller == null) return;

    setState(() => _isCameraReady = false);

    _frontCamera = !_frontCamera;

    final newCamera = _cameras.firstWhere(
      (c) =>
          c.lensDirection ==
          (_frontCamera ? CameraLensDirection.front : CameraLensDirection.back),
      orElse: () => _cameras.first,
    );

    _controller = CameraController(
      newCamera,
      ResolutionPreset.high,
      enableAudio: false,
    );

    await _controller!.initialize();
    setState(() => _isCameraReady = true);
  }

  Future<void> _captureImage() async {
    if (_controller == null || !_controller!.value.isInitialized) return;
    if (_isCapturing) return;

    setState(() => _isCapturing = true);

    try {
      final file = await _controller!.takePicture();
      final directory = await getApplicationDocumentsDirectory();
      final savedPath =
          '${directory.path}/${DateTime.now().millisecondsSinceEpoch}.jpg';
      await file.saveTo(savedPath);

      Navigator.pop(context, File(savedPath));
    } catch (e) {
      print('Error capturing image: $e');
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Failed to capture image')));
    } finally {
      setState(() => _isCapturing = false);
    }
  }

  Widget _buildCameraPreview() {
    if (!_isCameraReady || _controller == null) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 12),
            Text('Accessing front camera…'),
          ],
        ),
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        CameraPreview(_controller!),
        Positioned(
          top: 40,
          left: 16,
          child: IconButton(
            icon: const Icon(Icons.close, color: Colors.white, size: 30),
            onPressed: () => Navigator.pop(context),
          ),
        ),
        Positioned(
          top: 40,
          right: 16,
          child: IconButton(
            icon: const Icon(
              Icons.flip_camera_android,
              color: Colors.white,
              size: 28,
            ),
            tooltip: 'Flip Camera',
            onPressed: _flipCamera,
          ),
        ),
        Positioned(
          bottom: 80,
          left: 0,
          right: 0,
          child: Center(
            child: GestureDetector(
              onTap: _captureImage,
              child: Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
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
            ),
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
          '🔒 Your selfie is used only for identity verification and stored securely on your device.',
          style: TextStyle(color: Colors.white, fontSize: 13),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [_buildCameraPreview(), _buildPrivacyNotice()],
      ),
    );
  }
}
