import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../core/supabase_client.dart';
import '../core/local_avatar.dart';
import '../core/local_nickname.dart';
import '../core/tilt_provider.dart';
import '../widgets/glass_pill.dart';
import 'chat_screen.dart';
import 'requests_screen.dart';
import 'settings_screen.dart';
import '../services/push_notification_service.dart';

class ChatListScreen extends StatefulWidget {
  const ChatListScreen({super.key});

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen>
    with TickerProviderStateMixin {
  final _supa = SupaConfig.client;
  String get _uid => _supa.auth.currentUser!.id;
  String get _email => _supa.auth.currentUser!.email!;

  bool _isAddExpanded = false;
  final _addEmailController = TextEditingController();
  final _emailFocusNode = FocusNode();

  late final AnimationController _expandCtrl;
  late final AnimationController _wobbleCtrl;
  late final Animation<double> _wobbleAnim;

  List<Map<String, dynamic>> _requests = [];
  List<Map<String, dynamic>> _sentRequests = [];
  List<Map<String, dynamic>> _friends = [];
  RealtimeChannel? _requestsChannel;
  RealtimeChannel? _friendsChannel;

  @override
  void initState() {
    super.initState();
    _ensureUserDoc();
    PushNotificationService.instance.init();

    _expandCtrl = AnimationController(vsync: this);
    _wobbleCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _wobbleAnim = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0, end: 1.0), weight: 30),
      TweenSequenceItem(tween: Tween(begin: 1.0, end: -0.4), weight: 25),
      TweenSequenceItem(tween: Tween(begin: -0.4, end: 0.15), weight: 25),
      TweenSequenceItem(tween: Tween(begin: 0.15, end: 0), weight: 20),
    ]).animate(CurvedAnimation(parent: _wobbleCtrl, curve: Curves.easeOut));

    TiltProvider.instance.addUser();
    TiltProvider.instance.addListener(_onTilt);
    SimpleUiNotifier.instance.addListener(_onSimpleUiChanged);

    _loadData();
    _subscribeRealtime();
  }

  void _onTilt() {
    if (mounted && !SimpleUiNotifier.instance.value) setState(() {});
  }

  void _onSimpleUiChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    TiltProvider.instance.removeListener(_onTilt);
    TiltProvider.instance.removeUser();
    SimpleUiNotifier.instance.removeListener(_onSimpleUiChanged);
    _requestsChannel?.unsubscribe();
    _friendsChannel?.unsubscribe();
    _expandCtrl.dispose();
    _wobbleCtrl.dispose();
    _addEmailController.dispose();
    _emailFocusNode.dispose();
    super.dispose();
  }

  Future<void> _ensureUserDoc() async {
    // Profile is created at sign-up, just ensure it exists for older accounts
    final existing = await _supa
        .from('users')
        .select('id')
        .eq('id', _uid)
        .maybeSingle();
    if (existing == null) {
      await _supa.from('users').upsert({
        'id': _uid,
        'email': _email,
        'username': _email.split('@').first,
      });
    }
  }

  Future<void> _loadData() async {
    // Fire all three queries in parallel
    final results = await Future.wait([
      _supa
          .from('friend_requests')
          .select()
          .eq('to_uid', _uid)
          .eq('status', 'pending')
          .order('created_at'),
      _supa
          .from('friend_requests')
          .select()
          .eq('from_uid', _uid)
          .eq('status', 'pending')
          .order('created_at'),
      _supa
          .from('friends')
          .select()
          .eq('user_id', _uid)
          .order('added_at'),
    ]);
    final reqs = results[0] as List;
    final sent = results[1] as List;
    final frs = results[2] as List;

    // Collect all UIDs we need to look up in one batch
    final uidSet = <String>{};
    for (final r in reqs) {
      uidSet.add(r['from_uid'] as String);
    }
    for (final s in sent) {
      uidSet.add(s['to_uid'] as String);
    }
    for (final f in frs) {
      uidSet.add(f['friend_id'] as String);
    }

    // Single batch query for all user info
    Map<String, Map<String, dynamic>> userMap = {};
    if (uidSet.isNotEmpty) {
      final users = await _supa
          .from('users')
          .select('id, username, email')
          .inFilter('id', uidSet.toList());
      for (final u in users) {
        userMap[u['id'] as String] = u;
      }
    }

    // Enrich received requests
    final enrichedReceived = reqs.map((r) {
      final m = Map<String, dynamic>.from(r);
      final user = userMap[r['from_uid']];
      m['from_username'] = user?['username'] ?? r['from_email'] ?? '';
      return m;
    }).toList();

    // Enrich sent requests
    final enrichedSent = sent.map((s) {
      final m = Map<String, dynamic>.from(s);
      final user = userMap[s['to_uid']];
      m['to_username'] = user?['username'] ?? user?['email'] ?? (s['to_uid'] as String).substring(0, 8);
      return m;
    }).toList();

    // Enrich friends
    final enrichedFriends = frs.map((fr) {
      final m = Map<String, dynamic>.from(fr);
      final user = userMap[fr['friend_id']];
      m['username'] = user?['username'] ?? '';
      return m;
    }).toList();

    if (mounted) {
      setState(() {
        _requests = enrichedReceived;
        _sentRequests = enrichedSent;
        _friends = enrichedFriends;
      });
    }
  }

  void _subscribeRealtime() {
    _requestsChannel = _supa.channel('requests:$_uid',
      opts: const RealtimeChannelConfig(private: true),
    )
      .onBroadcast(event: 'INSERT', callback: (_) => _loadData())
      .onBroadcast(event: 'DELETE', callback: (_) => _loadData())
      .subscribe();

    _friendsChannel = _supa.channel('friends:$_uid',
      opts: const RealtimeChannelConfig(private: true),
    )
      .onBroadcast(event: 'INSERT', callback: (_) => _loadData())
      .onBroadcast(event: 'DELETE', callback: (_) => _loadData())
      .subscribe();
  }

  void _openRequests() {
    Navigator.push(
      context,
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => RequestsScreen(
          received: _requests,
          sent: _sentRequests,
          currentUid: _uid,
          currentEmail: _email,
          onChanged: _loadData,
          onFriendAdded: (friend) {
            // Optimistic — add to friends list immediately
            if (mounted) {
              setState(() {
                _friends.add(friend);
              });
            }
          },
        ),
        transitionsBuilder: (_, anim, __, child) {
          return FadeTransition(
            opacity: CurvedAnimation(parent: anim, curve: Curves.easeOut),
            child: child,
          );
        },
        transitionDuration: const Duration(milliseconds: 250),
      ),
    );
  }

  void _toggleAddFriend() {
    if (_isAddExpanded) {
      _emailFocusNode.unfocus();
      final sim = SpringSimulation(
        const SpringDescription(mass: 1, stiffness: 300, damping: 22),
        _expandCtrl.value, 0, 0,
      );
      _expandCtrl.animateWith(sim).then((_) {
        if (mounted) {
          setState(() {
            _isAddExpanded = false;
            _addEmailController.clear();
          });
        }
      });
    } else {
      setState(() => _isAddExpanded = true);
      final sim = SpringSimulation(
        const SpringDescription(mass: 1, stiffness: 180, damping: 16),
        0, 1, 0,
      );
      _expandCtrl.animateWith(sim);
      _wobbleCtrl.forward(from: 0);
      Future.delayed(const Duration(milliseconds: 400), () {
        if (mounted) _emailFocusNode.requestFocus();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final topPadding = MediaQuery.of(context).padding.top;
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(48),
        child: Container(
          padding: EdgeInsets.only(top: topPadding + 4),
          child: SizedBox(
            height: 48,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(
                children: [
                  GestureDetector(
                    onTap: _openRequests,
                    child: GlassPill(
                      width: 42,
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          SvgPicture.asset('assets/list.svg',
                              width: 18, height: 18,
                              colorFilter: ColorFilter.mode(
                                  Colors.white.withValues(alpha: 0.6), BlendMode.srcIn)),
                          if (_requests.isNotEmpty || _sentRequests.isNotEmpty)
                            Positioned(
                              top: -4, right: -6,
                              child: Container(
                                width: 16, height: 16,
                                decoration: const BoxDecoration(
                                  color: Color(0xFF007AFF),
                                  shape: BoxShape.circle,
                                ),
                                alignment: Alignment.center,
                                child: Text(
                                  '${_requests.length + _sentRequests.length}',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 9,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  GlassPill(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: const Text(
                        'Conversations',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 15,
                        ),
                      ),
                    ),
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: () {
                      Navigator.push(
                        context,
                        PageRouteBuilder(
                          pageBuilder: (_, __, ___) => const SettingsScreen(),
                          transitionsBuilder: (_, anim, __, child) {
                            return FadeTransition(
                              opacity: CurvedAnimation(parent: anim, curve: Curves.easeOut),
                              child: child,
                            );
                          },
                          transitionDuration: const Duration(milliseconds: 250),
                        ),
                      );
                    },
                    child: GlassPill(
                      width: 42,
                      child: Icon(Icons.settings_rounded,
                          size: 18,
                          color: Colors.white.withValues(alpha: 0.5)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: () => _supa.auth.signOut(),
                    child: GlassPill(
                      width: 42,
                      child: SvgPicture.asset('assets/logout.svg',
                          width: 16, height: 16,
                          colorFilter: ColorFilter.mode(
                              Colors.white.withValues(alpha: 0.5), BlendMode.srcIn)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      body: Stack(
        children: [
          _buildScrollableBody(topPadding),
          Positioned(
            top: 0, left: 0, right: 0,
            child: IgnorePointer(
              child: Container(
                height: topPadding + 70,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black,
                      Colors.black.withValues(alpha: 0.85),
                      Colors.black.withValues(alpha: 0.4),
                      Colors.black.withValues(alpha: 0.0),
                    ],
                    stops: const [0.0, 0.45, 0.7, 1.0],
                  ),
                ),
              ),
            ),
          ),
          if (_isAddExpanded)
            Positioned.fill(
              child: GestureDetector(
                onTap: _toggleAddFriend,
                behavior: HitTestBehavior.translucent,
                child: const SizedBox.expand(),
              ),
            ),
          _buildLiquidBlob(),
        ],
      ),
    );
  }

  Widget _buildLiquidBlob() {
    final bottomPad = MediaQuery.of(context).padding.bottom;
    final screenW = MediaQuery.of(context).size.width;
    const dotSize = 56.0;
    final expandedW = screenW - 40.0;
    final simple = SimpleUiNotifier.instance.value;

    return AnimatedBuilder(
      animation: Listenable.merge([_expandCtrl, _wobbleCtrl]),
      builder: (context, _) {
        final t = _expandCtrl.value.clamp(0.0, 1.0);
        final wobble = _wobbleAnim.value;
        final baseW = dotSize + (expandedW - dotSize) * t;
        final w = simple
            ? baseW
            : (baseW + wobble * 20 * t).clamp(dotSize, expandedW + 20.0);
        final h = simple ? dotSize : dotSize + wobble * 4 * t;
        final right = 20.0;

        if (simple) {
          return Positioned(
            right: right,
            bottom: bottomPad + 20,
            child: GestureDetector(
              onTap: t < 0.1 ? _toggleAddFriend : null,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: w,
                height: h,
                decoration: BoxDecoration(
                  color: t < 0.1
                      ? const Color(0xFF007AFF)
                      : const Color(0xFF1C1C1E),
                  borderRadius: BorderRadius.circular(h / 2),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.10),
                    width: 0.5,
                  ),
                ),
                child: t < 0.25
                    ? _buildDotContent(t)
                    : _buildInputContent(t),
              ),
            ),
          );
        }

        return Positioned(
          right: right,
          bottom: bottomPad + 20,
          child: GestureDetector(
            onTap: t < 0.1 ? _toggleAddFriend : null,
            child: CustomPaint(
              painter: _LiquidBlobPainter(
                progress: t,
                wobble: wobble,
                angle: TiltProvider.instance.angle,
                color1: Color.lerp(
                  const Color(0xFF007AFF),
                  const Color(0xFF1C1C1E).withValues(alpha: 0.85),
                  t,
                )!,
                color2: Color.lerp(
                  const Color(0xFF5856D6),
                  const Color(0xFF1C1C1E).withValues(alpha: 0.75),
                  t,
                )!,
                borderColor: Colors.white.withValues(alpha: 0.12 + 0.08 * t),
              ),
              child: ClipPath(
                clipper: _LiquidBlobClipper(progress: t, wobble: wobble),
                child: BackdropFilter(
                  filter: ImageFilter.blur(
                    sigmaX: 0.01 + 40 * t,
                    sigmaY: 0.01 + 40 * t,
                  ),
                  child: SizedBox(
                    width: w,
                    height: h,
                    child: t < 0.25
                        ? _buildDotContent(t)
                        : _buildInputContent(t),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildDotContent(double t) {
    return Center(
      child: Opacity(
        opacity: (1.0 - t * 4).clamp(0.0, 1.0),
        child: SvgPicture.asset('assets/user-plus.svg',
            width: 24, height: 24,
            colorFilter: const ColorFilter.mode(Colors.white, BlendMode.srcIn)),
      ),
    );
  }

  Widget _buildInputContent(double t) {
    final opacity = ((t - 0.25) / 0.5).clamp(0.0, 1.0);
    return Opacity(
      opacity: opacity,
      child: Padding(
        padding: const EdgeInsets.only(left: 20, right: 6),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _addEmailController,
                focusNode: _emailFocusNode,
                keyboardType: TextInputType.emailAddress,
                style: const TextStyle(
                  color: Colors.white, fontSize: 15, letterSpacing: -0.2,
                ),
                decoration: InputDecoration(
                  hintText: 'Add by username...',
                  hintStyle: TextStyle(
                    color: Colors.white.withValues(alpha: 0.35), fontSize: 15,
                  ),
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 8),
                ),
                onSubmitted: (_) => _submitAddFriend(),
              ),
            ),
            const SizedBox(width: 6),
            GestureDetector(
              onTap: _submitAddFriend,
              child: Container(
                width: 38, height: 38,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Color(0xFF007AFF),
                ),
                child: Center(
                  child: SvgPicture.asset('assets/send.svg',
                      width: 20, height: 20,
                      colorFilter: const ColorFilter.mode(Colors.white, BlendMode.srcIn)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _submitAddFriend() {
    final email = _addEmailController.text.trim();
    if (email.isNotEmpty) {
      _sendFriendRequest(email);
      _toggleAddFriend();
    }
  }

  Widget _buildScrollableBody(double topPadding) {
    if (_friends.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.people_outline_rounded,
                size: 48, color: Colors.white.withValues(alpha: 0.2)),
            const SizedBox(height: 12),
            Text('No friends yet',
                style: TextStyle(color: Colors.white.withValues(alpha: 0.4), fontSize: 16)),
            const SizedBox(height: 4),
            Text('Tap + to add someone',
                style: TextStyle(color: Colors.white.withValues(alpha: 0.25), fontSize: 13)),
          ],
        ),
      );
    }

    final items = <Widget>[];

    for (final fr in _friends) {
      final friendUid = fr['friend_id'] as String;
      final username = fr['username'] as String? ?? '';
      items.add(_ChatTile(
        key: ValueKey(friendUid),
        username: username,
        friendUid: friendUid,
        onTap: () {
          final convoId = _makeConvoId(_uid, friendUid);
          Navigator.push(context, MaterialPageRoute(
            builder: (_) => ChatScreen(
              convoId: convoId,
              friendUid: friendUid,
              friendUsername: username,
            ),
          ));
        },
      ));
    }

    return ListView.builder(
      padding: EdgeInsets.only(top: topPadding + 56, bottom: 100),
      itemCount: items.length,
      itemBuilder: (_, i) => items[i],
    );
  }

  Future<void> _sendFriendRequest(String username) async {
    // Optimistic — show sent request immediately
    final tempReq = {
      'id': 'temp_${DateTime.now().millisecondsSinceEpoch}',
      'to_uid': '',
      'from_uid': _uid,
      'to_username': username,
      'status': 'pending',
    };
    setState(() => _sentRequests.add(tempReq));

    final result = await _supa
        .from('users')
        .select('id, email')
        .eq('username', username)
        .limit(1)
        .maybeSingle();

    if (result == null) {
      // Rollback optimistic entry
      if (mounted) {
        setState(() => _sentRequests.removeWhere((r) => r['id'] == tempReq['id']));
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('User not found')),
        );
      }
      return;
    }

    final targetUid = result['id'] as String;
    if (targetUid == _uid) {
      if (mounted) setState(() => _sentRequests.removeWhere((r) => r['id'] == tempReq['id']));
      return;
    }

    try {
      await _supa.from('friend_requests').insert({
        'to_uid': targetUid,
        'from_uid': _uid,
        'from_email': _email,
        'to_email': result['email'] as String? ?? username,
        'status': 'pending',
      });
      // Refresh to get real IDs
      _loadData();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Request sent to $username')),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _sentRequests.removeWhere((r) => r['id'] == tempReq['id']));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to send request: $e')),
        );
      }
    }
  }

  String _makeConvoId(String uid1, String uid2) {
    final sorted = [uid1, uid2]..sort();
    return '${sorted[0]}_${sorted[1]}';
  }
}

class _LiquidBlobPainter extends CustomPainter {
  final double progress;
  final double wobble;
  final double angle;
  final Color color1;
  final Color color2;
  final Color borderColor;

  _LiquidBlobPainter({
    required this.progress,
    required this.wobble,
    required this.angle,
    required this.color1,
    required this.color2,
    required this.borderColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final path = _buildBlobPath(size, progress, wobble);
    final rect = Rect.fromLTWH(0, 0, size.width, size.height);
    final paint = Paint()
      ..shader = LinearGradient(
        colors: [color1, color2],
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
      ).createShader(rect);
    canvas.drawPath(path, paint);

    if (progress < 0.3) {
      final glowPaint = Paint()
        ..color = const Color(0xFF007AFF).withValues(alpha: 0.25 * (1 - progress * 3))
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12);
      canvas.drawPath(path, glowPaint);
    }

    // Tilt-reactive SweepGradient border
    final borderPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..shader = SweepGradient(
        center: Alignment.center,
        transform: GradientRotation(angle - math.pi * 0.33),
        colors: [
          Colors.white.withValues(alpha: 0.50),
          Colors.white.withValues(alpha: 0.35),
          Colors.white.withValues(alpha: 0.08),
          Colors.white.withValues(alpha: 0.04),
          Colors.white.withValues(alpha: 0.04),
          Colors.white.withValues(alpha: 0.08),
          Colors.white.withValues(alpha: 0.35),
          Colors.white.withValues(alpha: 0.50),
        ],
        stops: const [0.0, 0.08, 0.18, 0.3, 0.7, 0.82, 0.92, 1.0],
      ).createShader(rect);
    canvas.drawPath(path, borderPaint);

    // Blurred glow behind the bright section
    final glowBorderPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6.0
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4)
      ..shader = SweepGradient(
        center: Alignment.center,
        transform: GradientRotation(angle - math.pi * 0.25),
        colors: [
          Colors.white.withValues(alpha: 0.16),
          Colors.white.withValues(alpha: 0.05),
          Colors.white.withValues(alpha: 0.0),
          Colors.white.withValues(alpha: 0.0),
          Colors.white.withValues(alpha: 0.0),
          Colors.white.withValues(alpha: 0.05),
          Colors.white.withValues(alpha: 0.16),
        ],
        stops: const [0.0, 0.1, 0.22, 0.5, 0.78, 0.9, 1.0],
      ).createShader(rect);
    canvas.drawPath(path, glowBorderPaint);
  }

  @override
  bool shouldRepaint(_LiquidBlobPainter old) =>
      old.progress != progress || old.wobble != wobble ||
      old.angle != angle;
}

class _LiquidBlobClipper extends CustomClipper<Path> {
  final double progress;
  final double wobble;

  _LiquidBlobClipper({required this.progress, required this.wobble});

  @override
  Path getClip(Size size) => _buildBlobPath(size, progress, wobble);

  @override
  bool shouldReclip(_LiquidBlobClipper old) =>
      old.progress != progress || old.wobble != wobble;
}

Path _buildBlobPath(Size size, double progress, double wobble) {
  final w = size.width;
  final h = size.height;
  final r = h / 2;

  if (progress < 0.01) {
    return Path()..addOval(Rect.fromLTWH(0, 0, w, h));
  }

  final path = Path();
  final blobAmt = wobble * progress;
  final yPinch = blobAmt * 3;
  final xBulge = blobAmt * 8;

  path.moveTo(w - r, 0 - yPinch);
  path.cubicTo(
    w - r + r * 0.55 + xBulge, 0 - yPinch,
    w + xBulge * 0.5, r * 0.45 - yPinch * 0.5,
    w + xBulge * 0.3, r,
  );
  path.cubicTo(
    w + xBulge * 0.5, h - r * 0.45 + yPinch * 0.5,
    w - r + r * 0.55 + xBulge, h + yPinch,
    w - r, h + yPinch,
  );
  path.cubicTo(
    w * 0.6, h + yPinch * 1.5,
    w * 0.4, h + yPinch * 0.5,
    r, h + yPinch * 0.3,
  );
  path.cubicTo(
    r - r * 0.55, h + yPinch * 0.2,
    0 - xBulge * 0.2, h - r * 0.45,
    0 - xBulge * 0.1, r,
  );
  path.cubicTo(
    0 - xBulge * 0.2, r * 0.45,
    r - r * 0.55, 0 - yPinch * 0.2,
    r, 0 - yPinch * 0.3,
  );
  path.cubicTo(
    w * 0.4, 0 - yPinch * 0.5,
    w * 0.6, 0 - yPinch * 1.5,
    w - r, 0 - yPinch,
  );
  path.close();
  return path;
}

class _ChatTile extends StatefulWidget {
  final String username;
  final String friendUid;
  final VoidCallback onTap;

  const _ChatTile({super.key, required this.username, required this.friendUid, required this.onTap});

  @override
  State<_ChatTile> createState() => _ChatTileState();
}

class _ChatTileState extends State<_ChatTile> {
  Uint8List? _avatarBytes;
  String? _nickname;
  String _lastMsgPreview = '';
  bool _hasUnread = false;

  String get _uid => SupaConfig.client.auth.currentUser!.id;

  @override
  void initState() {
    super.initState();
    _loadAvatar();
    _loadNickname();
    _loadLastMessage();
  }

  Future<void> _loadAvatar() async {
    final bytes = await LocalAvatar.getBytes(widget.friendUid);
    if (mounted && bytes != null) setState(() => _avatarBytes = bytes);
  }

  Future<void> _loadNickname() async {
    final nick = await LocalNickname.get(widget.friendUid);
    if (mounted && nick != null && nick.isNotEmpty) {
      setState(() => _nickname = nick);
    }
  }

  Future<void> _loadLastMessage() async {
    try {
      final sorted = [_uid, widget.friendUid]..sort();
      final convoId = '${sorted[0]}_${sorted[1]}';
      final result = await SupaConfig.client
          .from('messages')
          .select('sender_id, type, blob, seen_at, gif_url')
          .eq('convo_id', convoId)
          .order('created_at', ascending: false)
          .limit(1);
      if (!mounted || result.isEmpty) return;
      final msg = result[0];
      final sender = msg['sender_id'] as String? ?? '';
      final type = msg['type'] as String?;
      final isMe = sender == _uid;

      String preview;
      if (type == 'image') {
        preview = isMe ? 'You sent a photo' : 'Sent a photo';
      } else if (type == 'video') {
        preview = isMe ? 'You sent a video' : 'Sent a video';
      } else if (type == 'gif') {
        preview = isMe ? 'You sent a GIF' : 'Sent a GIF';
      } else if (type == 'sticker') {
        preview = isMe ? 'You sent a sticker' : 'Sent a sticker';
      } else if (type == 'sv') {
        preview = isMe ? 'You sent a sound sticker' : 'Sent a sound sticker';
      } else if (type == 'voice') {
        preview = isMe ? 'You sent a voice message' : 'Voice message';
      } else if (type == 'locked_image') {
        preview = isMe ? 'You sent a locked photo' : '🔒 Locked photo';
      } else if (type == 'drawing') {
        preview = isMe ? 'You sent a drawing' : 'Sent a drawing';
      } else {
        // Text message — blob is encrypted, just show generic
        preview = isMe ? 'You sent a message' : 'New message';
      }

      // Unread = friend sent it and I haven't seen it
      final unread = !isMe && msg['seen_at'] == null;

      setState(() {
        _lastMsgPreview = preview;
        _hasUnread = unread;
      });
    } catch (_) {}
  }

  String get _displayName => _nickname ?? widget.username;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            SizedBox(
                width: 50, height: 50,
                child: Stack(
                  children: [
                    if (_avatarBytes != null)
                      ClipOval(
                        child: Image.memory(
                          _avatarBytes!,
                          width: 50, height: 50, fit: BoxFit.cover,
                        ),
                      )
                    else
                      Container(
                        width: 50, height: 50,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white.withValues(alpha: 0.06),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.12),
                            width: 1,
                          ),
                        ),
                        child: SvgPicture.asset('assets/user-plus.svg',
                            width: 24, height: 24,
                            colorFilter: const ColorFilter.mode(Color(0xFF007AFF), BlendMode.srcIn)),
                      ),
                    // Unread dot
                    if (_hasUnread)
                      Positioned(
                        right: 0, top: 0,
                        child: Container(
                          width: 12, height: 12,
                          decoration: BoxDecoration(
                            color: const Color(0xFF007AFF),
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.black, width: 2),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_displayName,
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: _hasUnread ? FontWeight.w600 : FontWeight.w500),
                      overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 3),
                  Text(
                    _lastMsgPreview.isNotEmpty ? _lastMsgPreview : 'Tap to chat',
                    style: TextStyle(
                      color: _hasUnread
                          ? Colors.white.withValues(alpha: 0.85)
                          : Colors.white.withValues(alpha: 0.35),
                      fontSize: 13,
                      fontWeight: _hasUnread ? FontWeight.w500 : FontWeight.w400,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded,
                color: Colors.white.withValues(alpha: 0.2)),
          ],
        ),
      ),
    );
  }
}
