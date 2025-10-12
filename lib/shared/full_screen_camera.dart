import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

class FullScreenCamera extends StatefulWidget {
  final bool isSelfie;
  const FullScreenCamera({super.key, required this.isSelfie});

  @override
  State<FullScreenCamera> createState() => _FullScreenCameraState();
}

class _FullScreenCameraState extends State<FullScreenCamera> {
  CameraController? _controller;
  List<CameraDescription>? cameras;
  bool _isCameraReady = false;

  @override
  void initState() {
    super.initState();
    _initializeCamera();
  }

  Future<void> _initializeCamera() async {
    final status = await Permission.camera.request();
    if (status.isDenied || status.isPermanentlyDenied) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(status.isPermanentlyDenied
                ? 'Camera permission permanently denied. Please enable in settings.'
                : 'Camera permission denied.'),
            backgroundColor: Theme.of(context).colorScheme.error,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            action: status.isPermanentlyDenied
                ? SnackBarAction(
                    label: 'Settings',
                    onPressed: () => openAppSettings(),
                  )
                : null,
          ),
        );
        Navigator.pop(context);
        return;
      }
    }

    try {
      cameras = await availableCameras();
      final camera = widget.isSelfie
          ? cameras!.firstWhere((c) => c.lensDirection == CameraLensDirection.front)
          : cameras!.first;
      _controller = CameraController(camera, ResolutionPreset.high);
      await _controller!.initialize();
      if (mounted) {
        setState(() => _isCameraReady = true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to initialize camera: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );
        Navigator.pop(context);
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
    if (!_isCameraReady) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      body: Stack(
        children: [
          CameraPreview(_controller!),
          Positioned(
            bottom: 20,
            left: MediaQuery.of(context).size.width / 2 - 30,
            child: FloatingActionButton(
              onPressed: () async {
                try {
                  final image = await _controller!.takePicture();
                  final tempDir = await getTemporaryDirectory();
                  final tempPath = '${tempDir.path}/temp_selfie_${DateTime.now().millisecondsSinceEpoch}.jpg';
                  final compressed = await FlutterImageCompress.compressAndGetFile(
                    image.path,
                    tempPath,
                    quality: 60,
                    minWidth: 800,
                    minHeight: 800,
                  );
                  if (compressed != null) {
                    // ignore: use_build_context_synchronously
                    Navigator.pop(context, File(compressed.path));
                  } else {
                    // ignore: use_build_context_synchronously
                    Navigator.pop(context);
                  }
                } catch (e) {
                  if (mounted) {
                    // ignore: use_build_context_synchronously
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Failed to capture image: $e'),
                        // ignore: use_build_context_synchronously
                        backgroundColor: Theme.of(context).colorScheme.error,
                        behavior: SnackBarBehavior.floating,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                    );
                    // ignore: use_build_context_synchronously
                    Navigator.pop(context);
                  }
                }
              },
              child: const Icon(Icons.camera),
            ),
          ),
        ],
      ),
    );
  }
}