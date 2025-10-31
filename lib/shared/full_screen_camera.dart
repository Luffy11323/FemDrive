// ignore_for_file: use_build_context_synchronously, avoid_print

import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'dart:async';

// --- Camera Class 1: For Selfies ---

class FullScreenCamera extends StatefulWidget {
  final bool isSelfie;

  const FullScreenCamera({super.key, this.isSelfie = false});

  @override
  State<FullScreenCamera> createState() => _FullScreenCameraState();
}

class _FullScreenCameraState extends State<FullScreenCamera> {
  CameraController? _controller;
  List<CameraDescription>? _cameras;
  late CameraDescription _currentCamera;
  bool _isInitialized = false;
  bool _isTakingPicture = false;

  @override
  void initState() {
    super.initState();
    _initializeCamera();
  }

  Future<void> _initializeCamera() async {
    try {
      _cameras = await availableCameras();
      if (_cameras == null || _cameras!.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('No cameras available')));
          Navigator.pop(context);
        }
        return;
      }

      // --- Selects FRONT camera for selfies ---
      final front = _cameras!
          .where((c) => c.lensDirection == CameraLensDirection.front)
          .toList();
      final back = _cameras!
          .where((c) => c.lensDirection == CameraLensDirection.back)
          .toList();

      _currentCamera = widget.isSelfie
          ? (front.isNotEmpty ? front.first : _cameras!.first)
          : (back.isNotEmpty ? back.first : _cameras!.first);
      // --- End of camera selection ---

      _controller?.dispose();
      _controller = CameraController(
        _currentCamera,
        ResolutionPreset.high,
        enableAudio: false,
      );

      await _controller!.initialize();
      if (!mounted) return;

      setState(() => _isInitialized = true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Camera error: $e')));
        Navigator.pop(context);
      }
    }
  }

  Future<void> _takePicture() async {
    if (_isTakingPicture || !_isInitialized || _controller == null) return;

    setState(() => _isTakingPicture = true);
    try {
      final XFile photo = await _controller!.takePicture();
      final File file = File(photo.path);
      if (mounted) {
        Navigator.pop(context, file); // Returns the captured image file
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error capturing photo: $e')));
      }
    } finally {
      if (mounted) {
        setState(() => _isTakingPicture = false);
      }
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_isInitialized || _controller == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          CameraPreview(_controller!),
          Positioned(
            top: 40,
            left: 16,
            child: IconButton(
              icon: const Icon(Icons.close, color: Colors.white, size: 30),
              onPressed: () {
                Navigator.pop(context);
              },
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: FloatingActionButton(
                onPressed: _isTakingPicture ? null : _takePicture,
                child: _isTakingPicture
                    ? const CircularProgressIndicator(color: Colors.white)
                    : const Icon(Icons.camera),
              ),
            ),
          ),
          Center(
            child: Container(
              width: MediaQuery.of(context).size.width * 0.9,
              height: MediaQuery.of(context).size.height * 0.4,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white, width: 2),
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// --- Camera Class 2: For Liveness Check ---

class LivenessCamera extends StatefulWidget {
  const LivenessCamera({super.key});

  @override
  State<LivenessCamera> createState() => _LivenessCameraState();
}

class _LivenessCameraState extends State<LivenessCamera> {
  CameraController? _controller;
  List<CameraDescription>? _cameras;
  bool _isInitialized = false;
  bool _isCapturing = false;
  final List<File> _frames = [];
  int _currentStep = 0;
  final _instructions = [
    'Hold card flat',
    'Tilt card left',
    'Tilt card right',
    'Move card closer',
  ];
  Timer? _captureTimer;

  @override
  void initState() {
    super.initState();
    _initializeCamera();
  }

  Future<void> _initializeCamera() async {
    try {
      _cameras = await availableCameras();
      if (_cameras == null || _cameras!.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('No cameras available')));
          Navigator.pop(context);
        }
        return;
      }

      _controller = CameraController(
        _cameras!.first,
        ResolutionPreset.high,
        enableAudio: false,
      );

      await _controller!.initialize();
      if (mounted) {
        setState(() => _isInitialized = true);
        _startCaptureSequence();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Camera error: $e')));
        Navigator.pop(context);
      }
    }
  }

  void _startCaptureSequence() {
    _captureTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      if (_currentStep >= _instructions.length || !mounted) {
        timer.cancel();
        if (_frames.isNotEmpty) {
          Navigator.pop(context, _frames);
        }
        return;
      }

      setState(() => _isCapturing = true);
      try {
        final XFile photo = await _controller!.takePicture();
        _frames.add(File(photo.path));
        setState(() => _currentStep++);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Error capturing frame: $e')));
        }
      } finally {
        if (mounted) {
          setState(() => _isCapturing = false);
        }
      }
    });
  }

  @override
  void dispose() {
    _captureTimer?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_isInitialized || _controller == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          CameraPreview(_controller!),
          Positioned(
            top: 40,
            left: 16,
            child: IconButton(
              icon: const Icon(Icons.close, color: Colors.white, size: 30),
              onPressed: () {
                _captureTimer?.cancel();
                Navigator.pop(context);
              },
            ),
          ),
          Positioned(
            top: 100,
            left: 0,
            right: 0,
            child: Container(
              padding: const EdgeInsets.all(16),
              color: Colors.black54,
              child: Text(
                _currentStep < _instructions.length
                    ? _instructions[_currentStep]
                    : 'Processing...',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ),
          Center(
            child: Container(
              width: MediaQuery.of(context).size.width * 0.9,
              height: MediaQuery.of(context).size.height * 0.4,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white, width: 2),
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
          if (_isCapturing)
            Positioned(
              bottom: 40,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.all(8),
                  color: Colors.black54,
                  child: const Text(
                    'Capturing...',
                    style: TextStyle(color: Colors.white),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// --- Camera Class 3: For Documents (CNIC/License) ---

class DocumentCameraScreen extends StatefulWidget {
  const DocumentCameraScreen({super.key});

  @override
  State<DocumentCameraScreen> createState() => _DocumentCameraScreenState();
}

class _DocumentCameraScreenState extends State<DocumentCameraScreen> {
  CameraController? _controller;
  List<CameraDescription>? _cameras;
  bool _isInitialized = false;
  bool _isTakingPicture = false;

  @override
  void initState() {
    super.initState();
    _initializeCamera();
  }

  Future<void> _initializeCamera() async {
    try {
      _cameras = await availableCameras();
      if (_cameras == null || _cameras!.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('No cameras available')));
          Navigator.pop(context);
        }
        return;
      }

      _controller = CameraController(
        _cameras!.first, // Uses the first available camera (usually the back)
        ResolutionPreset.high,
        enableAudio: false,
      );

      await _controller!.initialize();
      if (mounted) {
        setState(() => _isInitialized = true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Camera error: $e')));
        Navigator.pop(context);
      }
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _takePicture() async {
    if (_isTakingPicture || !_isInitialized || _controller == null) return;

    setState(() => _isTakingPicture = true);
    try {
      final XFile photo = await _controller!.takePicture();
      final File file = File(photo.path);
      if (mounted) {
        Navigator.pop(context, file); // Returns the captured image file
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error capturing photo: $e')));
      }
    } finally {
      if (mounted) {
        setState(() => _isTakingPicture = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_isInitialized || _controller == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      body: Stack(
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
          Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: FloatingActionButton(
                onPressed: _isTakingPicture ? null : _takePicture,
                child: _isTakingPicture
                    ? const CircularProgressIndicator(color: Colors.white)
                    : const Icon(Icons.camera),
              ),
            ),
          ),
          Center(
            child: Container(
              width: MediaQuery.of(context).size.width * 0.9,
              height: MediaQuery.of(context).size.height * 0.4,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white, width: 2),
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
