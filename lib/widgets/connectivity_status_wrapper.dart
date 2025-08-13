import 'package:flutter/material.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

class ConnectivityStatusWrapper extends StatefulWidget {
  final Widget child;

  const ConnectivityStatusWrapper({required this.child, super.key});

  @override
  State<ConnectivityStatusWrapper> createState() =>
      _ConnectivityStatusWrapperState();
}

class _ConnectivityStatusWrapperState extends State<ConnectivityStatusWrapper> {
  bool _isOffline = false;
  late final Connectivity _connectivity;
  late final Stream<List<ConnectivityResult>> _connectivityStream;

  @override
  void initState() {
    super.initState();
    _connectivity = Connectivity();
    _connectivityStream = _connectivity.onConnectivityChanged;

    _connectivityStream.listen((results) {
      final hasConnection = results.any(
        (result) => result != ConnectivityResult.none,
      );
      if (mounted) {
        setState(() => _isOffline = !hasConnection);
      }
    });

    _checkInitialConnection();
  }

  Future<void> _checkInitialConnection() async {
    final result = await _connectivity.checkConnectivity();
    // ignore: unrelated_type_equality_checks
    setState(() => _isOffline = result == ConnectivityResult.none);
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        widget.child,
        if (_isOffline)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Material(
              color: Colors.red,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Row(
                    children: const [
                      Icon(Icons.wifi_off, color: Colors.white),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'No internet connection',
                          style: TextStyle(color: Colors.white),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
