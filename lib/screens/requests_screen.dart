import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../core/supabase_client.dart';
import '../widgets/glass_pill.dart';

class RequestsScreen extends StatefulWidget {
  final List<Map<String, dynamic>> received;
  final List<Map<String, dynamic>> sent;
  final String currentUid;
  final String currentEmail;
  final VoidCallback onChanged;
  final void Function(Map<String, dynamic> friend)? onFriendAdded;

  const RequestsScreen({
    super.key,
    required this.received,
    required this.sent,
    required this.currentUid,
    required this.currentEmail,
    required this.onChanged,
    this.onFriendAdded,
  });

  @override
  State<RequestsScreen> createState() => _RequestsScreenState();
}

class _RequestsScreenState extends State<RequestsScreen> {
  final _supa = SupaConfig.client;
  late final List<Map<String, dynamic>> _received = List.from(widget.received);
  late final List<Map<String, dynamic>> _sent = List.from(widget.sent);
  final Set<String> _dismissing = {};

  void _dismiss(String id) {
    setState(() => _dismissing.add(id));
    Future.delayed(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      setState(() {
        _received.removeWhere((r) => r['id'] == id);
        _sent.removeWhere((r) => r['id'] == id);
        _dismissing.remove(id);
      });
    });
  }

  Future<void> _accept(Map<String, dynamic> req) async {
    final reqId = req['id'] as String;
    final fromUid = req['from_uid'] as String;
    final fromEmail = req['from_email'] as String? ?? '';
    final fromUsername = req['from_username'] as String? ?? fromEmail;

    // Animate out
    _dismiss(reqId);

    // Optimistic — add friend to chat list immediately
    widget.onFriendAdded?.call({
      'friend_id': fromUid,
      'username': fromUsername,
    });

    try {
      final sorted = [widget.currentUid, fromUid]..sort();
      final convoId = '${sorted[0]}_${sorted[1]}';
      // Insert friends + conversation first (RLS needs the pending request to exist)
      await Future.wait([
        _supa.from('friends').insert([
          {'user_id': widget.currentUid, 'friend_id': fromUid, 'email': fromEmail},
          {'user_id': fromUid, 'friend_id': widget.currentUid, 'email': widget.currentEmail},
        ]),
        _supa.from('conversations').upsert({
          'id': convoId,
          'participants': [widget.currentUid, fromUid],
        }),
      ]);
      // Now safe to delete the request
      await _supa.from('friend_requests').delete().eq('id', reqId);
      widget.onChanged();
    } catch (_) {
      widget.onChanged();
    }
  }

  Future<void> _reject(String reqId) async {
    _dismiss(reqId);
    widget.onChanged();

    try {
      await _supa.from('friend_requests').delete().eq('id', reqId);
    } catch (_) {
      widget.onChanged();
    }
  }

  Future<void> _cancelSent(String reqId) async {
    _dismiss(reqId);
    widget.onChanged();

    try {
      await _supa.from('friend_requests').delete().eq('id', reqId);
    } catch (_) {
      widget.onChanged();
    }
  }

  @override
  Widget build(BuildContext context) {
    final topPad = MediaQuery.of(context).padding.top;
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(48),
        child: Container(
          padding: EdgeInsets.only(top: topPad + 4),
          child: SizedBox(
            height: 48,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(
                children: [
                  GestureDetector(
                    onTap: () => Navigator.pop(context),
                    child: GlassPill(
                      width: 42,
                      child: SvgPicture.asset('assets/back.svg',
                          width: 16, height: 16,
                          colorFilter: const ColorFilter.mode(Colors.white70, BlendMode.srcIn)),
                    ),
                  ),
                  const SizedBox(width: 10),
                  GlassPill(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: const Text(
                        'Requests',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 15,
                        ),
                      ),
                    ),
                  ),
                  const Spacer(),
                ],
              ),
            ),
          ),
        ),
      ),
      body: Stack(
        children: [
          Positioned(
            top: 0, left: 0, right: 0,
            child: IgnorePointer(
              child: Container(
                height: topPad + 80,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter, end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.85),
                      Colors.black.withValues(alpha: 0.4),
                      Colors.black.withValues(alpha: 0.0),
                    ],
                  ),
                ),
              ),
            ),
          ),
          SafeArea(
            top: false,
            child: Column(
              children: [
                SizedBox(height: topPad + 56),
                Expanded(
                  child: _received.isEmpty && _sent.isEmpty
                      ? Center(
                          child: Text(
                            'No requests',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.3),
                              fontSize: 15,
                            ),
                          ),
                        )
                      : ListView(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          children: [
                            if (_received.isNotEmpty) ...[
                              _sectionHeader('Received', _received.where((r) => !_dismissing.contains(r['id'])).length),
                              const SizedBox(height: 8),
                              for (final req in _received) _receivedTile(req),
                            ],
                            if (_sent.isNotEmpty) ...[
                              SizedBox(height: _received.isNotEmpty ? 24 : 0),
                              _sectionHeader('Sent', _sent.where((r) => !_dismissing.contains(r['id'])).length),
                              const SizedBox(height: 8),
                              for (final req in _sent) _sentTile(req),
                            ],
                          ],
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(String title, int count) {
    return Row(
      children: [
        Text(title,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.5),
              fontSize: 13, fontWeight: FontWeight.w600, letterSpacing: 0.5,
            )),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: const Color(0xFF007AFF).withValues(alpha: 0.2),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text('$count',
              style: const TextStyle(
                color: Color(0xFF007AFF), fontSize: 12, fontWeight: FontWeight.w600,
              )),
        ),
      ],
    );
  }

  Widget _receivedTile(Map<String, dynamic> req) {
    final id = req['id'] as String;
    final isDismissing = _dismissing.contains(id);
    final username = req['from_username'] as String? ?? req['from_email'] as String? ?? '';
    return AnimatedSize(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
      child: isDismissing
          ? const SizedBox(width: double.infinity)
          : Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(50),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                  child: Container(
                    padding: const EdgeInsets.only(left: 6, right: 10, top: 6, bottom: 6),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.04),
                      borderRadius: BorderRadius.circular(50),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.08), width: 0.5,
                      ),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 40, height: 40,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: const Color(0xFF007AFF).withValues(alpha: 0.2),
                          ),
                          child: Center(
                            child: Text(
                              username.isNotEmpty ? username[0].toUpperCase() : '?',
                              style: const TextStyle(
                                color: Color(0xFF007AFF), fontSize: 16, fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(username,
                                  style: const TextStyle(color: Colors.white, fontSize: 15,
                                      fontWeight: FontWeight.w500),
                                  overflow: TextOverflow.ellipsis),
                              const SizedBox(height: 2),
                              Text('Wants to connect',
                                  style: TextStyle(color: Colors.white.withValues(alpha: 0.4),
                                      fontSize: 12)),
                            ],
                          ),
                        ),
                        GestureDetector(
                          onTap: () => _accept(req),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                            decoration: BoxDecoration(
                              color: const Color(0xFF007AFF),
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: const Text('Accept',
                                style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
                          ),
                        ),
                        const SizedBox(width: 6),
                        GestureDetector(
                          onTap: () => _reject(id),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Text('Decline',
                                style: TextStyle(color: Colors.white.withValues(alpha: 0.5),
                                    fontSize: 13, fontWeight: FontWeight.w500)),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
    );
  }

  Widget _sentTile(Map<String, dynamic> req) {
    final id = req['id'] as String;
    final isDismissing = _dismissing.contains(id);
    final username = req['to_username'] as String? ?? req['to_email'] as String? ?? '';
    return AnimatedSize(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
      child: isDismissing
          ? const SizedBox(width: double.infinity)
          : Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(50),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                  child: Container(
                    padding: const EdgeInsets.only(left: 6, right: 10, top: 6, bottom: 6),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.04),
                      borderRadius: BorderRadius.circular(50),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.08), width: 0.5,
                      ),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 40, height: 40,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.white.withValues(alpha: 0.06),
                          ),
                          child: Center(
                            child: Text(
                              username.isNotEmpty ? username[0].toUpperCase() : '?',
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.5),
                                fontSize: 16, fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(username,
                                  style: const TextStyle(color: Colors.white, fontSize: 15,
                                      fontWeight: FontWeight.w500),
                                  overflow: TextOverflow.ellipsis),
                              const SizedBox(height: 2),
                              Text('Pending',
                                  style: TextStyle(color: Colors.white.withValues(alpha: 0.35),
                                      fontSize: 12)),
                            ],
                          ),
                        ),
                        GestureDetector(
                          onTap: () => _cancelSent(id),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Text('Cancel',
                                style: TextStyle(color: Colors.white.withValues(alpha: 0.5),
                                    fontSize: 13, fontWeight: FontWeight.w500)),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}
