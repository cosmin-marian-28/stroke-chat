import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:http/http.dart' as http;
import '../core/supabase_client.dart';
import '../core/session_manager.dart';
import '../core/e2e_encryption.dart';
import '../core/stroke_mapping.dart' show isEmoji, strokeRuneLength;
import '../core/local_avatar.dart';
import '../core/local_nickname.dart';
import '../widgets/stroke_keyboard.dart';
import '../widgets/gif_picker.dart';
import '../widgets/emoji_picker.dart';
import '../widgets/glass_pill.dart';
import '../core/tilt_provider.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import '../widgets/voice_bubble.dart';
import 'settings_screen.dart';
import 'dart:io';
import 'friend_profile_page.dart';
import 'drawboard_screen.dart';
import 'camera_screen.dart';
import 'media_viewer_screen.dart';
import 'package:video_thumbnail/video_thumbnail.dart';
import '../widgets/stroke_text.dart';
import 'package:audioplayers/audioplayers.dart';
import '../services/sv_cache.dart';
import '../services/push_sender.dart';

class ChatScreen extends StatefulWidget {
  final String convoId;
  final String friendUid;
  final String friendUsername;

  const ChatScreen({
    super.key,
    required this.convoId,
    required this.friendUid,
    required this.friendUsername,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with TickerProviderStateMixin {
  late final SessionManager _session = SessionManager(convoId: widget.convoId);
  final _supa = SupaConfig.client;
  final _scrollController = ScrollController();
  String get _uid => _supa.auth.currentUser!.id;
  E2EEncryption? _e2e;

  String _strokeText = '';
  String _plainText = '';
  int _cursorPos = 0; // cursor index in _plainText (0 = start, length = end)
  int _selStart = -1; // selection start index in _plainText (-1 = no selection)
  int _selEnd = -1;   // selection end index in _plainText (-1 = no selection)
  int _inputLines = 1; // current input line count (1-3)
  int _sessionVersion = 0;
  Uint8List? _friendAvatar;

  String _friendNickname = '';
  String _chatBg = 'black';
  final ValueNotifier<List<Color>> _bubbleGradientNotifier = ValueNotifier(
    const [Color(0xFF007AFF), Color(0xFF0055CC), Color(0xFF003399)],
  );
  Color _bubbleAccent = const Color(0xFF007AFF);
  Color get _bubbleColor => _bubbleAccent;
  bool _showGifPicker = false;
  bool _showEmojiPicker = false;
  bool _showToolbarExpanded = false;
  MediaTab _mediaPickerTab = MediaTab.gifs;
  Uint8List? _customBgBytes;
  Matrix4? _customBgTransform;
  bool _keyboardVisible = true;

  List<Map<String, dynamic>> _messages = [];
  final Set<String> _seenMessageIds = {};
  RealtimeChannel? _messagesChannel;
  RealtimeChannel? _convoChannel;
  RealtimeChannel? _stickersChannel;

  // Pull-up key rotation (vanish-mode style drag)
  double _pullUpOffset = 0;
  bool _keyRotationTriggered = false;
  bool _atNewestMessage = true;
  double _lastPointerY = 0;
  bool _trackingPull = false;
  late AnimationController _pullResetController;
  late AnimationController _sendBounceCtrl;
  final AudioRecorder _recorder = AudioRecorder();
  bool _isRecording = false;
  DateTime? _recordingStart;
  final stt.SpeechToText _speech = stt.SpeechToText();
  String _liveTranscript = ''; // stroke-encoded transcript built live

  // Reply state
  Map<String, dynamic>? _replyTo;

  // Key change indicator — ephemeral, not persisted
  DateTime? _keyChangedAt;

  // Unlocked images — maps message id to decrypted bytes (ephemeral)
  final Map<String, Uint8List> _unlockedImages = {};
  // Recently unlocked — triggers dissolve animation
  final Set<String> _justUnlockedIds = {};

  // Delete mode — which message is showing the X button
  // Messages currently animating out (shrinking before removal)
  final Set<String> _deletingIds = {};

  // Unlock mode — when user taps a locked image, keyboard types password here
  String? _unlockTargetId;
  String? _unlockTargetUrl;
  String _unlockPassword = '';

  // Lock mode — when user picks an image to lock, types password in input bar
  Uint8List? _lockPendingBytes;
  String? _lockPendingDims;
  String _lockPassword = '';

  // Placed stickers — floating stickers anchored to messages
  List<Map<String, dynamic>> _placedStickers = [];

  // Seen status — ID of the last message I sent that the friend has seen
  String? _lastSeenByFriendId;
  // Track which SV audio we already auto-played so we don't replay on scroll
  final Set<String> _autoPlayedSvIds = {};

  // Pending uploads — optimistic UI: show immediately with progress
  // Key: temp id, Value: {bytes, type, dims, progress (0.0-1.0), error}
  final Map<String, Map<String, dynamic>> _pendingUploads = {};
  int _pendingCounter = 0;
  // Local image cache — maps media URL to local bytes to avoid flicker on upload completion
  final Map<String, Uint8List> _recentUploadCache = {};
  // Decrypted media cache — maps media URL to decrypted bytes
  final Map<String, Uint8List> _decryptedMediaCache = {};
  final Set<String> _decryptingUrls = {};
  // Video thumbnail cache — maps media URL to first-frame bytes
  final Map<String, Uint8List> _videoThumbnails = {};
  // Drag-to-place state
  String? _draggingStickerUrl;
  Offset? _dragPosition;
  OverlayEntry? _stickerOverlay;
  // Message GlobalKeys for sticker anchoring
  final Map<String, GlobalKey> _messageKeys = {};

  @override
  void initState() {
    super.initState();
    _pullResetController = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 300),
    )..addStatusListener((s) {
      if (s == AnimationStatus.completed) {
        _pullResetController.reset();
      }
    });
    _sendBounceCtrl = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 300),
    );
    _initSession();
    _loadFriendAvatar();
    _loadNickname();
    _loadPlacedStickers();
  }

  Future<void> _loadNickname() async {
    final nick = await LocalNickname.get(widget.friendUid);
    if (mounted && nick != null && nick.isNotEmpty) {
      setState(() => _friendNickname = nick);
    }
  }

  String get _displayName =>
      _friendNickname.isNotEmpty ? _friendNickname : widget.friendUsername;

  Future<void> _loadFriendAvatar() async {
    final bytes = await LocalAvatar.getBytes(widget.friendUid);
    if (mounted && bytes != null) setState(() => _friendAvatar = bytes);
  }

  Future<void> _initSession() async {
    _sessionVersion = 0;
    // Load theme + custom bg + session + messages in parallel where possible
    const storage = FlutterSecureStorage();
    final bgFuture = storage.read(key: 'chat_bg_theme_${widget.convoId}');
    final bubbleColorFuture = storage.read(key: 'chat_bubble_color_${widget.convoId}');
    final bubbleGradFuture = storage.read(key: 'chat_bubble_grad_${widget.convoId}');
    final customBgFuture = _loadCustomBg();
    final sessionFuture = _buildSession();

    final bg = await bgFuture;
    if (bg != null) _chatBg = bg;
    final bubbleHex = await bubbleColorFuture;
    if (bubbleHex != null) {
      final v = int.tryParse(bubbleHex, radix: 16);
      if (v != null) _bubbleAccent = Color(v);
    }
    final gradStr = await bubbleGradFuture;
    if (gradStr != null) {
      final parts = gradStr.split(',');
      final colors = <Color>[];
      for (final p in parts) {
        final v = int.tryParse(p.trim(), radix: 16);
        if (v != null) colors.add(Color(v));
      }
      if (colors.length >= 2) _bubbleGradientNotifier.value = colors;
    }
    await customBgFuture;
    await sessionFuture;

    // Messages depend on session being ready, but start loading immediately after
    _loadMessages();
    if (mounted) setState(() {});
    _subscribeRealtime();
  }

  Future<void> _loadCustomBg() async {
    const storage = FlutterSecureStorage();
    final b64 = await storage.read(key: 'chat_bg_${widget.convoId}');
    if (b64 != null && mounted) {
      _customBgBytes = base64Decode(b64);
    }
    final transformJson = await storage.read(key: 'chat_bg_transform_${widget.convoId}');
    if (transformJson != null && mounted) {
      final list = (jsonDecode(transformJson) as List).cast<num>();
      if (list.length == 16) {
        _customBgTransform = Matrix4.fromList(list.map((n) => n.toDouble()).toList());
      }
    }
  }

  void _subscribeRealtime() {
    // Listen for new messages
    _messagesChannel = _supa.channel('convo:${widget.convoId}',
      opts: const RealtimeChannelConfig(private: true),
    )
      .onBroadcast(event: 'INSERT', callback: (_) => _onNewMessage())
      .subscribe();

    // Listen for conversation metadata changes (bg)
    _convoChannel = _supa.channel('convo_meta:${widget.convoId}',
      opts: const RealtimeChannelConfig(private: true),
    )
      .onBroadcast(event: 'UPDATE', callback: (payload) async {
        final record = payload['new'] as Map<String, dynamic>?;
        if (record == null) return;
      })
      .subscribe();

    // Listen for placed stickers changes
    _stickersChannel = _supa.channel('stickers:${widget.convoId}',
      opts: const RealtimeChannelConfig(private: true),
    )
      .onBroadcast(event: 'INSERT', callback: (_) => _loadPlacedStickers())
      .onBroadcast(event: 'DELETE', callback: (_) => _loadPlacedStickers())
      .subscribe();

    // Poll for seen_at changes every few seconds (friend opening convo)
    _startSeenPolling();
  }

  bool _seenPollingActive = false;

  void _startSeenPolling() {
    _seenPollingActive = true;
    Future.doWhile(() async {
      await Future.delayed(const Duration(seconds: 5));
      if (!mounted || !_seenPollingActive) return false;
      await _refreshSeenStatus();
      return mounted && _seenPollingActive;
    });
  }

  Future<void> _refreshSeenStatus() async {
    try {
      // Find the latest message I sent that has been seen
      final result = await _supa
          .from('messages')
          .select('id')
          .eq('convo_id', widget.convoId)
          .eq('sender_id', _uid)
          .not('seen_at', 'is', null)
          .order('created_at', ascending: false)
          .limit(1);
      if (mounted) {
        final newSeenId = (result as List).isNotEmpty
            ? result[0]['id']?.toString()
            : null;
        if (newSeenId != _lastSeenByFriendId) {
          setState(() => _lastSeenByFriendId = newSeenId);
        }
      }
    } catch (_) {}
  }

  Future<void> _onNewMessage() async {
    await _loadMessages();
    // Mark any new friend messages as seen since we're in the convo
    if (_messages.isNotEmpty) {
      final unseen = <String>[];
      String? newSvUrl;
      String? newSvId;
      for (final m in _messages) {
        final sender = m['sender_id'] as String? ?? '';
        final id = m['id']?.toString() ?? '';
        if (sender != _uid && m['seen_at'] == null && id.isNotEmpty) {
          unseen.add(id);
          if (newSvUrl == null && m['type'] == 'sv') {
            newSvUrl = m['gif_url'] as String?;
            newSvId = id;
          }
        }
      }
      if (unseen.isNotEmpty) {
        // Auto-play new SV from friend
        if (newSvUrl != null && newSvId != null &&
            !_autoPlayedSvIds.contains(newSvId)) {
          _autoPlayedSvIds.add(newSvId);
          _playSvAudio(newSvUrl);
        }
        try {
          await _supa
              .from('messages')
              .update({'seen_at': DateTime.now().toUtc().toIso8601String()})
              .inFilter('id', unseen);
        } catch (_) {}
      }
    }
  }

  Future<void> _loadMessages() async {
    final result = await _supa
        .from('messages')
        .select()
        .eq('convo_id', widget.convoId)
        .order('created_at', ascending: false);
    if (mounted) {
      final newList = List<Map<String, dynamic>>.from(result);
      // On first load, mark all as seen so they don't all animate in
      if (_messages.isEmpty) {
        for (final m in newList) {
          final id = m['id']?.toString();
          if (id != null) _seenMessageIds.add(id);
        }
        // Mark friend's unseen messages as seen & play last unseen SV
        _markFriendMessagesAsSeen(newList);
      }
      // Compute last message I sent that friend has seen
      _computeLastSeenByFriend(newList);
      setState(() {
        _messages = newList;
        // Auto-remove pending uploads whose URL now exists in real messages
        if (_pendingUploads.isNotEmpty) {
          final realUrls = <String>{};
          for (final m in newList) {
            final url = m['media_url'] as String?;
            final gifUrl = m['gif_url'] as String?;
            if (url != null) realUrls.add(url);
            if (gifUrl != null) realUrls.add(gifUrl);
          }
          _pendingUploads.removeWhere((_, v) {
            final uploadedUrl = v['uploadedUrl'] as String?;
            return uploadedUrl != null && realUrls.contains(uploadedUrl);
          });
        }
      });
    }
  }

  /// Find the last message I sent that the friend has seen (has seen_at set).
  void _computeLastSeenByFriend(List<Map<String, dynamic>> msgs) {
    // msgs are ordered newest first
    for (final m in msgs) {
      final sender = m['sender_id'] as String? ?? '';
      if (sender == _uid && m['seen_at'] != null) {
        _lastSeenByFriendId = m['id']?.toString();
        return;
      }
    }
    _lastSeenByFriendId = null;
  }

  /// Mark all friend's unseen messages as seen, and auto-play the last unseen SV.
  Future<void> _markFriendMessagesAsSeen(List<Map<String, dynamic>> msgs) async {
    final unseenIds = <String>[];
    String? lastUnseenSvUrl;
    String? lastUnseenSvId;
    for (final m in msgs) {
      final sender = m['sender_id'] as String? ?? '';
      final id = m['id']?.toString() ?? '';
      if (sender != _uid && m['seen_at'] == null && id.isNotEmpty) {
        unseenIds.add(id);
        // Track last unseen SV from friend (msgs are newest-first, so first match = latest)
        if (lastUnseenSvUrl == null && m['type'] == 'sv') {
          lastUnseenSvUrl = m['gif_url'] as String?;
          lastUnseenSvId = id;
        }
      }
    }
    if (unseenIds.isEmpty) return;

    // Auto-play the last unseen SV audio from friend
    if (lastUnseenSvUrl != null && lastUnseenSvId != null &&
        !_autoPlayedSvIds.contains(lastUnseenSvId)) {
      _autoPlayedSvIds.add(lastUnseenSvId);
      _playSvAudio(lastUnseenSvUrl);
    }

    // Batch update seen_at
    try {
      await _supa
          .from('messages')
          .update({'seen_at': DateTime.now().toUtc().toIso8601String()})
          .inFilter('id', unseenIds);
    } catch (e) {
      debugPrint('Mark seen error: $e');
    }
  }

  Future<void> _buildSession() async {
    final sessionId = 'session_${widget.convoId}_v$_sessionVersion';
    final secret = _deriveSharedSecret(_sessionVersion);
    await _session.joinSession(sessionId, secret);
    _e2e = E2EEncryption(secret);
  }

  Future<void> _rotateMapping() async {
    _sessionVersion += 1;
    await _buildSession();
    if (mounted) {
      setState(() {
      _keyChangedAt = DateTime.now().toUtc();
    });
    }
  }

  Uint8List _deriveSharedSecret(int version) {
    final seed = utf8.encode('${widget.convoId}_v$version');
    return Uint8List.fromList(sha256.convert(seed).bytes);
  }

  /// Strip diacritics / accented chars to ASCII equivalents so speech
  /// recognition output (e.g. Romanian ă, î, ș, ț) maps to chars in
  /// the stroke encode table without breaking 4-rune alignment.
  static String _stripDiacritics(String input) {
    const diacriticMap = {
      'ă': 'a', 'â': 'a', 'î': 'i', 'ș': 's', 'ț': 't',
      'Ă': 'A', 'Â': 'A', 'Î': 'I', 'Ș': 'S', 'Ț': 'T',
      'à': 'a', 'á': 'a', 'ä': 'a', 'å': 'a', 'ã': 'a',
      'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e',
      'ì': 'i', 'í': 'i', 'ï': 'i',
      'ò': 'o', 'ó': 'o', 'ô': 'o', 'ö': 'o', 'õ': 'o',
      'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u',
      'ñ': 'n', 'ç': 'c', 'ý': 'y', 'ÿ': 'y',
      'À': 'A', 'Á': 'A', 'Ä': 'A', 'Å': 'A', 'Ã': 'A',
      'È': 'E', 'É': 'E', 'Ê': 'E', 'Ë': 'E',
      'Ì': 'I', 'Í': 'I', 'Ï': 'I',
      'Ò': 'O', 'Ó': 'O', 'Ô': 'O', 'Ö': 'O', 'Õ': 'O',
      'Ù': 'U', 'Ú': 'U', 'Û': 'U', 'Ü': 'U',
      'Ñ': 'N', 'Ç': 'C', 'Ý': 'Y',
      // Romanian comma-below variants (ş/ţ with cedilla)
      'ş': 's', 'ţ': 't', 'Ş': 'S', 'Ţ': 'T',
    };
    final buf = StringBuffer();
    for (final ch in input.characters) {
      final mapped = diacriticMap[ch];
      if (mapped != null) {
        buf.write(mapped);
      } else if (ch.runes.length == 1 && ch.runes.first < 128) {
        buf.write(ch); // ASCII — safe
      } else {
        // Unknown non-ASCII char — skip it to avoid misalignment
      }
    }
    return buf.toString();
  }

  /// Convert a grapheme cluster index to a code-unit offset in _plainText.
  int _plainOffset(int graphemeIdx) {
    var offset = 0;
    var i = 0;
    final it = _plainText.characters.iterator;
    while (i < graphemeIdx && it.moveNext()) {
      offset += it.current.length;
      i++;
    }
    return offset;
  }

  /// Compute the stroke-text rune offset for a given plaintext character index.
  /// Emojis contribute their raw rune count; encoded chars contribute 4 runes.
  int _strokeOffset(int plainIdx) {
    var offset = 0;
    var i = 0;
    final it = _plainText.characters.iterator;
    while (i < plainIdx && it.moveNext()) {
      offset += strokeRuneLength(it.current);
      i++;
    }
    return offset;
  }

  /// Stroke rune length of a single plaintext character at [plainIdx].
  int _strokeCharLen(int plainIdx) {
    var i = 0;
    final it = _plainText.characters.iterator;
    while (i <= plainIdx && it.moveNext()) {
      if (i == plainIdx) return strokeRuneLength(it.current);
      i++;
    }
    return 4;
  }

  void _onKeyTap(String displayChar, String _) {
    if (!_session.hasActiveSession) return;
    if (_unlockTargetId != null) {
      setState(() => _unlockPassword += displayChar);
      return;
    }
    if (_lockPendingBytes != null) {
      setState(() => _lockPassword += displayChar);
      return;
    }
    setState(() {
      _deleteSelection(); // replace selection if any
      final encoded = isEmoji(displayChar) ? displayChar : _session.encodeChar(displayChar);
      final strokeIdx = _strokeOffset(_cursorPos);
      final strokeRunes = _strokeText.runes.toList();
      final encodedRunes = encoded.runes.toList();
      _strokeText = String.fromCharCodes([
        ...strokeRunes.sublist(0, strokeIdx),
        ...encodedRunes,
        ...strokeRunes.sublist(strokeIdx),
      ]);
      final plainIdx = _plainOffset(_cursorPos);
      _plainText = _plainText.substring(0, plainIdx) + displayChar + _plainText.substring(plainIdx);
      _cursorPos += 1;
    });
    _updateInputLines();
  }

  void _onBackspace() {
    if (_unlockTargetId != null) {
      if (_unlockPassword.isNotEmpty) {
        setState(() => _unlockPassword = _unlockPassword.substring(0, _unlockPassword.length - 1));
      }
      return;
    }
    if (_lockPendingBytes != null) {
      if (_lockPassword.isNotEmpty) {
        setState(() => _lockPassword = _lockPassword.substring(0, _lockPassword.length - 1));
      }
      return;
    }
    if (_selStart >= 0 && _selEnd >= 0 && _selStart != _selEnd) {
      setState(() => _deleteSelection());
      _updateInputLines();
      return;
    }
    if (_strokeText.isEmpty || _cursorPos <= 0) return;
    setState(() {
      final charLen = _strokeCharLen(_cursorPos - 1);
      final strokeIdx = _strokeOffset(_cursorPos);
      final removeStart = strokeIdx - charLen;
      final strokeRunes = _strokeText.runes.toList();
      _strokeText = String.fromCharCodes([
        ...strokeRunes.sublist(0, removeStart),
        ...strokeRunes.sublist(strokeIdx),
      ]);
      final prevOff = _plainOffset(_cursorPos - 1);
      final curOff = _plainOffset(_cursorPos);
      _plainText = _plainText.substring(0, prevOff) + _plainText.substring(curOff);
      _cursorPos -= 1;
    });
    _updateInputLines();
  }

  void _onCursorMove(int delta) {
    setState(() {
      _selStart = -1;
      _selEnd = -1;
      _cursorPos = (_cursorPos + delta).clamp(0, _plainText.characters.length);
    });
  }

  /// Deletes the selected range and places cursor at the start of the range.
  /// Must be called inside setState.
  void _deleteSelection() {
    if (_selStart < 0 || _selEnd < 0 || _selStart == _selEnd) return;
    final lo = _selStart < _selEnd ? _selStart : _selEnd;
    final hi = _selStart < _selEnd ? _selEnd : _selStart;
    final strokeLo = _strokeOffset(lo);
    final strokeHi = _strokeOffset(hi);
    final strokeRunes = _strokeText.runes.toList();
    _strokeText = String.fromCharCodes([
      ...strokeRunes.sublist(0, strokeLo),
      ...strokeRunes.sublist(strokeHi),
    ]);
    _plainText = _plainText.substring(0, _plainOffset(lo)) + _plainText.substring(_plainOffset(hi));
    _cursorPos = lo;
    _selStart = -1;
    _selEnd = -1;
  }

  void _clearSelection() {
    if (_selStart >= 0 || _selEnd >= 0) {
      setState(() { _selStart = -1; _selEnd = -1; });
    }
  }

  /// Returns word boundaries [start, end) for the word at [pos] in _plainText.
  List<int> _wordBoundsAt(int pos) {
    if (_plainText.isEmpty) return [0, 0];
    pos = pos.clamp(0, _plainText.length - 1);
    int start = pos;
    int end = pos;
    // Expand left
    while (start > 0 && _plainText[start - 1] != ' ' && _plainText[start - 1] != '\n') {
      start--;
    }
    // Expand right
    while (end < _plainText.length && _plainText[end] != ' ' && _plainText[end] != '\n') {
      end++;
    }
    return [start, end];
  }

  /// Hit-test: convert a local offset (relative to the StrokeText widget)
  /// into a character index in _plainText. Returns -1 if out of bounds.
  int _charIndexFromOffset(Offset localPos) {
    if (_plainText.isEmpty) return -1;
    // Build a paragraph with the same style to hit-test
    final builder = ui.ParagraphBuilder(
      ui.ParagraphStyle(
        textAlign: TextAlign.left,
        fontSize: 16,
        maxLines: 100,
        height: 1.15,
      ),
    );
    builder.pushStyle(ui.TextStyle(
      color: const Color(0xFFFFFFFF),
      fontSize: 16,
      letterSpacing: -0.2,
      height: 1.15,
    ));
    builder.addText(_plainText);
    builder.pop();
    // Use the input bar width (~screen width minus padding)
    final w = MediaQuery.of(context).size.width - 80;
    final paragraph = builder.build();
    paragraph.layout(ui.ParagraphConstraints(width: w > 0 ? w : 300));
    final pos = paragraph.getPositionForOffset(localPos);
    return pos.offset.clamp(0, _plainText.length);
  }

  void _updateInputLines() {
    if (_plainText.isEmpty) {
      if (_inputLines != 1) setState(() => _inputLines = 1);
      return;
    }
    final screenW = MediaQueryData.fromView(
      WidgetsBinding.instance.platformDispatcher.views.first,
    ).size.width;
    final textW = screenW - 122;
    final tp = TextPainter(
      text: TextSpan(
        text: _plainText,
        style: const TextStyle(fontSize: 16, letterSpacing: -0.2),
      ),
      maxLines: 100,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: textW);
    final lines = tp.computeLineMetrics().length.clamp(1, 3);
    tp.dispose();
    if (lines != _inputLines) {
      final delta = (lines - _inputLines) * 20.0;
      setState(() => _inputLines = lines);
      // Smooth scroll to keep messages at same visual position
      if (_scrollController.hasClients) {
        final pos = _scrollController.position;
        _scrollController.animateTo(
          (pos.pixels - delta).clamp(pos.minScrollExtent, pos.maxScrollExtent + delta.abs()),
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
        );
      }
    }
  }

  bool get _isUnlockMode => _unlockTargetId != null;

  void _enterUnlockMode(String msgId, String mediaUrl) {
    setState(() {
      _unlockTargetId = msgId;
      _unlockTargetUrl = mediaUrl;
      _unlockPassword = '';
      _keyboardVisible = true;
    });
  }

  void _exitUnlockMode() {
    setState(() {
      _unlockTargetId = null;
      _unlockTargetUrl = null;
      _unlockPassword = '';
    });
  }

  Future<void> _onUnlockSend() async {
    if (_unlockPassword.isEmpty || _unlockTargetId == null || _unlockTargetUrl == null) return;
    _sendBounceCtrl.forward(from: 0);
    final msgId = _unlockTargetId!;
    final url = _unlockTargetUrl!;
    final pass = _unlockPassword;
    _exitUnlockMode();
    await _tryUnlockImage(msgId, url, pass);
  }

  bool get _isLockMode => _lockPendingBytes != null;

  void _exitLockMode() {
    setState(() {
      _lockPendingBytes = null;
      _lockPendingDims = null;
      _lockPassword = '';
    });
  }

  Future<void> _onLockSend() async {
    if (_lockPassword.isEmpty || _lockPendingBytes == null) return;
    _sendBounceCtrl.forward(from: 0);
    final bytes = _lockPendingBytes!;
    final dims = _lockPendingDims ?? '';
    final password = _lockPassword;
    _exitLockMode();

    final passKey = Uint8List.fromList(
      sha256.convert(utf8.encode(password)).bytes,
    );
    final passE2e = E2EEncryption(passKey);
    final encryptedBytes = passE2e.encryptBytes(Uint8List.fromList(bytes));
    final fileName =
        '${widget.convoId}/${DateTime.now().millisecondsSinceEpoch}_locked.enc';

    try {
      await _supa.storage.from('chat-media').uploadBinary(
        fileName,
        encryptedBytes,
        fileOptions: const FileOptions(contentType: 'application/octet-stream'),
      );
      final publicUrl =
          _supa.storage.from('chat-media').getPublicUrl(fileName);
      final passHash = sha256.convert(utf8.encode(password)).toString();

      await _supa.from('messages').insert({
        'convo_id': widget.convoId,
        'sender_id': _uid,
        'type': 'locked_image',
        'media_url': publicUrl,
        'blob': '$passHash|$dims',
        'v': _sessionVersion,
      });
      PushSender.instance.notify(recipientId: widget.friendUid, msgType: 'locked_image');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Upload failed: $e')),
        );
      }
    }
  }

  Future<void> _onSend() async {
    if (_strokeText.isEmpty || !_session.hasActiveSession) return;
    _sendBounceCtrl.forward(from: 0);
    final payload = _strokeText;
    final replyId = _replyTo?['id']?.toString();
    setState(() { _strokeText = ''; _plainText = ''; _cursorPos = 0; _selStart = -1; _selEnd = -1; _replyTo = null; _inputLines = 1; });
    final encryptedBlob = _e2e!.encrypt(payload);
    final row = <String, dynamic>{
      'convo_id': widget.convoId,
      'sender_id': _uid,
      'session_id': _session.activeSessionId!,
      'blob': encryptedBlob,
      'v': _sessionVersion,
    };
    if (replyId != null) row['reply_to'] = replyId;
    await _supa.from('messages').insert(row);
    _messagesChannel?.sendBroadcastMessage(event: 'INSERT', payload: {});
    PushSender.instance.notify(recipientId: widget.friendUid);
  }

  Future<void> _onGifSelected(String gifUrl) async {
    final replyId = _replyTo?['id']?.toString();
    final isSticker = _mediaPickerTab == MediaTab.stickers;
    final isSv = _mediaPickerTab == MediaTab.sv;

    // Optimistic UI — show gif/sticker immediately
    final tempId = 'pending_${_pendingCounter++}';
    final msgType = isSv ? 'sv' : isSticker ? 'sticker' : 'gif';
    setState(() {
      _showGifPicker = false;
      _strokeText = '';
      _plainText = '';
      _cursorPos = 0;
      _selStart = -1;
      _selEnd = -1;
      _replyTo = null;
      _inputLines = 1;
      _pendingUploads[tempId] = {
        'type': msgType,
        'gifUrl': gifUrl,
        'progress': 0.0,
      };
    });
    try {
      final row = <String, dynamic>{
        'convo_id': widget.convoId,
        'sender_id': _uid,
        'type': msgType,
        'gif_url': gifUrl,
        'v': _sessionVersion,
      };
      if (replyId != null) row['reply_to'] = replyId;
      if (mounted) setState(() => _pendingUploads[tempId]!['uploadedUrl'] = gifUrl);
      await _supa.from('messages').insert(row);
      PushSender.instance.notify(recipientId: widget.friendUid, msgType: msgType);
    } catch (e) {
      if (mounted) setState(() => _pendingUploads.remove(tempId));
    }
  }

  AudioPlayer? _svPlayer;

  Future<void> _playSvAudio(String svUrl) async {
    try {
      final data = await SvCache.instance.get(svUrl);
      if (data?.audioPath == null) return;
      _svPlayer?.dispose();
      _svPlayer = AudioPlayer();
      await _svPlayer!.play(DeviceFileSource(data!.audioPath!));
    } catch (e) {
      debugPrint('SV play error: $e');
    }
  }

  Future<void> _pickAndSendMedia() async {
    final picker = ImagePicker();
    final picked = await picker.pickMedia(
      maxWidth: 1920,
      maxHeight: 1920,
      imageQuality: 80,
    );
    if (picked == null) return;

    final bytes = await picked.readAsBytes();
    const maxSize = 30 * 1024 * 1024; // 30 MB
    if (bytes.length > maxSize) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('File too large. Max 30 MB.')),
        );
      }
      return;
    }

    final ext = picked.name.split('.').last.toLowerCase();
    final isVideo = ['mp4', 'mov', 'avi', 'webm', 'm4v'].contains(ext);
    final mediaType = isVideo ? 'video' : 'image';

    // Get image dimensions for natural aspect ratio
    String? dimensionsBlob;
    if (!isVideo) {
      final decoded = await decodeImageFromList(bytes);
      dimensionsBlob = '${decoded.width}x${decoded.height}';
    }

    // Optimistic UI — show immediately
    final tempId = 'pending_${_pendingCounter++}';
    setState(() {
      _pendingUploads[tempId] = {
        'bytes': bytes,
        'type': mediaType,
        'dims': dimensionsBlob,
        'progress': 0.0,
      };
    });

    // Encrypt media bytes before upload
    final uploadBytes = _e2e != null
        ? _e2e!.encryptBytes(bytes)
        : bytes;
    final encExt = _e2e != null ? 'enc' : ext;
    final fileName = '${widget.convoId}/${DateTime.now().millisecondsSinceEpoch}_media.$encExt';

    try {
      await _supa.storage.from('chat-media').uploadBinary(
        fileName,
        uploadBytes,
        fileOptions: FileOptions(contentType: _e2e != null ? 'application/octet-stream' : (isVideo ? 'video/$ext' : 'image/$ext')),
      );
      final publicUrl = _supa.storage.from('chat-media').getPublicUrl(fileName);

      // Cache local UNENCRYPTED bytes so the real message shows instantly without network load
      if (!isVideo) _recentUploadCache[publicUrl] = bytes;
      if (isVideo) _decryptedMediaCache[publicUrl] = bytes;

      // Mark pending as uploaded — it stays visible until _loadMessages picks up the real message
      if (mounted) setState(() => _pendingUploads[tempId]!['uploadedUrl'] = publicUrl);

      final row = <String, dynamic>{
        'convo_id': widget.convoId,
        'sender_id': _uid,
        'type': mediaType,
        'media_url': publicUrl,
        'v': _sessionVersion,
      };
      if (dimensionsBlob != null) row['blob'] = dimensionsBlob;
      await _supa.from('messages').insert(row);
      PushSender.instance.notify(recipientId: widget.friendUid, msgType: mediaType);
    } catch (e) {
      if (mounted) {
        setState(() => _pendingUploads.remove(tempId));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Upload failed: $e')),
        );
      }
    }
  }

  Future<void> _openCamera() async {
    final result = await Navigator.push<Map<String, dynamic>>(
      context,
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => const CameraScreen(),
        transitionsBuilder: (_, anim, __, child) =>
            FadeTransition(opacity: anim, child: child),
        transitionDuration: const Duration(milliseconds: 200),
      ),
    );
    if (result == null || !mounted) return;

    final bytes = result['bytes'] as Uint8List;
    final ext = result['ext'] as String;
    final isVideo = result['isVideo'] as bool;
    final dimensions = result['dimensions'] as String?;
    final mediaType = isVideo ? 'video' : 'image';

    // Optimistic UI — show immediately
    final tempId = 'pending_${_pendingCounter++}';
    setState(() {
      _pendingUploads[tempId] = {
        'bytes': bytes,
        'type': mediaType,
        'dims': dimensions,
        'progress': 0.0,
      };
    });

    // Encrypt media bytes before upload
    final uploadBytes = _e2e != null
        ? _e2e!.encryptBytes(bytes)
        : bytes;
    final encExt = _e2e != null ? 'enc' : ext;
    final fileName = '${widget.convoId}/${DateTime.now().millisecondsSinceEpoch}_camera.$encExt';

    try {
      await _supa.storage.from('chat-media').uploadBinary(
        fileName,
        uploadBytes,
        fileOptions: FileOptions(contentType: _e2e != null ? 'application/octet-stream' : (isVideo ? 'video/$ext' : 'image/$ext')),
      );
      final publicUrl = _supa.storage.from('chat-media').getPublicUrl(fileName);

      // Cache local UNENCRYPTED bytes so the real message shows instantly
      if (!isVideo) _recentUploadCache[publicUrl] = bytes;
      if (isVideo) _decryptedMediaCache[publicUrl] = bytes;

      // Mark pending as uploaded — stays visible until _loadMessages picks up the real message
      if (mounted) setState(() => _pendingUploads[tempId]!['uploadedUrl'] = publicUrl);

      final row = <String, dynamic>{
        'convo_id': widget.convoId,
        'sender_id': _uid,
        'type': mediaType,
        'media_url': publicUrl,
        'v': _sessionVersion,
      };
      if (dimensions != null) row['blob'] = dimensions;
      await _supa.from('messages').insert(row);
      PushSender.instance.notify(recipientId: widget.friendUid, msgType: mediaType);
    } catch (e) {
      if (mounted) {
        setState(() => _pendingUploads.remove(tempId));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Upload failed: $e')),
        );
      }
    }
  }

  Future<void> _pickAndSendLockedImage() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      maxWidth: 1920,
      maxHeight: 1920,
      imageQuality: 80,
      source: ImageSource.gallery,
    );
    if (picked == null || !mounted) return;

    final bytes = await picked.readAsBytes();
    if (bytes.length > 30 * 1024 * 1024) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('File too large. Max 30 MB.')),
        );
      }
      return;
    }

    final decoded = await decodeImageFromList(bytes);
    final dims = '${decoded.width}x${decoded.height}';

    // Enter lock mode — password typed in input bar
    setState(() {
      _lockPendingBytes = bytes;
      _lockPendingDims = dims;
      _lockPassword = '';
      _keyboardVisible = true;
      _showToolbarExpanded = false;
    });
  }

  Future<void> _toggleRecording() async {
    if (_isRecording) {
      await _stopAndSendRecording();
    } else {
      await _startRecording();
    }
  }

  Future<void> _startRecording() async {
    if (!await _recorder.hasPermission()) return;
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _recorder.start(
      const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 128000),
      path: path,
    );
    setState(() {
      _isRecording = true;
      _recordingStart = DateTime.now();
      _liveTranscript = '';
    });

    // Start live speech recognition alongside recording
    final available = await _speech.initialize(
      onError: (_) {},
      onStatus: (_) {},
    );
    if (available) {
      // Use device locale so it transcribes the right language
      final systemLocale = await _speech.systemLocale();
      final localeId = systemLocale?.localeId ?? '';

      _speech.listen(
        onResult: (result) {
          if (!_session.hasActiveSession) return;
          final words = result.recognizedWords;
          if (words.isNotEmpty) {
            _liveTranscript = _session.encodeMessage(_stripDiacritics(words));
          }
        },
        localeId: localeId,
        listenOptions: stt.SpeechListenOptions(
          listenMode: stt.ListenMode.dictation,
          cancelOnError: false,
          partialResults: true,
        ),
      );
    }
  }

  Future<void> _stopAndSendRecording() async {
    final path = await _recorder.stop();
    await _speech.stop();
    final durationMs = _recordingStart != null
        ? DateTime.now().difference(_recordingStart!).inMilliseconds
        : 0;
    final replyId = _replyTo?['id']?.toString();
    final transcript = _liveTranscript;
    final voiceSessionId = _session.activeSessionId ?? '';
    final voiceSecret = _deriveSharedSecret(_sessionVersion);
    final voiceVersion = _sessionVersion;

    // Optimistic UI — show voice bubble immediately
    final tempId = 'pending_${_pendingCounter++}';
    setState(() {
      _isRecording = false; _replyTo = null; _liveTranscript = '';
      _pendingUploads[tempId] = {
        'type': 'voice',
        'durationMs': durationMs,
        'transcript': transcript,
        'sessionId': voiceSessionId,
        'sharedSecret': voiceSecret,
        'progress': 0.0,
      };
    });
    if (path == null) { setState(() => _pendingUploads.remove(tempId)); return; }

    try {
      final rawBytes = await File(path).readAsBytes();
      // Encrypt audio with current session E2E key
      final uploadBytes = _e2e != null
          ? _e2e!.encryptBytes(Uint8List.fromList(rawBytes))
          : Uint8List.fromList(rawBytes);
      final fileName =
          '${widget.convoId}/${DateTime.now().millisecondsSinceEpoch}_voice.enc';
      await _supa.storage.from('chat-media').uploadBinary(
        fileName,
        uploadBytes,
        fileOptions: const FileOptions(contentType: 'application/octet-stream'),
      );
      final publicUrl = _supa.storage.from('chat-media').getPublicUrl(fileName);

      if (mounted) setState(() => _pendingUploads[tempId]!['uploadedUrl'] = publicUrl);

      final row = <String, dynamic>{
        'convo_id': widget.convoId,
        'sender_id': _uid,
        'type': 'voice',
        'media_url': publicUrl,
        'duration_ms': durationMs,
        'v': voiceVersion,
      };
      if (replyId != null) row['reply_to'] = replyId;
      // Encrypt and attach transcript if available
      if (transcript.isNotEmpty && _e2e != null) {
        row['transcript_blob'] = _e2e!.encrypt(transcript);
      }
      await _supa.from('messages').insert(row);
      PushSender.instance.notify(recipientId: widget.friendUid, msgType: 'voice');
    } catch (e) {
      if (mounted) {
        setState(() => _pendingUploads.remove(tempId));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Voice upload failed: $e')),
        );
      }
    }
  }

  void _openProfileSheet() {
    Navigator.push(
      context,
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => FriendProfilePage(
          friendUid: widget.friendUid,
          friendUsername: widget.friendUsername,
          nickname: _friendNickname,
          avatarBytes: _friendAvatar,
          currentUid: _uid,
          convoId: widget.convoId,
          chatBg: _chatBg,
          bubbleColor: _bubbleColor,
          deriveSecret: _deriveSharedSecret,
          onAvatarChanged: (bytes) {
            setState(() => _friendAvatar = bytes);
          },
          onNicknameChanged: (name) {
            setState(() => _friendNickname = name);
            LocalNickname.set(widget.friendUid, name);
          },
          onBgChanged: (bg) async {
            if (bg == 'custom') {
              await _loadCustomBg();
            }
            setState(() => _chatBg = bg);
            const storage = FlutterSecureStorage();
            await storage.write(key: 'chat_bg_theme_${widget.convoId}', value: bg);
          },
          onBubbleColorChanged: (color) async {
            _bubbleAccent = color;
            setState(() {});
            const storage = FlutterSecureStorage();
            final hex = (color.a * 255).round().toRadixString(16).padLeft(2, '0') +
                (color.r * 255).round().toRadixString(16).padLeft(2, '0') +
                (color.g * 255).round().toRadixString(16).padLeft(2, '0') +
                (color.b * 255).round().toRadixString(16).padLeft(2, '0');
            await storage.write(
              key: 'chat_bubble_color_${widget.convoId}',
              value: hex,
            );
          },
          onBubbleGradientChanged: (colors) async {
            _bubbleGradientNotifier.value = colors;
            const storage = FlutterSecureStorage();
            final hexList = colors.map((c) {
              return (c.a * 255).round().toRadixString(16).padLeft(2, '0') +
                  (c.r * 255).round().toRadixString(16).padLeft(2, '0') +
                  (c.g * 255).round().toRadixString(16).padLeft(2, '0') +
                  (c.b * 255).round().toRadixString(16).padLeft(2, '0');
            }).join(',');
            await storage.write(
              key: 'chat_bubble_grad_${widget.convoId}',
              value: hexList,
            );
          },
          onDeleteConversation: () async {
            try {
              final token = _supa.auth.currentSession?.accessToken;
              await _supa.functions.invoke('nuke-convo',
                body: {'convo_id': widget.convoId},
                headers: {'Authorization': 'Bearer $token'},
              );
            } catch (e) {
              debugPrint('Nuke convo error: $e');
            }
            if (mounted) {
              Navigator.pop(context);
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

  // --- Vanish-mode style drag-up gesture ---
  void _onPointerDown(PointerDownEvent e) {
    _lastPointerY = e.position.dy;
    _trackingPull = false;
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (_keyRotationTriggered) return;
    final dy = _lastPointerY - e.position.dy;
    _lastPointerY = e.position.dy;

    if (!_trackingPull) {
      if (!_scrollController.hasClients) return;
      final pos = _scrollController.position;
      _atNewestMessage = pos.pixels <= pos.minScrollExtent + 1.0;
      if (_atNewestMessage && dy > 0) {
        _trackingPull = true;
      } else {
        return;
      }
    }

    if (dy < 0 && _pullUpOffset > 0) {
      setState(() {
        _pullUpOffset = (_pullUpOffset + dy * 1.5).clamp(0.0, 160.0);
      });
      return;
    }

    if (dy > 0) {
      setState(() {
        _pullUpOffset = (_pullUpOffset + dy * 0.4).clamp(0.0, 160.0);
      });
    }
  }

  void _onPointerUp(PointerEvent e) {
    final wasAtThreshold = _pullUpOffset >= 150;
    _trackingPull = false;
    if (wasAtThreshold && !_keyRotationTriggered) {
      _keyRotationTriggered = true;
      HapticFeedback.heavyImpact();
      _rotateMapping();
    }
    if (_pullUpOffset > 0) _animateReset();
  }

  void _animateReset() {
    final start = _pullUpOffset;
    late void Function() listener;
    listener = () {
      if (mounted) {
        setState(() {
          _pullUpOffset = start * (1.0 - _pullResetController.value);
        });
        if (_pullResetController.value >= 1.0) {
          _pullResetController.removeListener(listener);
          setState(() { _pullUpOffset = 0; _keyRotationTriggered = false; });
        }
      }
    };
    _pullResetController.addListener(listener);
    _pullResetController.forward(from: 0.0);
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
                    onTap: () => Navigator.pop(context),
                    child: _headerPill(
                      child: SvgPicture.asset('assets/back.svg',
                          width: 16, height: 16,
                          colorFilter: const ColorFilter.mode(Colors.white70, BlendMode.srcIn)),
                      width: 42,
                    ),
                  ),
                  const Spacer(),
                  _headerPill(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      child: Text(
                        _displayName,
                        style: const TextStyle(
                          color: Colors.white, fontWeight: FontWeight.w600, fontSize: 15,
                        ),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                    ),
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: _openProfileSheet,
                    child: GlassPill(
                      width: 42,
                      height: 42,
                      borderRadius: 21,
                      child: Padding(
                        padding: const EdgeInsets.all(3),
                        child: ClipOval(
                          child: _friendAvatar != null
                              ? Image.memory(_friendAvatar!, width: 36, height: 36, fit: BoxFit.cover)
                              : Center(
                                  child: Text(
                                    _displayName.isNotEmpty ? _displayName[0].toUpperCase() : '?',
                                    style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600),
                                  ),
                                ),
                        ),
                      ),
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
          if (_chatBg == 'image')
            Positioned.fill(
              child: Image.asset('assets/signup.png', fit: BoxFit.cover),
            ),
          if (_chatBg == 'image')
            Positioned.fill(
              child: Container(color: Colors.black.withValues(alpha: 0.4)),
            ),
          if (_chatBg == 'custom' && _customBgBytes != null)
            Positioned.fill(
              child: _customBgTransform != null
                  ? ClipRect(
                      child: Transform(
                        transform: _customBgTransform!,
                        child: Image.memory(_customBgBytes!, fit: BoxFit.contain),
                      ),
                    )
                  : Image.memory(_customBgBytes!, fit: BoxFit.contain),
            ),
          if (_chatBg == 'custom' && _customBgBytes != null)
            Positioned.fill(
              child: Container(color: Colors.black.withValues(alpha: 0.35)),
            ),
          GestureDetector(
            onTap: () {
              if (_keyboardVisible) setState(() => _keyboardVisible = false);
            },
            child: Column(children: [Expanded(child: _buildMessages())]),
          ),

          Positioned(
            top: 0, left: 0, right: 0,
            child: IgnorePointer(
              child: Container(
                height: topPadding + 80,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter, end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.85),
                      Colors.black.withValues(alpha: 0.4),
                      Colors.black.withValues(alpha: 0.0),
                    ],
                    stops: const [0.0, 0.55, 1.0],
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            left: 0, right: 0, bottom: 0,
            child: _keyboardVisible
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildInputBar(),
                      const SizedBox(height: 6),
                      if (_showGifPicker)
                        GifPicker(
                          key: ValueKey(_mediaPickerTab),
                          onGifSelected: _onGifSelected,
                          onStickerDragStart: _onStickerDragStart,
                          onStickerDragUpdate: _onStickerDragUpdate,
                          onStickerDragEnd: _onStickerDragEnd,
                          onTabChanged: (tab) => _mediaPickerTab = tab,
                          externalQuery: _plainText,
                          height: 200,
                          initialTab: _mediaPickerTab,
                        ),
                      if (_showGifPicker)
                        StrokeKeyboard(
                          enabled: _session.hasActiveSession,
                          onKeyTap: _onKeyTap,
                          onBackspace: _onBackspace,
                          onReturn: () {},
                          onCursorMove: _onCursorMove,
                          onEmojiToggle: () => setState(() => _showEmojiPicker = !_showEmojiPicker),
                          emojiMode: _showEmojiPicker,
                        )
                      else if (_showEmojiPicker)
                        ClipRRect(
                          borderRadius: const BorderRadius.only(
                            topLeft: Radius.circular(12),
                            topRight: Radius.circular(12),
                          ),
                          child: EmojiPicker(
                            height: 300,
                            onEmojiSelected: (emoji) => _onKeyTap(emoji, emoji),
                            onBackspace: _onBackspace,
                            onSwitchToKeyboard: () => setState(() => _showEmojiPicker = false),
                          ),
                        )
                      else
                        ClipRRect(
                          borderRadius: const BorderRadius.only(
                            topLeft: Radius.circular(12),
                            topRight: Radius.circular(12),
                          ),
                          child: StrokeKeyboard(
                            enabled: _session.hasActiveSession,
                            onKeyTap: _onKeyTap,
                            onBackspace: _onBackspace,
                            onReturn: () {},
                            onCursorMove: _onCursorMove,
                            onEmojiToggle: () => setState(() => _showEmojiPicker = !_showEmojiPicker),
                            emojiMode: _showEmojiPicker,
                          ),
                        ),
                    ],
                  )
                : Padding(
                    padding: EdgeInsets.only(bottom: MediaQuery.of(context).padding.bottom),
                    child: _buildInputBar(),
                  ),
          ),
          if (_pullUpOffset > 10)
            Positioned(
              bottom: 350, left: 0, right: 0,
              child: Center(
                child: AnimatedOpacity(
                  opacity: (_pullUpOffset / 60).clamp(0.0, 1.0),
                  duration: const Duration(milliseconds: 100),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 28, height: 28,
                        child: CustomPaint(
                          painter: _ArcProgressPainter(
                            progress: (_pullUpOffset / 150).clamp(0.0, 1.0),
                            color: _pullUpOffset >= 150
                                ? _bubbleColor
                                : Colors.white.withValues(alpha: 0.5),
                            strokeWidth: 2.0,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _keyRotationTriggered ? 'Key changed' : 'Swipe up to change key',
                        style: TextStyle(
                          color: _keyRotationTriggered
                              ? _bubbleColor
                              : Colors.white.withValues(alpha: 0.35),
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _headerPill({required Widget child, double? width}) {
    return GlassPill(
      width: width,
      child: child,
    );
  }


  Widget _buildMessages() {
    return Listener(
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerUp,
      child: Transform.translate(
        offset: Offset(0, -_pullUpOffset),
        child: _buildMessageList(),
      ),
    );
  }

  // Recording slide-to-cancel state
  double _cancelSlide = 0; // 0..1 where 1 = fully cancelled

  String _replyPreview(Map<String, dynamic> msg) {
    final type = msg['type'] as String?;
    if (type == 'gif') return 'GIF';
    if (type == 'image') return 'Photo';
    if (type == 'video') return 'Video';
    if (type == 'voice') return 'Voice message';
    if (type == 'locked_image') return '🔒 Locked image';
    if (type == 'sv') return '🔊 Sound Sticker';
    return 'Message';
  }

  /// Get image URL from a message if it's an image/gif
  String? _replyImageUrl(Map<String, dynamic> msg) {
    final type = msg['type'] as String?;
    if (type == 'image') return msg['media_url'] as String?;
    if (type == 'gif' || type == 'sticker') return msg['gif_url'] as String?;
    return null;
  }

  void _setReply(Map<String, dynamic> msg) {
    setState(() => _replyTo = msg);
    if (!_keyboardVisible) setState(() => _keyboardVisible = true);
  }

  Future<void> _deleteMessage(String msgId) async {
    setState(() {
      _deletingIds.add(msgId);
    });
    // Wait for shrink animation
    await Future.delayed(const Duration(milliseconds: 350));
    await _supa.from('messages').delete().eq('id', msgId);
    if (mounted) {
      setState(() {
        _deletingIds.remove(msgId);
        _messages.removeWhere((m) => m['id']?.toString() == msgId);
      });
    }
  }

  // ── Placed stickers ──────────────────────────────────────────
  Future<void> _loadPlacedStickers() async {
    try {
      final res = await _supa
          .from('placed_stickers')
          .select()
          .eq('convo_id', widget.convoId)
          .order('created_at', ascending: true);
      if (mounted) {
        setState(() => _placedStickers = List<Map<String, dynamic>>.from(res));
      }
    } catch (_) {}
  }

  Future<void> _placeStickerAt(String url, Offset position, double scale) async {
    // Find the closest visible message to the drop point
    String? anchorMsgId;
    double bestDist = double.infinity;
    Offset? anchorTopLeft;

    for (final entry in _messageKeys.entries) {
      final key = entry.value;
      final ctx = key.currentContext;
      if (ctx == null) continue;
      final box = ctx.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) continue;
      final topLeft = box.localToGlobal(Offset.zero);
      final center = topLeft + Offset(box.size.width / 2, box.size.height / 2);
      final dist = (center - position).distance;
      if (dist < bestDist) {
        bestDist = dist;
        anchorMsgId = entry.key;
        anchorTopLeft = topLeft;
      }
    }

    if (anchorMsgId == null) return; // no messages visible

    // Store offset relative to the message widget
    final screenW = MediaQuery.of(context).size.width;
    final offsetX = (position.dx) / screenW; // fraction of screen width
    final offsetY = position.dy - anchorTopLeft!.dy; // px from message top

    final sticker = <String, dynamic>{
      'convo_id': widget.convoId,
      'sender_id': _uid,
      'url': url,
      'message_id': anchorMsgId,
      'offset_x': offsetX,
      'offset_y': offsetY,
      'scale': scale,
    };
    try {
      final res = await _supa.from('placed_stickers').insert(sticker).select().single();
      if (mounted) setState(() => _placedStickers.add(res));
    } catch (_) {}
  }

  /// Builds placed sticker widgets for a specific message.
  /// Returns empty list if no stickers are anchored to [msgId].
  List<Widget> _buildStickersForMessage(String msgId) {
    final screenW = MediaQuery.of(context).size.width;
    final stickers = <Widget>[];
    for (final s in _placedStickers) {
      if (s['message_id']?.toString() != msgId) continue;
      final ox = (s['offset_x'] as num?)?.toDouble() ?? 0.5;
      final oy = (s['offset_y'] as num?)?.toDouble() ?? 0;
      final sc = (s['scale'] as num?)?.toDouble() ?? 1.0;
      final url = s['url'] as String? ?? '';
      final stickerId = s['id']?.toString();

      // offset_x is fraction of screen width, offset_y is px from message top
      // Subtract the ListView's horizontal padding (12) since the Stack is
      // inside the padded item, not at screen origin.
      final left = ox * screenW - 50 * sc - 12;
      final top = oy - 50 * sc;

      stickers.add(Positioned(
        left: left,
        top: top,
        child: GestureDetector(
          onLongPress: stickerId != null ? () => _deletePlacedSticker(stickerId) : null,
          child: Image.network(
            url,
            width: 100 * sc,
            height: 100 * sc,
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) => const SizedBox.shrink(),
          ),
        ),
      ));
    }
    return stickers;
  }

  Future<void> _deletePlacedSticker(String stickerId) async {
    HapticFeedback.mediumImpact();
    setState(() {
      _placedStickers.removeWhere((s) => s['id']?.toString() == stickerId);
    });
    try {
      await _supa.from('placed_stickers').delete().eq('id', stickerId);
    } catch (_) {}
  }

  void _onStickerDragStart(String url, Offset globalPos) {
    _draggingStickerUrl = url;
    _dragPosition = globalPos;
    _stickerOverlay = OverlayEntry(builder: (_) {
      if (_dragPosition == null || _draggingStickerUrl == null) return const SizedBox.shrink();
      return Positioned(
        left: _dragPosition!.dx - 50,
        top: _dragPosition!.dy - 50,
        child: IgnorePointer(
          child: Image.network(
            _draggingStickerUrl!,
            width: 100,
            height: 100,
            fit: BoxFit.contain,
          ),
        ),
      );
    });
    Overlay.of(context).insert(_stickerOverlay!);
  }

  void _onStickerDragUpdate(Offset globalPos) {
    _dragPosition = globalPos;
    _stickerOverlay?.markNeedsBuild();
  }

  void _onStickerDragEnd() {
    _stickerOverlay?.remove();
    _stickerOverlay = null;
    if (_draggingStickerUrl != null && _dragPosition != null) {
      _placeStickerAt(_draggingStickerUrl!, _dragPosition!, 1.0);
    }
    _draggingStickerUrl = null;
    _dragPosition = null;
  }

  void _scrollToMessage(String msgId) {
    final idx = _messages.indexWhere((m) => m['id']?.toString() == msgId);
    if (idx < 0 || !_scrollController.hasClients) return;
    // Approximate: each message ~70px, list is reversed
    final offset = idx * 70.0;
    _scrollController.animateTo(
      offset,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  /// Find a message by id from the loaded list
  Map<String, dynamic>? _findMessage(String id) {
    try {
      return _messages.firstWhere((m) => m['id']?.toString() == id);
    } catch (_) {
      return null;
    }
  }

  Widget _buildInputBar() {
    final hasText = _strokeText.isNotEmpty;
    final showReply = _replyTo != null;
    return GestureDetector(
      onTap: () {
        if (!_keyboardVisible) setState(() => _keyboardVisible = true);
      },
      child: Container(
        padding: const EdgeInsets.only(left: 12, right: 12, top: 4, bottom: 0),
        color: Colors.transparent,
        child: _MotionGlass(
          borderRadius: 22,
          customClipper: showReply ? _SteppedPillClipper(replyFraction: 0.30, radius: 22) : null,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (showReply) _buildInlineReply(),
              Padding(
                padding: const EdgeInsets.only(left: 10, right: 4, top: 4, bottom: 4),
                child: _isRecording ? _buildRecordingContent() : _buildMessageContent(hasText),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInlineReply() {
    final type = _replyTo!['type'] as String?;
    final imgUrl = _replyImageUrl(_replyTo!);
    final preview = _replyPreview(_replyTo!);
    final isTextMsg = type == null;
    return Align(
      alignment: Alignment.centerLeft,
      child: FractionallySizedBox(
        widthFactor: 0.30,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 6, 4),
          child: Row(
            children: [
              GestureDetector(
                onTap: () => setState(() => _replyTo = null),
                child: Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Icon(Icons.close_rounded,
                      size: 15, color: Colors.white.withValues(alpha: 0.3)),
                ),
              ),

              if (imgUrl != null && type == 'image')
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: Builder(builder: (_) {
                      final b = _recentUploadCache[imgUrl] ?? _decryptedMediaCache[imgUrl];
                      if (b != null) return Image.memory(b, width: 24, height: 24, fit: BoxFit.cover);
                      return const SizedBox(width: 24, height: 24);
                    }),
                  ),
                ),
              if (imgUrl != null && type != 'image')
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: Image.network(
                      imgUrl,
                      width: 24, height: 24,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const SizedBox(width: 24, height: 24),
                    ),
                  ),
                ),
              if (type == 'voice')
                Padding(
                  padding: const EdgeInsets.only(right: 5),
                  child: Icon(Icons.mic_rounded,
                      size: 13, color: Colors.white.withValues(alpha: 0.35)),
                ),
              Expanded(
                child: isTextMsg
                    ? _buildReplyStrokePreview()
                    : Text(
                        preview,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.45),
                          fontSize: 13,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildReplyStrokePreview() {
    final blob = _replyTo!['blob'] as String? ?? '';
    final v = (_replyTo!['v'] as int?) ?? 0;
    final secret = _deriveSharedSecret(v);
    final e2e = E2EEncryption(secret);
    String strokePayload;
    try { strokePayload = e2e.decrypt(blob); } catch (_) { strokePayload = blob; }
    final sid = 'session_${widget.convoId}_v$v';
    return StrokeText(
      strokeText: strokePayload,
      sessionId: sid,
      sharedSecret: secret,
      style: TextStyle(
        color: Colors.white.withValues(alpha: 0.45),
        fontSize: 13,
      ),
      maxLines: 1,
    );
  }



  Widget _buildRecordingContent() {
    // Color fades from blue to red as user slides to cancel
    final sendColor = Color.lerp(
      _bubbleColor,
      const Color(0xFFFF453A),
      _cancelSlide,
    )!;

    return GestureDetector(
      onHorizontalDragUpdate: (d) {
        setState(() {
          _cancelSlide = (_cancelSlide - d.delta.dx / 150).clamp(0.0, 1.0);
        });
      },
      onHorizontalDragEnd: (_) {
        if (_cancelSlide > 0.7) {
          // Cancel
          _recorder.stop();
          _speech.stop();
          setState(() { _isRecording = false; _cancelSlide = 0; _liveTranscript = ''; });
        } else {
          setState(() => _cancelSlide = 0);
        }
      },
      child: Row(
        children: [
          // Pulsing red dot
          _RecordingDot(),
          const SizedBox(width: 8),
          // Timer
          _RecordingTimer(start: _recordingStart ?? DateTime.now()),
          const Spacer(),
          // Cancel button
          GestureDetector(
            onTap: () async {
              await _recorder.stop();
              await _speech.stop();
              setState(() { _isRecording = false; _cancelSlide = 0; _liveTranscript = ''; });
            },
            child: Container(
              width: 34, height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.08),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.close_rounded,
                  size: 18, color: Colors.white.withValues(alpha: 0.5)),
            ),
          ),
          const SizedBox(width: 6),
          // Send button — fades blue→red on slide
          GestureDetector(
            onTap: _stopAndSendRecording,
            child: Container(
              width: 34, height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: sendColor, shape: BoxShape.circle),
              child: SvgPicture.asset('assets/send.svg',
                  width: 16, height: 16,
                  colorFilter: const ColorFilter.mode(Colors.white, BlendMode.srcIn)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageContent(bool hasText) {
    final inUnlock = _isUnlockMode;
    final inLock = _isLockMode;
    final inPasswordMode = inUnlock || inLock;
    final hasContent = inPasswordMode
        ? (inUnlock ? _unlockPassword.isNotEmpty : _lockPassword.isNotEmpty)
        : hasText;
    final showClose = _showGifPicker || _showToolbarExpanded;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // Left: + button or close button
        if (!inPasswordMode)
          GestureDetector(
            onTap: () {
              setState(() {
                if (showClose) {
                  _showGifPicker = false;
                  _showToolbarExpanded = false;
                } else {
                  _showToolbarExpanded = true;
                }
              });
            },
            child: Padding(
              padding: const EdgeInsets.only(right: 6),
              child: AnimatedRotation(
                turns: showClose ? 0.125 : 0,
                duration: const Duration(milliseconds: 200),
                child: SizedBox(
                  width: 28,
                  height: 28,
                  child: Center(
                    child: Icon(
                      Icons.add_rounded,
                      color: _bubbleColor.withValues(alpha: showClose ? 0.9 : 0.7),
                      size: 24,
                    ),
                  ),
                ),
              ),
            ),
          ),
        if (inPasswordMode)
          GestureDetector(
            onTap: inUnlock ? _exitUnlockMode : _exitLockMode,
            child: Padding(
              padding: const EdgeInsets.only(right: 10),
              child: Icon(Icons.close_rounded,
                  color: Colors.white.withValues(alpha: 0.4), size: 22),
            ),
          ),
        if (inPasswordMode)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Icon(Icons.lock_rounded,
                size: 16, color: Colors.white.withValues(alpha: 0.25)),
          ),
        Expanded(
          child: _showToolbarExpanded && !inPasswordMode
              ? Row(
                  children: [
                    _inlineToolBtn(Icons.camera_alt_outlined, () {
                      setState(() => _showToolbarExpanded = false);
                      _openCamera();
                    }),
                    const SizedBox(width: 6),
                    _inlineToolBtn(Icons.photo_outlined, () {
                      setState(() => _showToolbarExpanded = false);
                      _pickAndSendMedia();
                    }),
                    const SizedBox(width: 6),
                    _inlineToolBtnSvg('assets/locked.svg', () {
                      setState(() => _showToolbarExpanded = false);
                      _pickAndSendLockedImage();
                    }),
                    const SizedBox(width: 6),
                    _inlineToolBtnSvg('assets/gif.svg', () => setState(() {
                      _showToolbarExpanded = false;
                      _mediaPickerTab = MediaTab.gifs;
                      _showGifPicker = true;
                    })),
                    const SizedBox(width: 6),
                    _inlineToolBtnSvg('assets/draw.svg', () {
                      setState(() => _showToolbarExpanded = false);
                      Navigator.push(
                        context,
                        PageRouteBuilder(
                          pageBuilder: (_, __, ___) => DrawboardScreen(
                            convoId: widget.convoId,
                            friendEmail: widget.friendUsername,
                          ),
                          transitionsBuilder: (_, anim, __, child) =>
                              FadeTransition(opacity: CurvedAnimation(parent: anim, curve: Curves.easeOut), child: child),
                          transitionDuration: const Duration(milliseconds: 250),
                        ),
                      );
                    }),
                  ],
                )
              : inPasswordMode
                    ? Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          () {
                            final pw = inUnlock ? _unlockPassword : _lockPassword;
                            if (pw.isEmpty) return inLock ? 'Set password…' : 'Enter password…';
                            return '•' * pw.length;
                          }(),
                          style: TextStyle(
                            fontSize: 16,
                            color: () {
                              final pw = inUnlock ? _unlockPassword : _lockPassword;
                              return pw.isEmpty
                                  ? Colors.white.withValues(alpha: 0.35)
                                  : Colors.white;
                            }(),
                            letterSpacing: () {
                              final pw = inUnlock ? _unlockPassword : _lockPassword;
                              return pw.isEmpty ? -0.2 : 3.0;
                            }(),
                          ),
                        ),
                      )
                    : hasText
                        ? Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: GestureDetector(
                              onTapDown: (d) {
                                final charIdx = _charIndexFromOffset(d.localPosition);
                                if (charIdx >= 0) {
                                  // If tapping inside an existing selection, deselect and place cursor
                                  if (_selStart >= 0 && _selEnd >= 0 && _selStart != _selEnd) {
                                    final lo = _selStart < _selEnd ? _selStart : _selEnd;
                                    final hi = _selStart < _selEnd ? _selEnd : _selStart;
                                    if (charIdx >= lo && charIdx <= hi) {
                                      setState(() {
                                        _cursorPos = charIdx;
                                        _selStart = -1;
                                        _selEnd = -1;
                                      });
                                      return;
                                    }
                                  }
                                  final bounds = _wordBoundsAt(charIdx);
                                  setState(() {
                                    _selStart = bounds[0];
                                    _selEnd = bounds[1];
                                    _cursorPos = bounds[1];
                                  });
                                } else {
                                  _clearSelection();
                                }
                              },
                              onPanStart: (d) {
                                final charIdx = _charIndexFromOffset(d.localPosition);
                                if (charIdx >= 0 && _selStart < 0) {
                                  final bounds = _wordBoundsAt(charIdx);
                                  setState(() {
                                    _selStart = bounds[0];
                                    _selEnd = bounds[1];
                                    _cursorPos = bounds[1];
                                  });
                                }
                              },
                              onPanUpdate: (d) {
                                if (_selStart < 0) return;
                                final charIdx = _charIndexFromOffset(d.localPosition);
                                if (charIdx >= 0) {
                                  // Extend selection to the word boundary at drag position
                                  final bounds = _wordBoundsAt(charIdx);
                                  setState(() {
                                    // Keep the original anchor, extend to the dragged word edge
                                    if (charIdx >= _selStart) {
                                      _selEnd = bounds[1];
                                      _cursorPos = bounds[1];
                                    } else {
                                      _selEnd = bounds[0];
                                      _cursorPos = bounds[0];
                                    }
                                  });
                                }
                              },
                              child: StrokeText(
                                strokeText: _strokeText,
                                sessionId: _session.activeSessionId ?? '',
                                sharedSecret: _deriveSharedSecret(_sessionVersion),
                                style: const TextStyle(
                                  fontSize: 16,
                                  color: Colors.white,
                                  letterSpacing: -0.2,
                                  height: 1.15,
                                ),
                                maxLines: 100,
                                sizeMaxLines: 3,
                                cursorPosition: _cursorPos,
                                selectionStart: _selStart,
                                selectionEnd: _selEnd,
                              ),
                            ),
                          )
                        : Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              'Message…',
                              style: TextStyle(
                                fontSize: 16,
                                color: Colors.white.withValues(alpha: 0.35),
                                letterSpacing: -0.2,
                              ),
                            ),
                          ),
        ),
        const SizedBox(width: 8),
        // Right: mic/send toggle (or unlock/lock button)
        if (inPasswordMode)
          AnimatedBuilder(
            animation: _sendBounceCtrl,
            builder: (context, child) {
              final t = _sendBounceCtrl.value;
              final scale = 1.0 - 0.25 * Curves.easeOut.transform(
                t < 0.4 ? t / 0.4 : 1.0 - (t - 0.4) / 0.6,
              );
              return AnimatedOpacity(
                opacity: hasContent ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 150),
                child: Transform.scale(
                  scale: hasContent ? scale : 0.6,
                  child: child,
                ),
              );
            },
            child: GestureDetector(
              onTap: hasContent
                  ? (inUnlock ? _onUnlockSend : _onLockSend)
                  : null,
              child: Container(
                height: 34,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: _bubbleColor,
                  borderRadius: BorderRadius.circular(17),
                ),
                child: Text(
                  inUnlock ? 'Unlock' : 'Lock',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          )
        else
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            transitionBuilder: (child, anim) => ScaleTransition(scale: anim, child: child),
            child: hasContent
                ? GestureDetector(
                    key: const ValueKey('send'),
                    onTap: _onSend,
                    child: AnimatedBuilder(
                      animation: _sendBounceCtrl,
                      builder: (context, child) {
                        final t = _sendBounceCtrl.value;
                        final scale = 1.0 - 0.25 * Curves.easeOut.transform(
                          t < 0.4 ? t / 0.4 : 1.0 - (t - 0.4) / 0.6,
                        );
                        return Transform.scale(scale: scale, child: child);
                      },
                      child: Container(
                        width: 34,
                        height: 34,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: _bubbleColor,
                          shape: BoxShape.circle,
                        ),
                        child: SvgPicture.asset('assets/send.svg',
                            width: 16, height: 16,
                            colorFilter: const ColorFilter.mode(Colors.white, BlendMode.srcIn)),
                      ),
                    ),
                  )
                : GestureDetector(
                    key: const ValueKey('mic'),
                    onTap: _toggleRecording,
                    onLongPress: _startRecording,
                    child: Container(
                      width: 34,
                      height: 34,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: _bubbleColor,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.mic_none_rounded,
                          size: 20, color: Colors.white),
                    ),
                  ),
          ),
      ],
    );
  }


  Widget _inlineToolBtn(IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 34,
        height: 34,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: _bubbleColor,
          shape: BoxShape.circle,
        ),
        child: Icon(icon, size: 18, color: Colors.white),
      ),
    );
  }

  Widget _inlineToolBtnSvg(String asset, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 34,
        height: 34,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: _bubbleColor,
          shape: BoxShape.circle,
        ),
        child: SvgPicture.asset(asset,
            width: 15, height: 15,
            colorFilter: const ColorFilter.mode(
                Colors.white, BlendMode.srcIn)),
      ),
    );
  }

  Widget _buildTimestamp(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);
    String label;
    if (diff.inDays == 0 && now.day == time.day) {
      // Today — just show time
      label = '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    } else if (diff.inDays == 1 || (diff.inDays == 0 && now.day != time.day)) {
      label = 'Yesterday ${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    } else if (diff.inDays < 7) {
      const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
      label = '${days[time.weekday - 1]} ${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    } else {
      label = '${time.day}/${time.month}/${time.year} ${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Center(
        child: Text(
          label,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.25),
            fontSize: 11,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }

  void _openImageViewerBytes(Uint8List bytes, {Map<String, dynamic>? message}) {
    final senderId = message?['sender_id'] as String? ?? '';
    final senderName = senderId == _uid ? 'you' : _displayName;
    final sentAt = message?['created_at'] != null
        ? DateTime.tryParse(message!['created_at'].toString())
        : null;
    Navigator.of(context).push(
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => MediaViewerScreen(
          bytes: bytes,
          senderName: senderName,
          sentAt: sentAt,
          session: _session,
          e2e: _e2e,
          sessionVersion: _sessionVersion,
          deriveSecret: _deriveSharedSecret,
          onSendReply: message != null
              ? (stroke, blob) => _sendReplyFromViewer(blob, message)
              : null,
        ),
        transitionsBuilder: (_, anim, __, child) {
          return FadeTransition(
            opacity: CurvedAnimation(parent: anim, curve: Curves.easeOut),
            child: child,
          );
        },
        transitionDuration: const Duration(milliseconds: 200),
      ),
    );
  }


  /// Send an already-encrypted reply from the media viewer.
  Future<void> _sendReplyFromViewer(String encryptedBlob, Map<String, dynamic> replyMsg) async {
    if (!_session.hasActiveSession) return;
    final replyId = replyMsg['id']?.toString();
    final row = <String, dynamic>{
      'convo_id': widget.convoId,
      'sender_id': _uid,
      'session_id': _session.activeSessionId!,
      'blob': encryptedBlob,
      'v': _sessionVersion,
    };
    if (replyId != null) row['reply_to'] = replyId;
    await _supa.from('messages').insert(row);
    PushSender.instance.notify(recipientId: widget.friendUid);
  }

  /// Download encrypted media, decrypt, cache, and trigger rebuild.
  void _decryptAndCacheMedia(String url, int version) {
    if (_decryptedMediaCache.containsKey(url)) return;
    if (_decryptingUrls.contains(url)) return;
    _decryptingUrls.add(url);
    () async {
      try {
        final resp = await http.get(Uri.parse(url));
        if (resp.statusCode == 200) {
          final secret = _deriveSharedSecret(version);
          final e2e = E2EEncryption(secret);
          final decrypted = e2e.decryptBytes(Uint8List.fromList(resp.bodyBytes));
          if (mounted) {
            setState(() {
              _decryptedMediaCache[url] = decrypted;
            });
          }
        }
      } catch (_) {}
      _decryptingUrls.remove(url);
    }();
  }

  /// Generate video thumbnail from decrypted bytes by writing to temp file first.
  void _generateVideoThumbnailFromBytes(String key, Uint8List videoBytes) {
    if (_videoThumbnails.containsKey(key)) return;
    _videoThumbnails[key] = Uint8List(0);
    () async {
      try {
        final dir = await getTemporaryDirectory();
        final tmpFile = File('${dir.path}/thumb_${key.hashCode}.mp4');
        await tmpFile.writeAsBytes(videoBytes);
        final bytes = await VideoThumbnail.thumbnailData(
          video: tmpFile.path,
          imageFormat: ImageFormat.JPEG,
          maxWidth: 320,
          quality: 50,
        );
        if (bytes != null && bytes.isNotEmpty && mounted) {
          setState(() => _videoThumbnails[key] = bytes);
        }
      } catch (_) {}
    }();
  }

  /// Open video viewer from decrypted bytes — writes to temp file and plays locally.
  void _openVideoViewerBytes(Uint8List videoBytes, {Map<String, dynamic>? message}) {
    final senderId = message?['sender_id'] as String? ?? '';
    final senderName = senderId == _uid ? 'you' : _displayName;
    final sentAt = message?['created_at'] != null
        ? DateTime.tryParse(message!['created_at'].toString())
        : null;
    () async {
      final dir = await getTemporaryDirectory();
      final tmpFile = File('${dir.path}/play_${DateTime.now().millisecondsSinceEpoch}.mp4');
      await tmpFile.writeAsBytes(videoBytes);
      if (!mounted) return;
      Navigator.of(context).push(
        PageRouteBuilder(
          pageBuilder: (_, __, ___) => MediaViewerScreen(
            url: tmpFile.path,
            isVideo: true,
            isLocalFile: true,
            senderName: senderName,
            sentAt: sentAt,
            session: _session,
            e2e: _e2e,
            sessionVersion: _sessionVersion,
            deriveSecret: _deriveSharedSecret,
            onSendReply: message != null
                ? (stroke, blob) => _sendReplyFromViewer(blob, message)
                : null,
          ),
          transitionsBuilder: (_, anim, __, child) {
            return FadeTransition(
              opacity: CurvedAnimation(parent: anim, curve: Curves.easeOut),
              child: child,
            );
          },
          transitionDuration: const Duration(milliseconds: 200),
        ),
      );
    }();
  }

  Future<void> _tryUnlockImage(String msgId, String mediaUrl, String password) async {
    try {
      final uri = Uri.parse(mediaUrl);
      final response = await HttpClient().getUrl(uri).then((r) => r.close());
      final chunks = <List<int>>[];
      await for (final chunk in response) {
        chunks.add(chunk);
      }
      final encBytes = Uint8List.fromList(chunks.expand((c) => c).toList());

      final passKey = Uint8List.fromList(
        sha256.convert(utf8.encode(password)).bytes,
      );
      final passE2e = E2EEncryption(passKey);
      final decrypted = passE2e.decryptBytes(encBytes);

      if (mounted) {
        setState(() {
          _unlockedImages[msgId] = decrypted;
          _justUnlockedIds.add(msgId);
        });
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Wrong password')),
        );
      }
    }
  }

  Widget _buildMessageList() {
    if (_messages.isEmpty && _pendingUploads.isEmpty) {
      return Center(
        child: Text('Send a message',
            style: TextStyle(color: Colors.white.withValues(alpha: 0.3), fontSize: 15)),
      );
    }
    // Compute key-changed divider position dynamically.
    // Messages are newest-first (DESC). Find the first message older than _keyChangedAt.
    int? computedDividerPos;
    if (_keyChangedAt != null) {
      for (int i = 0; i < _messages.length; i++) {
        final t = DateTime.tryParse(_messages[i]['created_at']?.toString() ?? '');
        if (t != null && t.isBefore(_keyChangedAt!)) {
          computedDividerPos = i; // insert divider at this index (before older messages)
          break;
        }
      }
      // If all messages are newer, put divider after all of them
      computedDividerPos ??= _messages.length;
    }
    final pendingCount = _pendingUploads.length;
    final hasKeyDivider = computedDividerPos != null;
    final dividerPos = computedDividerPos ?? -1;
    final totalCount = pendingCount + _messages.length + (hasKeyDivider ? 1 : 0);

    return ListView.builder(
      controller: _scrollController,
      reverse: true,
      physics: const BouncingScrollPhysics(),
      padding: EdgeInsets.fromLTRB(6, MediaQuery.of(context).padding.top + 52, 6,
          _keyboardVisible ? 340 + (_inputLines - 1) * 20.0 : MediaQuery.of(context).padding.bottom + 70),
      itemCount: totalCount,
      itemBuilder: (context, index) {
        // Pending uploads — shown at the newest position (index 0..pendingCount-1)
        if (index < pendingCount) {
          final entry = _pendingUploads.entries.elementAt(pendingCount - 1 - index);
          final p = entry.value;
          final pType = p['type'] as String;
          final isUploaded = p['uploadedUrl'] != null;

          // Voice pending
          if (pType == 'voice') {
            final dMs = p['durationMs'] as int? ?? 0;
            final transcript = p['transcript'] as String? ?? '';
            final sid = p['sessionId'] as String? ?? '';
            final secret = p['sharedSecret'] as Uint8List?;
            return Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Opacity(
                opacity: isUploaded ? 1.0 : 0.7,
                child: _ScreenGradientBubble(
                  gradientNotifier: _bubbleGradientNotifier,
                  scrollController: _scrollController,
                  builder: (gradColors) => VoiceBubble(
                    audioUrl: '',
                    isMe: true,
                    durationMs: dMs,
                    transcriptStrokes: transcript.isNotEmpty ? transcript : null,
                    sessionId: sid,
                    sharedSecret: secret,
                    borderRadius: BorderRadius.circular(22),
                    bubbleGradient: gradColors,
                    foregroundColor: _ScreenGradientBubbleState.textColorFor(gradColors),
                  ),
                ),
              ),
            );
          }

          // GIF / sticker / sv pending
          if (pType == 'gif' || pType == 'sticker' || pType == 'sv') {
            final gifUrl = p['gifUrl'] as String? ?? '';
            if (pType == 'sv') {
              return Align(
                alignment: Alignment.centerRight,
                child: Opacity(
                  opacity: isUploaded ? 1.0 : 0.5,
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 4),
                    constraints: const BoxConstraints(maxWidth: 140, maxHeight: 140),
                    child: _SvBubble(svUrl: gifUrl, onTap: () {}),
                  ),
                ),
              );
            }
            return Align(
              alignment: Alignment.centerRight,
              child: Container(
                margin: const EdgeInsets.only(bottom: 4),
                constraints: BoxConstraints(
                  maxWidth: pType == 'sticker'
                      ? 150
                      : MediaQuery.of(context).size.width * 0.55,
                ),
                child: Opacity(
                  opacity: isUploaded ? 1.0 : 0.7,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: Image.network(gifUrl, fit: BoxFit.cover),
                  ),
                ),
              ),
            );
          }

          // Image / video pending (existing logic)
          final pBytes = p['bytes'] as Uint8List;
          final pDims = p['dims'] as String?;

          double aspect = 1.0;
          if (pDims != null) {
            final dp = pDims.split('x');
            if (dp.length == 2) {
              final w = double.tryParse(dp[0]) ?? 0;
              final h = double.tryParse(dp[1]) ?? 0;
              if (w > 0 && h > 0) aspect = (w / h).clamp(0.65, 1.8);
            }
          }

          return Align(
            alignment: Alignment.centerRight,
            child: Container(
              margin: const EdgeInsets.only(bottom: 4),
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.40,
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Stack(
                  children: [
                    if (pType == 'image')
                      AspectRatio(
                        aspectRatio: aspect,
                        child: Image.memory(pBytes, fit: BoxFit.cover),
                      )
                    else
                      AspectRatio(
                        aspectRatio: aspect > 0.1 ? aspect : 1.0,
                        child: Container(
                          color: Colors.white.withValues(alpha: 0.05),
                          child: Center(
                            child: Container(
                              width: 48, height: 48,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: Colors.white.withValues(alpha: 0.15),
                              ),
                              child: const Icon(Icons.play_arrow_rounded,
                                  size: 28, color: Colors.white),
                            ),
                          ),
                        ),
                      ),
                    // Upload overlay — only while still uploading
                    if (!isUploaded)
                      Positioned.fill(
                        child: Container(
                          color: Colors.black.withValues(alpha: 0.35),
                          child: const Center(
                            child: SizedBox(
                              width: 28,
                              height: 28,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          );
        }

        // Offset index past pending items
        final realIndex = index - pendingCount;

        // Key changed divider
        if (hasKeyDivider && realIndex == dividerPos) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Center(
              child: Text(
                'Key changed',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.25),
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          );
        }

        // Adjust index for messages after the divider
        final msgIndex = hasKeyDivider && realIndex > dividerPos ? realIndex - 1 : realIndex;
        if (msgIndex >= _messages.length) return const SizedBox.shrink();

        final data = _messages[msgIndex];
        final msgId = data['id']?.toString() ?? '';
        final senderId = data['sender_id'] as String? ?? '';
        final isMe = senderId == _uid;
        final msgType = data['type'] as String?;
        final isNew = msgId.isNotEmpty && _seenMessageIds.add(msgId);

        // --- Grouping logic (list is reversed: index 0 = newest) ---
        final prevSender = msgIndex > 0 ? (_messages[msgIndex - 1]['sender_id'] as String? ?? '') : '';
        final nextSender = msgIndex < _messages.length - 1 ? (_messages[msgIndex + 1]['sender_id'] as String? ?? '') : '';
        // Time gap check — break group if messages are > 60s apart
        final myTime = DateTime.tryParse(data['created_at']?.toString() ?? '');
        final newerTime = msgIndex > 0 ? DateTime.tryParse(_messages[msgIndex - 1]['created_at']?.toString() ?? '') : null;
        final olderTime = msgIndex < _messages.length - 1 ? DateTime.tryParse(_messages[msgIndex + 1]['created_at']?.toString() ?? '') : null;
        final closeToNewer = newerTime != null && myTime != null && newerTime.difference(myTime).inSeconds.abs() <= 60;
        final closeToOlder = olderTime != null && myTime != null && myTime.difference(olderTime).inSeconds.abs() <= 60;
        final sameAsNewer = prevSender == senderId && closeToNewer;
        final sameAsOlder = nextSender == senderId && closeToOlder;
        // Position in group (visually: top = older, bottom = newer since list is reversed)
        // isFirst = top of visual group (oldest in run), isLast = bottom (newest)
        final isFirst = !sameAsOlder; // no same sender above (older)
        final isLast = !sameAsNewer;  // no same sender below (newer)
        final isSingle = isFirst && isLast;
        final groupGap = isLast ? 6.0 : 1.5;

        BorderRadius groupRadius([double r = 18]) {
          if (isSingle) {
            return BorderRadius.circular(r);
          }
          if (isFirst) {
            return BorderRadius.only(
              topLeft: Radius.circular(r), topRight: Radius.circular(r),
              bottomLeft: Radius.circular(isMe ? r : 4), bottomRight: Radius.circular(isMe ? 4 : r),
            );
          }
          if (isLast) {
            return BorderRadius.only(
              topLeft: Radius.circular(isMe ? r : 4), topRight: Radius.circular(isMe ? 4 : r),
              bottomLeft: Radius.circular(r), bottomRight: Radius.circular(r),
            );
          }
          // Middle — tight on the sender's side
          return BorderRadius.only(
            topLeft: Radius.circular(isMe ? r : 4), topRight: Radius.circular(isMe ? 4 : r),
            bottomLeft: Radius.circular(isMe ? r : 4), bottomRight: Radius.circular(isMe ? 4 : r),
          );
        }

        Widget bubble;

        // GIF message
        if (msgType == 'gif') {
          final gifUrl = data['gif_url'] as String? ?? '';
          bubble = Align(
            alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOutCubic,
              margin: EdgeInsets.only(bottom: groupGap),
              constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.40),
              child: ClipRRect(
                borderRadius: groupRadius(16),
                child: Image.network(
                  gifUrl,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(
                    height: 120,
                    color: Colors.white.withValues(alpha: 0.05),
                    child: Center(
                        child: SvgPicture.asset('assets/gif.svg',
                            width: 32, height: 32,
                            colorFilter: const ColorFilter.mode(Colors.white24, BlendMode.srcIn))),
                  ),
                ),
              ),
            ),
          );
        } else if (msgType == 'sticker') {
          final stickerUrl = data['gif_url'] as String? ?? '';
          bubble = Align(
            alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOutCubic,
              margin: EdgeInsets.only(bottom: groupGap),
              constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.4),
              child: Image.network(
                stickerUrl,
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => Container(
                  height: 100,
                  color: Colors.white.withValues(alpha: 0.05),
                  child: const Center(
                      child: Icon(Icons.sticky_note_2_outlined,
                          size: 32, color: Colors.white24)),
                ),
              ),
            ),
          );
        } else if (msgType == 'sv') {
          final svUrl = data['gif_url'] as String? ?? '';
          bubble = Align(
            alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOutCubic,
              margin: EdgeInsets.only(bottom: groupGap),
              constraints: const BoxConstraints(maxWidth: 140, maxHeight: 140),
              child: _SvBubble(svUrl: svUrl, onTap: () => _playSvAudio(svUrl)),
            ),
          );
        } else if (msgType == 'image') {
          final mediaUrl = data['media_url'] as String? ?? '';
          final maxW = MediaQuery.of(context).size.width * 0.40;
          // Parse natural dimensions from blob (format: "WxH")
          final dimBlob = data['blob'] as String? ?? '';
          final dimParts = dimBlob.split('x');
          double imgAspect = 1.0;
          if (dimParts.length == 2) {
            final w = double.tryParse(dimParts[0]) ?? 0;
            final h = double.tryParse(dimParts[1]) ?? 0;
            if (w > 0 && h > 0) imgAspect = w / h;
          }
          // Clamp aspect ratio: min 0.5 (tall), max 1.8 (wide)
          imgAspect = imgAspect.clamp(0.65, 1.8);
          final cachedBytes = _recentUploadCache[mediaUrl] ?? _decryptedMediaCache[mediaUrl];
          final msgVersion = (data['v'] as int?) ?? 0;
          // Trigger decryption if not cached
          if (cachedBytes == null) _decryptAndCacheMedia(mediaUrl, msgVersion);
          bubble = Align(
            alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
            child: GestureDetector(
              onTap: () {
                final bytes = _recentUploadCache[mediaUrl] ?? _decryptedMediaCache[mediaUrl];
                if (bytes != null) {
                  _openImageViewerBytes(bytes, message: data);
                }
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOutCubic,
                margin: EdgeInsets.only(bottom: groupGap),
                constraints: BoxConstraints(maxWidth: maxW),
                child: ClipRRect(
                  borderRadius: groupRadius(18),
                  child: AspectRatio(
                    aspectRatio: imgAspect,
                    child: cachedBytes != null
                        ? Image.memory(cachedBytes, fit: BoxFit.cover,
                            gaplessPlayback: true)
                        : Container(
                          color: Colors.white.withValues(alpha: 0.04),
                          child: Center(
                            child: SizedBox(
                              width: 32, height: 32,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                color: Colors.white.withValues(alpha: 0.3),
                              ),
                            ),
                          ),
                        ),
                  ),
                ),
              ),
            ),
          );
        } else if (msgType == 'locked_image') {
          final mediaUrl = data['media_url'] as String? ?? '';
          final msgId = data['id']?.toString() ?? '';
          final unlocked = _unlockedImages[msgId];
          final maxW = MediaQuery.of(context).size.width * 0.40;
          // Parse dimensions from blob format "hash|WxH"
          final blobStr = data['blob'] as String? ?? '';
          final pipeIdx = blobStr.indexOf('|');
          double lockedAspect = 1.0;
          if (pipeIdx > 0 && pipeIdx < blobStr.length - 1) {
            final dimStr = blobStr.substring(pipeIdx + 1);
            final dp = dimStr.split('x');
            if (dp.length == 2) {
              final w = double.tryParse(dp[0]) ?? 0;
              final h = double.tryParse(dp[1]) ?? 0;
              if (w > 0 && h > 0) lockedAspect = (w / h).clamp(0.65, 1.8);
            }
          }
          final justUnlocked = _justUnlockedIds.contains(msgId);
          bubble = Align(
            alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOutCubic,
              margin: EdgeInsets.only(bottom: groupGap),
              constraints: BoxConstraints(maxWidth: maxW),
              child: unlocked != null
                  ? GestureDetector(
                      onTap: () => _openImageViewerBytes(unlocked, message: data),
                      child: ClipRRect(
                        borderRadius: groupRadius(18),
                        child: AspectRatio(
                          aspectRatio: lockedAspect,
                          child: justUnlocked
                              ? _UnlockRevealAnimation(
                                  imageBytes: unlocked,
                                  aspectRatio: lockedAspect,
                                  onComplete: () {
                                    _justUnlockedIds.remove(msgId);
                                  },
                                )
                              : Image.memory(unlocked, fit: BoxFit.cover),
                        ),
                      ),
                    )
                  : _LockedImagePlaceholder(
                      isActive: _unlockTargetId == msgId,
                      onTap: () => _enterUnlockMode(msgId, mediaUrl),
                      aspectRatio: lockedAspect,
                    ),
            ),
          );
        } else if (msgType == 'video') {
          // Video message — encrypted
          final mediaUrl = data['media_url'] as String? ?? '';
          final msgVersion = (data['v'] as int?) ?? 0;
          final decryptedVideo = _decryptedMediaCache[mediaUrl];
          // Trigger decryption if not cached
          if (decryptedVideo == null) _decryptAndCacheMedia(mediaUrl, msgVersion);
          // Generate thumbnail from decrypted bytes
          if (decryptedVideo != null) _generateVideoThumbnailFromBytes(mediaUrl, decryptedVideo);
          final thumb = _videoThumbnails[mediaUrl];
          final hasThumb = thumb != null && thumb.isNotEmpty;
          bubble = Align(
            alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
            child: GestureDetector(
              onTap: () {
                final vBytes = _decryptedMediaCache[mediaUrl];
                if (vBytes != null) _openVideoViewerBytes(vBytes, message: data);
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOutCubic,
                margin: EdgeInsets.only(bottom: groupGap),
                constraints: BoxConstraints(
                    maxWidth: MediaQuery.of(context).size.width * 0.40),
                child: ClipRRect(
                  borderRadius: groupRadius(16),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      AspectRatio(
                        aspectRatio: 0.65,
                        child: hasThumb
                            ? Image.memory(thumb, fit: BoxFit.cover,
                                width: double.infinity, height: double.infinity)
                            : Container(
                                color: Colors.white.withValues(alpha: 0.05),
                              ),
                      ),
                      Container(
                        width: 48, height: 48,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.black.withValues(alpha: 0.45),
                        ),
                        child: const Icon(Icons.play_arrow_rounded,
                            size: 28, color: Colors.white),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        } else if (msgType == 'voice') {
          // Voice message — pass e2e for decryption
          final mediaUrl = data['media_url'] as String? ?? '';
          final durationMs = (data['duration_ms'] as int?) ?? 0;
          final msgVersion = (data['v'] as int?) ?? 0;
          final msgSecret = _deriveSharedSecret(msgVersion);
          final voiceE2e = E2EEncryption(msgSecret);
          // Decrypt transcript blob if present
          final transcriptBlob = data['transcript_blob'] as String?;
          String? transcriptStrokes;
          if (transcriptBlob != null && transcriptBlob.isNotEmpty) {
            try { transcriptStrokes = voiceE2e.decrypt(transcriptBlob); } catch (_) {}
          }
          final voiceSessionId = 'session_${widget.convoId}_v$msgVersion';
          bubble = Padding(
            padding: EdgeInsets.only(bottom: groupGap),
            child: isMe
              ? _ScreenGradientBubble(
                  gradientNotifier: _bubbleGradientNotifier,
                  scrollController: _scrollController,
                  builder: (gradColors) => VoiceBubble(
                    audioUrl: mediaUrl,
                    isMe: true,
                    durationMs: durationMs,
                    e2e: voiceE2e,
                    transcriptStrokes: transcriptStrokes,
                    sessionId: voiceSessionId,
                    sharedSecret: msgSecret,
                    borderRadius: groupRadius(22),
                    bubbleGradient: gradColors,
                    foregroundColor: _ScreenGradientBubbleState.textColorFor(gradColors),
                  ),
                )
              : VoiceBubble(
                  audioUrl: mediaUrl,
                  isMe: false,
                  durationMs: durationMs,
                  e2e: voiceE2e,
                  transcriptStrokes: transcriptStrokes,
                  sessionId: voiceSessionId,
                  sharedSecret: msgSecret,
                  borderRadius: groupRadius(22),
                ),
          );
        } else {
          // Text message — decode at paint time only, no plaintext in RAM
          final blob = data['blob'] as String? ?? '';
          final msgVersion = (data['v'] as int?) ?? 0;
          final msgSecret = _deriveSharedSecret(msgVersion);
          final msgE2e = E2EEncryption(msgSecret);
          String strokePayload;
          try { strokePayload = msgE2e.decrypt(blob); } catch (e) { strokePayload = blob; }
          final msgSessionId = 'session_${widget.convoId}_v$msgVersion';
          final radius = groupRadius();
          bubble = Align(
            alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
            child: isMe
              ? _ScreenGradientBubble(
                  gradientNotifier: _bubbleGradientNotifier,
                  scrollController: _scrollController,
                  builder: (gradColors) {
                    final textCol = _ScreenGradientBubbleState.textColorFor(gradColors);
                    return AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeOutCubic,
                    margin: EdgeInsets.only(bottom: groupGap),
                    constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.72),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: gradColors,
                      ),
                      borderRadius: radius,
                    ),
                    child: StrokeText(
                      strokeText: strokePayload,
                      sessionId: msgSessionId,
                      sharedSecret: msgSecret,
                      style: TextStyle(color: textCol, fontSize: 16, height: 1.3, letterSpacing: -0.2),
                    ),
                  );
                  },
                )
              : AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeOutCubic,
                  margin: EdgeInsets.only(bottom: groupGap),
                  constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.72),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                  decoration: BoxDecoration(
                    color: const Color(0xFF2C2C2E),
                    borderRadius: radius,
                  ),
                  child: StrokeText(
                    strokeText: strokePayload,
                    sessionId: msgSessionId,
                    sharedSecret: msgSecret,
                    style: const TextStyle(color: Colors.white, fontSize: 16, height: 1.3, letterSpacing: -0.2),
                  ),
                ),
          );
        }

        // Build reply quote if this message is replying to another
        final replyToId = data['reply_to']?.toString();
        if (replyToId != null) {
          final repliedMsg = _findMessage(replyToId);
          final replyLabel = repliedMsg != null ? _replyPreview(repliedMsg) : 'Message';
          final replyImg = repliedMsg != null ? _replyImageUrl(repliedMsg) : null;
          final replyType = repliedMsg?['type'] as String?;
          final isRepliedText = repliedMsg != null && replyType == null;
          final isRepliedMine = repliedMsg?['sender_id'] == _uid;

          // Build the reply label widget — StrokeText for text, plain Text otherwise
          Widget replyLabelWidget;
          if (isRepliedText) {
            final rBlob = repliedMsg['blob'] as String? ?? '';
            final rV = (repliedMsg['v'] as int?) ?? 0;
            final rSecret = _deriveSharedSecret(rV);
            final rE2e = E2EEncryption(rSecret);
            String rStroke;
            try { rStroke = rE2e.decrypt(rBlob); } catch (_) { rStroke = rBlob; }
            final rSid = 'session_${widget.convoId}_v$rV';
            replyLabelWidget = StrokeText(
              strokeText: rStroke,
              sessionId: rSid,
              sharedSecret: rSecret,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.5),
                fontSize: 16, height: 1.3, letterSpacing: -0.2,
              ),
              maxLines: 1,
            );
          } else {
            replyLabelWidget = Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (replyImg != null && replyType == 'image')
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: Builder(builder: (_) {
                        final b = _recentUploadCache[replyImg] ?? _decryptedMediaCache[replyImg];
                        if (b != null) return Image.memory(b, width: 24, height: 24, fit: BoxFit.cover);
                        return const SizedBox(width: 24, height: 24);
                      }),
                    ),
                  ),
                if (replyImg != null && replyType != 'image')
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: Image.network(
                        replyImg,
                        width: 24, height: 24,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => const SizedBox(width: 24, height: 24),
                      ),
                    ),
                  ),
                if (replyType == 'voice')
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Icon(Icons.mic_rounded,
                        size: 14, color: Colors.white.withValues(alpha: 0.4)),
                  ),
                Flexible(
                  child: Text(
                    replyLabel,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.5),
                      fontSize: 16, height: 1.3, letterSpacing: -0.2,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            );
          }

          bubble = Column(
            crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              GestureDetector(
                onTap: () => _scrollToMessage(replyToId),
                child: _ScreenGradientBubble(
                  gradientNotifier: _bubbleGradientNotifier,
                  scrollController: _scrollController,
                  builder: (gradColors) {
                    final replyFg = isRepliedMine
                        ? _ScreenGradientBubbleState.textColorFor(gradColors)
                        : Colors.white;
                    return Container(
                    margin: const EdgeInsets.only(bottom: 2),
                    constraints: BoxConstraints(
                      maxWidth: MediaQuery.of(context).size.width * 0.72,
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                    decoration: BoxDecoration(
                      gradient: isRepliedMine ? LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: gradColors,
                      ) : null,
                      color: isRepliedMine ? null : const Color(0xFF2C2C2E),
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: DefaultTextStyle.merge(
                      style: TextStyle(color: replyFg.withValues(alpha: 0.5)),
                      child: IconTheme.merge(
                        data: IconThemeData(color: replyFg.withValues(alpha: 0.4)),
                        child: replyLabelWidget,
                      ),
                    ),
                  );
                  },
                ),
              ),
              bubble,
            ],
          );
        }

        // --- Time gap divider (30+ min between messages) ---
        // In reversed list, msgIndex+1 is the older message (visually above)
        Widget? timeDivider;
        if (msgIndex < _messages.length - 1) {
          final curTime = DateTime.tryParse(data['created_at']?.toString() ?? '');
          final olderData = _messages[msgIndex + 1];
          final olderTime = DateTime.tryParse(olderData['created_at']?.toString() ?? '');
          if (curTime != null && olderTime != null) {
            final gap = curTime.difference(olderTime);
            if (gap.inMinutes >= 30) {
              timeDivider = _buildTimestamp(curTime);
            }
          }
        } else {
          // First message ever — always show timestamp
          final curTime = DateTime.tryParse(data['created_at']?.toString() ?? '');
          if (curTime != null) {
            timeDivider = _buildTimestamp(curTime);
          }
        }

        // Wrap with swipe-to-reply and long-press delete
        final msgIdStr = data['id']?.toString() ?? '';
        final isDeleting = _deletingIds.contains(msgIdStr);

        final swipeBubble = _SwipeToReply(
          isMe: isMe,
          onReply: () => _setReply(data),
          onDelete: isMe ? () => _deleteMessage(msgIdStr) : null,
          child: bubble,
        );

        Widget assembled = timeDivider != null
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [timeDivider, swipeBubble],
              )
            : swipeBubble;

        // "Seen" indicator — show under the last message I sent that friend has seen
        if (isMe && _lastSeenByFriendId == msgIdStr) {
          assembled = Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              assembled,
              Padding(
                padding: const EdgeInsets.only(right: 14, top: 1),
                child: Text(
                  'Seen',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.35),
                    fontSize: 10,
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ),
            ],
          );
        }

        // Shrink animation when deleting
        if (isDeleting) {
          assembled = _MessageDeleteAnimation(
            key: ValueKey('del_$msgIdStr'),
            child: assembled,
          );
        }

        // Assign a GlobalKey for sticker anchoring
        final msgKey = _messageKeys.putIfAbsent(msgIdStr, () => GlobalKey());

        // Wrap message with any placed stickers anchored to it.
        // Stack sizes to `assembled` (the non-positioned child) so stickers
        // don't add extra space — they just overflow visually, and the
        // ListView viewport clips them at top/bottom like any other content.
        final msgStickers = _buildStickersForMessage(msgIdStr);
        final withStickers = msgStickers.isEmpty
            ? assembled
            : Stack(
                clipBehavior: Clip.none,
                children: [assembled, ...msgStickers],
              );

        final finalWidget = KeyedSubtree(key: msgKey, child: withStickers);

        if (isNew) {
          return _MessageAppearAnimation(
            key: ValueKey('anim_$msgId'),
            isMe: isMe,
            child: finalWidget,
          );
        }
        return finalWidget;
      },
    );
  }

  @override
  void dispose() {
    _seenPollingActive = false;
    _bubbleGradientNotifier.dispose();
    _svPlayer?.dispose();
    _stickerOverlay?.remove();
    _messagesChannel?.unsubscribe();
    _convoChannel?.unsubscribe();
    _stickersChannel?.unsubscribe();
    _scrollController.dispose();
    _pullResetController.dispose();
    _sendBounceCtrl.dispose();
    _recorder.dispose();
    super.dispose();
  }
}

/// Animates a new message bubble — subtle fade + scale, no slide.
class _MessageAppearAnimation extends StatefulWidget {
  final Widget child;
  final bool isMe;

  const _MessageAppearAnimation({
    super.key,
    required this.child,
    required this.isMe,
  });

  @override
  State<_MessageAppearAnimation> createState() => _MessageAppearAnimationState();
}

class _MessageAppearAnimationState extends State<_MessageAppearAnimation>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    )..forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, child) {
        final t = Curves.easeOut.transform(_ctrl.value);
        return Opacity(
          opacity: t,
          child: Transform.scale(
            scale: 0.92 + 0.08 * t,
            alignment: widget.isMe ? Alignment.bottomRight : Alignment.bottomLeft,
            child: child,
          ),
        );
      },
      child: widget.child,
    );
  }
}

class _ArcProgressPainter extends CustomPainter {
  final double progress;
  final Color color;
  final double strokeWidth;

  _ArcProgressPainter({
    required this.progress,
    required this.color,
    this.strokeWidth = 2.5,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.width - strokeWidth) / 2;

    final bgPaint = Paint()
      ..color = color.withValues(alpha: 0.15)
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(center, radius, bgPaint);

    final arcPaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    final sweepAngle = 2 * math.pi * progress;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      sweepAngle,
      false,
      arcPaint,
    );
  }

  @override
  bool shouldRepaint(_ArcProgressPainter old) =>
      old.progress != progress || old.color != color;
}

/// Glass container that reacts to device tilt — shifts specular highlight
/// based on accelerometer data, mimicking Apple's liquid glass effect.
class _MotionGlass extends StatefulWidget {
  final Widget child;
  final double borderRadius;
  final CustomClipper<Path>? customClipper;

  const _MotionGlass({
    required this.child,
    this.borderRadius = 22,
    this.customClipper,
  });

  @override
  State<_MotionGlass> createState() => _MotionGlassState();
}

class _MotionGlassState extends State<_MotionGlass> {
  final _tilt = TiltProvider.instance;

  @override
  void initState() {
    super.initState();
    _tilt.addUser();
    _tilt.addListener(_onTilt);
    SimpleUiNotifier.instance.addListener(_onSimpleUiChanged);
  }

  void _onTilt() {
    if (mounted && !SimpleUiNotifier.instance.value) setState(() {});
  }

  void _onSimpleUiChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _tilt.removeListener(_onTilt);
    _tilt.removeUser();
    SimpleUiNotifier.instance.removeListener(_onSimpleUiChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.borderRadius;

    if (SimpleUiNotifier.instance.value) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(r),
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFF1C1C1E),
            borderRadius: BorderRadius.circular(r),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.08),
              width: 0.5,
            ),
          ),
          child: widget.child,
        ),
      );
    }

    final clipper = widget.customClipper;
    final clipWidget = clipper != null
        ? ClipPath(clipper: clipper, child: _glassContent(r))
        : ClipRRect(borderRadius: BorderRadius.circular(r), child: _glassContent(r));
    return clipWidget;
  }

  Widget _glassContent(double r) {
    return BackdropFilter(
      filter: ui.ImageFilter.blur(sigmaX: 24, sigmaY: 24),
      child: CustomPaint(
        painter: _GlassHighlightPainter(
          angle: _tilt.angle,
          tiltX: _tilt.tiltX,
          tiltY: _tilt.tiltY,
          borderRadius: r,
          customClipper: widget.customClipper,
        ),
        child: widget.child,
      ),
    );
  }
}

class _GlassHighlightPainter extends CustomPainter {
  final double angle;
  final double tiltX;
  final double tiltY;
  final double borderRadius;
  final CustomClipper<Path>? customClipper;

  _GlassHighlightPainter({
    required this.angle,
    required this.tiltX,
    required this.tiltY,
    required this.borderRadius,
    this.customClipper,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final r = borderRadius;

    // Use custom path or default rrect
    Path? customPath;
    if (customClipper != null) {
      customPath = customClipper!.getClip(size);
    }
    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(r));

    // Base glass fill
    if (customPath != null) {
      canvas.drawPath(customPath, Paint()..color = Colors.white.withValues(alpha: 0.06));
    } else {
      canvas.drawRRect(rrect, Paint()..color = Colors.white.withValues(alpha: 0.06));
    }

    canvas.save();
    if (customPath != null) {
      canvas.clipPath(customPath);
    } else {
      canvas.clipRRect(rrect);
    }

    // Inner specular glow — a soft radial that moves with tilt
    final glowCenter = Offset(
      size.width * (0.5 + tiltX * 0.4),
      size.height * (0.5 - tiltY * 0.5),
    );
    final glowPaint = Paint()
      ..shader = RadialGradient(
        colors: [
          Colors.white.withValues(alpha: 0.10),
          Colors.white.withValues(alpha: 0.03),
          Colors.white.withValues(alpha: 0.0),
        ],
        stops: const [0.0, 0.4, 1.0],
      ).createShader(Rect.fromCircle(center: glowCenter, radius: size.width * 0.5));
    canvas.drawRect(rect, glowPaint);

    canvas.restore();

    // === Border highlight that travels around the edge ===
    final borderPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;

    borderPaint.shader = SweepGradient(
      center: Alignment.center,
      transform: GradientRotation(angle - math.pi * 0.33),
      colors: [
        Colors.white.withValues(alpha: 0.55),
        Colors.white.withValues(alpha: 0.40),
        Colors.white.withValues(alpha: 0.10),
        Colors.white.withValues(alpha: 0.04),
        Colors.white.withValues(alpha: 0.04),
        Colors.white.withValues(alpha: 0.10),
        Colors.white.withValues(alpha: 0.40),
        Colors.white.withValues(alpha: 0.55),
      ],
      stops: const [0.0, 0.08, 0.18, 0.3, 0.7, 0.82, 0.92, 1.0],
    ).createShader(rect);

    if (customPath != null) {
      canvas.drawPath(customPath, borderPaint);
    } else {
      canvas.drawRRect(rrect, borderPaint);
    }

    // Blurred glow behind the bright section
    final blurPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6.0
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4)
      ..shader = SweepGradient(
        center: Alignment.center,
        transform: GradientRotation(angle - math.pi * 0.25),
        colors: [
          Colors.white.withValues(alpha: 0.18),
          Colors.white.withValues(alpha: 0.06),
          Colors.white.withValues(alpha: 0.0),
          Colors.white.withValues(alpha: 0.0),
          Colors.white.withValues(alpha: 0.0),
          Colors.white.withValues(alpha: 0.06),
          Colors.white.withValues(alpha: 0.18),
        ],
        stops: const [0.0, 0.1, 0.22, 0.5, 0.78, 0.9, 1.0],
      ).createShader(rect);

    if (customPath != null) {
      canvas.drawPath(customPath, blurPaint);
    } else {
      canvas.drawRRect(rrect, blurPaint);
    }
  }

  @override
  bool shouldRepaint(_GlassHighlightPainter old) =>
      old.angle != angle || old.tiltX != tiltX || old.tiltY != tiltY;
}




/// Clips the input bar into a stepped pill shape:
/// Left portion is taller (reply + message rows), right portion is shorter (message only).
/// A smooth S-curve (cubic bezier) connects the two heights seamlessly.
class _SteppedPillClipper extends CustomClipper<Path> {
  final double replyFraction;
  final double radius;

  _SteppedPillClipper({required this.replyFraction, required this.radius});

  @override
  Path getClip(Size size) {
    final w = size.width;
    final h = size.height;
    final r = radius;
    final stepX = w * replyFraction;
    final stepY = 23.0.clamp(0.0, h - r * 2); // reply row height

    // Curve width — how much horizontal space the S-curve occupies
    final curveW = math.min(stepY * 1.2, w * 0.18);

    final p = Path();

    // ── Top-left rounded corner ──
    p.moveTo(r, 0);

    // ── Top edge of reply section → start of curve ──
    p.lineTo(stepX - r * 0.3, 0);

    // ── Smooth S-curve from (stepX, 0) down to (stepX + curveW, stepY) ──
    final midX = stepX + curveW * 0.5;
    final midY = stepY * 0.5;

    // First half: starts horizontal (tangent along top edge), curves down
    p.cubicTo(
      stepX + curveW * 0.35, 0,
      midX - curveW * 0.05, midY * 0.6,
      midX, midY,
    );

    // Second half: continues from midpoint, curves to horizontal at stepY
    p.cubicTo(
      midX + curveW * 0.05, midY + (stepY - midY) * 0.4,
      stepX + curveW * 0.65, stepY,
      stepX + curveW + r * 0.3, stepY,
    );

    // ── Top edge of message section → top-right corner ──
    p.lineTo(w - r, stepY);
    p.arcToPoint(Offset(w, stepY + r), radius: Radius.circular(r), clockwise: true);

    // ── Right edge ──
    p.lineTo(w, h - r);
    p.arcToPoint(Offset(w - r, h), radius: Radius.circular(r), clockwise: true);

    // ── Bottom edge ──
    p.lineTo(r, h);
    p.arcToPoint(Offset(0, h - r), radius: Radius.circular(r), clockwise: true);

    // ── Left edge ──
    p.lineTo(0, r);
    p.arcToPoint(Offset(r, 0), radius: Radius.circular(r), clockwise: true);

    p.close();
    return p;
  }

  @override
  bool shouldReclip(_SteppedPillClipper old) =>
      old.replyFraction != replyFraction || old.radius != radius;
}

/// Pulsing red recording dot
class _RecordingDot extends StatefulWidget {
  @override
  State<_RecordingDot> createState() => _RecordingDotState();
}

class _RecordingDotState extends State<_RecordingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        final opacity = 0.5 + 0.5 * _ctrl.value;
        return Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: const Color(0xFFFF453A).withValues(alpha: opacity),
          ),
        );
      },
    );
  }
}

/// Live recording timer that counts up from a start time
class _RecordingTimer extends StatefulWidget {
  final DateTime start;
  const _RecordingTimer({required this.start});

  @override
  State<_RecordingTimer> createState() => _RecordingTimerState();
}

class _RecordingTimerState extends State<_RecordingTimer> {
  late final Stream<int> _ticker;
  int _seconds = 0;

  @override
  void initState() {
    super.initState();
    _ticker = Stream.periodic(const Duration(seconds: 1), (i) => i + 1);
    _ticker.listen((s) {
      if (mounted) setState(() => _seconds = s);
    });
  }

  @override
  Widget build(BuildContext context) {
    final m = _seconds ~/ 60;
    final s = _seconds % 60;
    return Text(
      '$m:${s.toString().padLeft(2, '0')}',
      style: const TextStyle(
        color: Colors.white,
        fontSize: 15,
        fontWeight: FontWeight.w600,
        fontFeatures: [FontFeature.tabularFigures()],
      ),
    );
  }
}

/// Swipe right to reply gesture wrapper
class _SwipeToReply extends StatefulWidget {
  final Widget child;
  final bool isMe;
  final VoidCallback onReply;
  final VoidCallback? onDelete;

  const _SwipeToReply({
    required this.child,
    required this.isMe,
    required this.onReply,
    this.onDelete,
  });

  @override
  State<_SwipeToReply> createState() => _SwipeToReplyState();
}

class _SwipeToReplyState extends State<_SwipeToReply>
    with SingleTickerProviderStateMixin {
  double _dragX = 0;
  bool _triggered = false;
  bool _deleteTriggered = false;
  late final AnimationController _resetCtrl;

  @override
  void initState() {
    super.initState();
    _resetCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
  }

  @override
  void dispose() {
    _resetCtrl.dispose();
    super.dispose();
  }

  void _onDragUpdate(DragUpdateDetails d) {
    final hasDelete = widget.onDelete != null;
    setState(() {
      if (hasDelete) {
        // Own messages: left = reply (negative), right = delete (positive)
        _dragX = (_dragX + d.delta.dx).clamp(-80.0, 80.0);
      } else {
        // Other's messages: right = reply only
        _dragX = (_dragX + d.delta.dx).clamp(0.0, 80.0);
      }
    });
    if (hasDelete) {
      // Own messages: right = delete
      if (_dragX >= 60 && !_deleteTriggered) {
        _deleteTriggered = true;
        HapticFeedback.mediumImpact();
      }
      if (_dragX < 60 && _deleteTriggered) {
        _deleteTriggered = false;
      }
      // Own messages: left = reply
      if (_dragX <= -60 && !_triggered) {
        _triggered = true;
        HapticFeedback.lightImpact();
      }
      if (_dragX > -60 && _triggered) {
        _triggered = false;
      }
    } else {
      // Other's messages: right = reply
      if (_dragX >= 60 && !_triggered) {
        _triggered = true;
        HapticFeedback.lightImpact();
      }
      if (_dragX < 60 && _triggered) {
        _triggered = false;
      }
    }
  }

  void _onDragEnd(DragEndDetails _) {
    if (_deleteTriggered && widget.onDelete != null) {
      widget.onDelete!();
    } else if (_triggered) {
      widget.onReply();
    }
    _triggered = false;
    _deleteTriggered = false;
    final start = _dragX;
    late void Function() listener;
    listener = () {
      if (mounted) {
        setState(() => _dragX = start * (1.0 - _resetCtrl.value));
        if (_resetCtrl.value >= 1.0) {
          _resetCtrl.removeListener(listener);
        }
      }
    };
    _resetCtrl.addListener(listener);
    _resetCtrl.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragUpdate: _onDragUpdate,
      onHorizontalDragEnd: _onDragEnd,
      child: SizedBox(
        width: double.infinity,
        child: Stack(
          children: [
            // Reply icon — right side for own msgs (swipe left), left side for others (swipe right)
            if (widget.onDelete != null && _dragX < -4)
              Positioned(
                right: 0, top: 0, bottom: 0,
                child: Center(
                  child: Opacity(
                    opacity: (-_dragX / 50).clamp(0.0, 1.0),
                    child: Icon(Icons.reply_rounded, size: 20,
                      color: Colors.white.withValues(alpha: 0.4)),
                  ),
                ),
              ),
            if (widget.onDelete == null && _dragX > 4)
              Positioned(
                left: 0, top: 0, bottom: 0,
                child: Center(
                  child: Opacity(
                    opacity: (_dragX / 50).clamp(0.0, 1.0),
                    child: Icon(Icons.reply_rounded, size: 20,
                      color: Colors.white.withValues(alpha: 0.4)),
                  ),
                ),
              ),
            // Delete icon — left side (swipe right on own msgs)
            if (_dragX > 4 && widget.onDelete != null)
              Positioned(
                left: 0, top: 0, bottom: 0,
                child: Center(
                  child: Opacity(
                    opacity: (_dragX / 50).clamp(0.0, 1.0),
                    child: SvgPicture.asset('assets/trash.svg',
                      width: 18, height: 18,
                      colorFilter: ColorFilter.mode(
                        _deleteTriggered
                            ? const Color(0xFFFF453A)
                            : Colors.white.withValues(alpha: 0.4),
                        BlendMode.srcIn)),
                  ),
                ),
              ),
            Transform.translate(
              offset: Offset(_dragX, 0),
              child: widget.child,
            ),
          ],
        ),
      ),
    );
  }
}

class _LockedImagePlaceholder extends StatelessWidget {
  final bool isActive;
  final VoidCallback onTap;
  final double aspectRatio;
  const _LockedImagePlaceholder({
    required this.isActive,
    required this.onTap,
    this.aspectRatio = 1.0,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: AspectRatio(
            aspectRatio: aspectRatio,
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFF2C2C2E),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    isActive ? Icons.lock_open_rounded : Icons.lock_rounded,
                    size: 22,
                    color: Colors.white.withValues(alpha: isActive ? 0.35 : 0.2),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    isActive ? 'Type password below' : 'Tap to unlock',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.25),
                      fontSize: 11,
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


/// Animated X button that pops in on long-press — glass circle like header pills
class _DeleteXButton extends StatefulWidget {
  final VoidCallback onTap;
  const _DeleteXButton({required this.onTap});

  @override
  State<_DeleteXButton> createState() => _DeleteXButtonState();
}

class _DeleteXButtonState extends State<_DeleteXButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _scale = CurvedAnimation(parent: _ctrl, curve: Curves.elasticOut);
    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(
      scale: _scale,
      child: GestureDetector(
        onTap: widget.onTap,
        child: GlassPill(
          width: 34,
          height: 34,
          borderRadius: 17,
          child: Icon(Icons.close_rounded,
              size: 15, color: Colors.white.withValues(alpha: 0.7)),
        ),
      ),
    );
  }
}

/// Shrink + fade animation when a message is being deleted
class _MessageDeleteAnimation extends StatefulWidget {
  final Widget child;
  const _MessageDeleteAnimation({super.key, required this.child});

  @override
  State<_MessageDeleteAnimation> createState() => _MessageDeleteAnimationState();
}

class _MessageDeleteAnimationState extends State<_MessageDeleteAnimation>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _scale;
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _scale = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeInBack),
    );
    _opacity = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeOut),
    );
    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, child) {
        return Opacity(
          opacity: _opacity.value,
          child: Transform.scale(
            scale: _scale.value,
            child: child,
          ),
        );
      },
      child: widget.child,
    );
  }
}

/// Crossfade: grey locked placeholder dissolves, revealing the unlocked image
class _UnlockRevealAnimation extends StatefulWidget {
  final Uint8List imageBytes;
  final double aspectRatio;
  final VoidCallback onComplete;

  const _UnlockRevealAnimation({
    required this.imageBytes,
    required this.aspectRatio,
    required this.onComplete,
  });

  @override
  State<_UnlockRevealAnimation> createState() => _UnlockRevealAnimationState();
}

class _UnlockRevealAnimationState extends State<_UnlockRevealAnimation>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _ctrl.addStatusListener((s) {
      if (s == AnimationStatus.completed) {
        widget.onComplete();
      }
    });
    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, child) {
        return Stack(
          fit: StackFit.expand,
          children: [
            // Revealed image underneath
            Image.memory(widget.imageBytes, fit: BoxFit.cover),
            // Grey placeholder fading out
            Opacity(
              opacity: 1.0 - _ctrl.value,
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF2C2C2E),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.lock_open_rounded,
                        size: 22,
                        color: Colors.white.withValues(alpha: 0.35)),
                    const SizedBox(height: 6),
                    Text('Unlocked',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.25),
                          fontSize: 11,
                        )),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Shows the extracted sticker visual from an .sv file.
/// Tap to replay audio.
class _SvBubble extends StatefulWidget {
  final String svUrl;
  final VoidCallback onTap;
  const _SvBubble({required this.svUrl, required this.onTap});
  @override
  State<_SvBubble> createState() => _SvBubbleState();
}

class _SvBubbleState extends State<_SvBubble> {
  String? _visualPath;
  bool _isVideo = false;
  bool _loading = true;
  VideoPlayerController? _ctrl;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final data = await SvCache.instance.get(widget.svUrl);
    if (mounted && data != null) {
      if (data.isVideo) {
        final ctrl = VideoPlayerController.file(File(data.visualPath));
        await ctrl.initialize();
        await ctrl.setLooping(true);
        await ctrl.setVolume(0);
        await ctrl.play();
        if (mounted) {
          setState(() {
            _ctrl = ctrl;
            _visualPath = data.visualPath;
            _isVideo = true;
            _loading = false;
          });
        } else {
          ctrl.dispose();
        }
      } else {
        setState(() {
          _visualPath = data.visualPath;
          _loading = false;
        });
      }
    } else if (mounted) {
      setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _ctrl?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Container(
        width: 130, height: 130,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(16),
        ),
        child: const Center(
          child: SizedBox(width: 20, height: 20,
            child: CircularProgressIndicator(
                strokeWidth: 1.5, color: Color(0xFF007AFF))),
        ),
      );
    }
    if (_visualPath == null) {
      return GestureDetector(
        onTap: widget.onTap,
        child: Container(
          width: 130, height: 130,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(16),
          ),
          child: const Center(
            child: Icon(Icons.music_video_outlined,
                color: Color(0xFF007AFF), size: 36),
          ),
        ),
      );
    }
    final visual = (_isVideo && _ctrl != null && _ctrl!.value.isInitialized)
        ? FittedBox(
            fit: BoxFit.cover,
            clipBehavior: Clip.hardEdge,
            child: SizedBox(
              width: _ctrl!.value.size.width,
              height: _ctrl!.value.size.height,
              child: VideoPlayer(_ctrl!),
            ),
          )
        : Image.file(File(_visualPath!), fit: BoxFit.cover);
    return GestureDetector(
      onTap: widget.onTap,
      child: SizedBox(
        width: 130, height: 130,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: visual,
        ),
      ),
    );
  }
}

/// A bubble that samples its color from a screen-spanning gradient based on
/// its vertical position — IG-style: the gradient flows across ALL sent
/// messages, not per-bubble.
class _ScreenGradientBubble extends StatefulWidget {
  final ValueNotifier<List<Color>> gradientNotifier;
  final ScrollController scrollController;
  final Widget Function(List<Color> gradientColors) builder;

  const _ScreenGradientBubble({
    required this.gradientNotifier,
    required this.scrollController,
    required this.builder,
  });

  @override
  State<_ScreenGradientBubble> createState() => _ScreenGradientBubbleState();
}

class _ScreenGradientBubbleState extends State<_ScreenGradientBubble> {
  List<Color> _colors = [];
  final _key = GlobalKey();

  @override
  void initState() {
    super.initState();
    _colors = widget.gradientNotifier.value;
    widget.gradientNotifier.addListener(_onGradientChanged);
    widget.scrollController.addListener(_recompute);
    WidgetsBinding.instance.addPostFrameCallback((_) => _recompute());
  }

  @override
  void dispose() {
    widget.gradientNotifier.removeListener(_onGradientChanged);
    widget.scrollController.removeListener(_recompute);
    super.dispose();
  }

  void _onGradientChanged() {
    _recompute();
  }

  void _recompute() {
    final ctx = _key.currentContext;
    if (ctx == null) return;
    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final topLeft = box.localToGlobal(Offset.zero);
    final screenH = MediaQuery.of(ctx).size.height;
    // t = where this bubble sits on screen (0 = top, 1 = bottom)
    final centerY = topLeft.dy + box.size.height / 2;
    final t = (centerY / screenH).clamp(0.0, 1.0);

    final baseColors = widget.gradientNotifier.value;
    if (baseColors.length < 2) return;

    // Top = normal (start of gradient), bottom = darker (end)
    final rt = 1.0 - t;
    final c = _sampleGradient(baseColors, rt);
    final newColors = [c, c];

    if (!_colorsEqual(newColors, _colors)) {
      setState(() => _colors = newColors);
    }
  }

  static Color _sampleGradient(List<Color> colors, double t) {
    if (colors.length == 1) return colors[0];
    final maxIdx = colors.length - 1;
    final scaled = t * maxIdx;
    final lo = scaled.floor().clamp(0, maxIdx - 1);
    final hi = (lo + 1).clamp(0, maxIdx);
    final frac = scaled - lo;
    return Color.lerp(colors[lo], colors[hi], frac)!;
  }

  static bool _colorsEqual(List<Color> a, List<Color> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Returns black for bright bubbles (e.g. yellow), white otherwise.
  static Color textColorFor(List<Color> gradColors) {
    if (gradColors.isEmpty) return Colors.white;
    final c = gradColors.first;
    return c.computeLuminance() > 0.5 ? Colors.black : Colors.white;
  }

  @override
  Widget build(BuildContext context) {
    return KeyedSubtree(
      key: _key,
      child: widget.builder(_colors.isEmpty ? widget.gradientNotifier.value : _colors),
    );
  }
}
