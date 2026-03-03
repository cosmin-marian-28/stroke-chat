import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Full-screen custom camera — Snap/IG style.
/// X to close, shutter to capture, flip to rotate.
/// Returns captured bytes + metadata via Navigator.pop.
class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen>
    with WidgetsBindingObserver {
  CameraController? _ctrl;
  List<CameraDescription> _cameras = [];
  int _cameraIdx = 0;
  bool _initializing = true;
  bool _capturing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initCameras();
  }

  Future<void> _initCameras() async {
    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        setState(() {
          _error = 'No cameras found';
          _initializing = false;
        });
        return;
      }
      // Default to back camera
      _cameraIdx = _cameras.indexWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
      );
      if (_cameraIdx < 0) _cameraIdx = 0;
      await _startCamera();
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Camera error: $e';
          _initializing = false;
        });
      }
    }
  }

  Future<void> _startCamera() async {
    final prev = _ctrl;
    if (prev != null) {
      await prev.dispose();
    }

    final camera = _cameras[_cameraIdx];
    final ctrl = CameraController(
      camera,
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );

    try {
      await ctrl.initialize();
      // Lock to portrait
      await ctrl.lockCaptureOrientation(DeviceOrientation.portraitUp);
      if (mounted) {
        setState(() {
          _ctrl = ctrl;
          _initializing = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Failed to init camera: $e';
          _initializing = false;
        });
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_ctrl == null || !_ctrl!.value.isInitialized) return;
    if (state == AppLifecycleState.inactive) {
      _ctrl?.dispose();
      _ctrl = null;
    } else if (state == AppLifecycleState.resumed) {
      _startCamera();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ctrl?.dispose();
    super.dispose();
  }

  Future<void> _capture() async {
    if (_capturing || _ctrl == null || !_ctrl!.value.isInitialized) return;
    setState(() => _capturing = true);
    HapticFeedback.mediumImpact();

    try {
      final file = await _ctrl!.takePicture();
      final bytes = await file.readAsBytes();

      if (bytes.length > 30 * 1024 * 1024) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('File too large. Max 30 MB.')),
          );
          setState(() => _capturing = false);
        }
        return;
      }

      final ext = file.name.split('.').last.toLowerCase();
      final decoded = await decodeImageFromList(bytes);
      final dimensions = '${decoded.width}x${decoded.height}';

      if (mounted) {
        Navigator.pop(context, {
          'bytes': bytes,
          'name': file.name,
          'ext': ext,
          'isVideo': false,
          'dimensions': dimensions,
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Capture failed: $e')),
        );
        setState(() => _capturing = false);
      }
    }
  }

  void _flipCamera() {
    if (_cameras.length < 2) return;
    HapticFeedback.selectionClick();
    setState(() {
      _cameraIdx = (_cameraIdx + 1) % _cameras.length;
      _initializing = true;
    });
    _startCamera();
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final topPad = mq.padding.top;
    final bottomPad = mq.padding.bottom;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Camera preview — full screen
          if (_ctrl != null && _ctrl!.value.isInitialized && !_initializing)
            Positioned.fill(
              child: ClipRRect(
                child: FittedBox(
                  fit: BoxFit.cover,
                  child: SizedBox(
                    width: _ctrl!.value.previewSize!.height,
                    height: _ctrl!.value.previewSize!.width,
                    child: CameraPreview(_ctrl!),
                  ),
                ),
              ),
            )
          else if (_error != null)
            Center(
              child: Text(
                _error!,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.4),
                  fontSize: 14,
                ),
              ),
            )
          else
            const Center(
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white24,
              ),
            ),

          // Top bar — X button
          Positioned(
            top: topPad + 8,
            left: 16,
            child: GestureDetector(
              onTap: () => Navigator.pop(context),
              child: Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.black.withValues(alpha: 0.35),
                ),
                child: const Center(
                  child: Icon(
                    Icons.close_rounded,
                    color: Colors.white,
                    size: 22,
                  ),
                ),
              ),
            ),
          ),

          // Bottom controls — shutter + flip
          Positioned(
            left: 0,
            right: 0,
            bottom: bottomPad + 24,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                // Spacer for symmetry
                const SizedBox(width: 48),

                // Shutter button
                GestureDetector(
                  onTap: _capture,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 120),
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Colors.white,
                        width: _capturing ? 3 : 4,
                      ),
                    ),
                    child: Center(
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 120),
                        width: _capturing ? 52 : 58,
                        height: _capturing ? 52 : 58,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),

                // Flip camera button
                GestureDetector(
                  onTap: _flipCamera,
                  child: Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.black.withValues(alpha: 0.35),
                    ),
                    child: const Center(
                      child: Icon(
                        Icons.flip_camera_ios_rounded,
                        color: Colors.white,
                        size: 22,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
