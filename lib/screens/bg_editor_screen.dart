import 'dart:typed_data';
import 'package:flutter/material.dart';

/// Lets the user pan & zoom a picked image to frame it as a chat background.
/// Returns the full Matrix4 storage (List length 16) on pop,
/// or null if cancelled.
class BgEditorScreen extends StatefulWidget {
  final Uint8List imageBytes;

  const BgEditorScreen({super.key, required this.imageBytes});

  @override
  State<BgEditorScreen> createState() => _BgEditorScreenState();
}

class _BgEditorScreenState extends State<BgEditorScreen> {
  final TransformationController _ctrl = TransformationController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _confirm() {
    // Return the raw matrix storage so the chat screen can replay it exactly.
    Navigator.pop(context, _ctrl.value.storage.toList());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: InteractiveViewer(
              transformationController: _ctrl,
              minScale: 0.5,
              maxScale: 5.0,
              boundaryMargin: const EdgeInsets.all(double.infinity),
              panEnabled: true,
              scaleEnabled: true,
              child: Image.memory(widget.imageBytes, fit: BoxFit.contain),
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: Container(color: Colors.black.withValues(alpha: 0.35)),
            ),
          ),
          Positioned(
            left: 0, right: 0,
            bottom: MediaQuery.of(context).padding.bottom + 16,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _pill('Cancel', () => Navigator.pop(context)),
                _pill('Done', _confirm, primary: true),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _pill(String label, VoidCallback onTap, {bool primary = false}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
        decoration: BoxDecoration(
          color: primary
              ? const Color(0xFF007AFF)
              : Colors.white.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(24),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: primary ? Colors.white : Colors.white.withValues(alpha: 0.7),
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
