import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:video_player/video_player.dart';
import 'package:femdrive/main.dart'; // Adjust import if needed

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  late VideoPlayerController _controller;
  bool _isVideoInitialized = false;

  @override
  void initState() {
    super.initState();
    // Preload video for faster initialization
    _controller = VideoPlayerController.asset('assets/images/splash_video2.mp4')
      ..setPlaybackSpeed(2.0) // Set to 2x speed
      ..initialize().then((_) {
        if (!mounted) return;
        setState(() {
          _isVideoInitialized = true;
        });
        _controller.play();
        _navigateAfterVideo();
      }).catchError((e) {
        if (kDebugMode) {
          print("Video error: $e");
        }
        _navigateAfterVideo(); // Fallback if video fails
      });
  }

  void _navigateAfterVideo() {
    // Calculate duration based on video length at 2x speed
    final videoDuration = _controller.value.duration.inMilliseconds / 2;
    Future.delayed(Duration(milliseconds: videoDuration.ceil()), () {
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        PageRouteBuilder(
          pageBuilder: (_, _, _) => const InitialScreen(),
          transitionsBuilder: (_, animation, _, child) {
            return FadeTransition(
              opacity: animation.drive(CurveTween(curve: Curves.easeInOut)),
              child: child,
            );
          },
          transitionDuration: const Duration(milliseconds: 400),
        ),
      );
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface, // Match theme
      body: Stack(
        children: [
          if (_isVideoInitialized)
            Center(
              child: AspectRatio(
                aspectRatio: _controller.value.aspectRatio,
                child: VideoPlayer(_controller),
              ),
            ).animate().fadeIn(duration: 300.ms, curve: Curves.easeInOut),
          if (!_isVideoInitialized)
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Theme.of(context).colorScheme.primary.withValues(alpha:0.8),
                    Theme.of(context).colorScheme.surface,
                  ],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
              ),
              child: const Center(
                child: CircularProgressIndicator(
                  strokeWidth: 3.0,
                  valueColor: AlwaysStoppedAnimation<Color>(
                    Colors.white, // Use neutral color for fallback
                  ),
                ),
              ),
            ).animate().fadeIn(duration: 300.ms, curve: Curves.easeInOut),
        ],
      ),
    );
  }
}