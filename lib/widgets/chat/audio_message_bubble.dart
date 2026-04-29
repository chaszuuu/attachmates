// lib/widgets/chat/audio_message_bubble.dart
import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:just_audio/just_audio.dart';

import '../../utils/constants.dart';           // AppColors + kSupportedReactions + tray sizes
import '../../utils/chat_service.dart';        // toggleReaction + reactionCounts
import '../../utils/time_format.dart';         // TimeFormat.exactTime
import 'reaction_picker.dart';                 // ReactionPicker overlay

typedef ReplyCallback = void Function(String messageId, Map<String, dynamic> msg);

/// ===========================================================================
/// SINGLETON AUDIO COORDINATOR — ensures only ONE message plays at a time
/// ===========================================================================
class _AudioPlayCoordinator {
  _AudioPlayCoordinator._internal() {
    // When a track completes, clear active id so UI resets
    _player.playerStateStream.listen((st) {
      if (st.processingState == ProcessingState.completed) {
        _player.seek(Duration.zero);
        _player.pause();
        _setActive(null);
      }
    });
  }

  static final _AudioPlayCoordinator instance = _AudioPlayCoordinator._internal();

  final AudioPlayer _player = AudioPlayer();
  String? _activeId;

  final _activeCtrl = StreamController<String?>.broadcast();
  Stream<String?> get activeStream => _activeCtrl.stream;

  AudioPlayer get player => _player;
  String? get activeId => _activeId;

  void _setActive(String? id) {
    if (_activeId == id) return;
    _activeId = id;
    _activeCtrl.add(_activeId);
  }

  /// Toggle playback for a given message id/url.
  /// - If a different message is active, stop it, load this URL, and play.
  /// - If the same message is active, toggle pause/play.
  Future<void> toggle(String id, String url) async {
    // If tapping the same bubble
    if (_activeId == id) {
      if (_player.playing) {
        await _player.pause();
      } else {
        // If previously completed, restart from 0
        if (_player.playerState.processingState == ProcessingState.completed) {
          await _player.seek(Duration.zero);
        }
        await _player.play();
      }
      return;
    }

    // Switching to a new bubble
    await _player.stop();
    try {
      final dur = await _player.setUrl(url);
      _setActive(id);
      // If stream completed previously, ensure we start fresh
      if (dur == Duration.zero) {
        await _player.seek(Duration.zero);
      }
      await _player.play();
    } catch (_) {
      // On load error, clear active so UI doesn't get stuck
      _setActive(null);
      rethrow;
    }
  }

  /// If the given id is active, pause it.
  Future<void> pauseIfActive(String id) async {
    if (_activeId == id && _player.playing) {
      await _player.pause();
    }
  }

  /// Explicit stop for a bubble (e.g., on dispose) if it's the active one.
  Future<void> stopIfActive(String id) async {
    if (_activeId == id) {
      await _player.stop();
      _setActive(null);
    }
  }
}

/// ---------------------------------------------------------------------------
/// SENT AUDIO BUBBLE (matches your 2nd screenshot)
/// ---------------------------------------------------------------------------
class AudioMessageBubble extends StatefulWidget {
  // identifiers for reactions / reply
  final String chatId;
  final String messageId;
  final String currentUid;

  final Map<String, dynamic> message;
  final bool isMe;

  // Optional IG-style props your screen passes (safe defaults)
  final bool showTime;
  final bool connectPrev;
  final bool connectNext;
  final String? networkStatus;

  // retry & remove callbacks (for upload failures)
  final void Function(Map<String, dynamic> message)? onRetry;
  final void Function(Map<String, dynamic> message)? onRemove;

  // reply hook
  final ReplyCallback? onReply;

  const AudioMessageBubble({
    super.key,
    required this.chatId,
    required this.messageId,
    required this.currentUid,
    required this.message,
    required this.isMe,
    this.showTime = false,
    this.connectPrev = false,
    this.connectNext = false,
    this.networkStatus,
    this.onRetry,
    this.onRemove,
    this.onReply,
  });

  @override
  State<AudioMessageBubble> createState() => _AudioMessageBubbleState();
}

class _AudioMessageBubbleState extends State<AudioMessageBubble>
    with SingleTickerProviderStateMixin {
  final _coord = _AudioPlayCoordinator.instance;

  StreamSubscription<Duration>? _posSub;
  StreamSubscription<PlayerState>? _stateSub;
  StreamSubscription<String?>? _activeSub;
  StreamSubscription<Duration?>? _durSub;

  bool _playing = false;
  double _posSec = 0.0;
  double _totalSec = 0.0;

  String? get _url =>
      (widget.message['media']?['url'] as String?) ??
      (widget.message['audio_url'] as String?); // backend fallback

  // optional duration hints from backend (seconds)
  double? get _hintDuration {
    final n = (widget.message['media']?['duration'] as num?) ??
        (widget.message['duration'] as num?) ??
        (widget.message['duration_sec'] as num?);
    return n?.toDouble();
  }

  // ------- helpers for reply meta (mirrors MessageBubble) -------
  String? get _replyToId {
    final m = widget.message;
    return (m['reply_to_id'] ??
            m['replyToId'] ??
            m['reply_message_id'] ??
            m['replyMessageId']) as String?;
  }

  String? get _replySenderUid {
    final m = widget.message;
    return (m['reply_sender_uid'] ??
        m['replySenderUid'] ??
        m['reply_from_uid']) as String?;
  }

  String? get _replyTextPreview {
    final m = widget.message;
    final t = (m['reply_text'] ??
        m['replyText'] ??
        m['reply_preview'] ??
        m['replyPreview'] ??
        m['reply_body']) as String?;
    if (t == null) return null;
    final s = t.trim();
    return s.isEmpty ? null : s;
  }

  String? get _replyThumb {
    final m = widget.message;
    final s =
        (m['reply_thumb'] ?? m['replyThumb'] ?? m['reply_image'] ?? m['replyImage'])
            as String?;
    if (s == null) return null;
    return s.isEmpty ? null : s;
  }

  String get _replyType {
    final m = widget.message;
    return (m['reply_type'] ??
                m['replyType'] ??
                (m['reply_thumb'] != null ? 'image' : 'text'))
            as String? ??
        'text';
  }

  bool get _replyDeleted {
    final m = widget.message;
    return (m['reply_deleted'] ?? m['replyDeleted'] ?? false) as bool;
  }

  bool get _hasReply => _replyToId != null && _replyToId!.isNotEmpty;

  bool get _iAmActive => _coord.activeId == widget.messageId;

  @override
  void initState() {
    super.initState();

    // Seed total duration from backend hint if available
    final hint = _hintDuration;
    if (hint != null) _totalSec = hint;

    // Listen to coordinator's active id so we know when to animate or reset
    _activeSub = _coord.activeStream.listen((activeId) {
      if (!mounted) return;
      if (activeId != widget.messageId) {
        // Not the active one — ensure UI shows idle state
        setState(() {
          _playing = false;
          _posSec = 0.0;
          // keep _totalSec as-is (may be hint), actual duration comes when active
        });
      }
    });

    // Update position ONLY when this bubble is active
    _posSub = _coord.player.positionStream.listen((pos) {
      if (!mounted) return;
      if (_iAmActive) {
        setState(() => _posSec = pos.inSeconds.toDouble());
      }
    });

    // Update total duration when the shared player reports it (only if active)
    _durSub = _coord.player.durationStream.listen((dur) {
      if (!mounted) return;
      if (_iAmActive && dur != null) {
        setState(() => _totalSec = dur.inSeconds.toDouble());
      }
    });

    // Update playing flag from shared player (only if active)
    _stateSub = _coord.player.playerStateStream.listen((st) {
      if (!mounted) return;
      final ended = st.processingState == ProcessingState.completed;
      if (_iAmActive) {
        setState(() {
          _playing = st.playing && !ended;
          if (ended) _posSec = 0.0;
        });
      } else {
        // If not active, ensure it's shown as paused
        if (_playing) {
          setState(() => _playing = false);
        }
      }
    });
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _stateSub?.cancel();
    _activeSub?.cancel();
    _durSub?.cancel();

    // If this bubble is currently active, stop it so nothing keeps playing
    unawaited(_coord.stopIfActive(widget.messageId));
    super.dispose();
  }

  Future<void> _togglePlay() async {
    final url = _url;
    if (url == null || url.isEmpty) return;
    await _coord.toggle(widget.messageId, url);
  }

  String _fmt(double s) {
    final sec = s.clamp(0, double.infinity).floor();
    final m = (sec ~/ 60).toString().padLeft(1, '0');
    final r = (sec % 60).toString().padLeft(2, '0');
    return '$m:$r';
  }

  @override
  Widget build(BuildContext context) {
    final createdAt = (widget.message['created_at'] as Timestamp?)?.toDate();
    final String status = (widget.message['status'] as String?) ?? 'sent';

    // IG-like context label
    final bool iAmSender = widget.isMe;
    final bool repliedToSelf = _hasReply &&
        _replySenderUid != null &&
        _replySenderUid == widget.currentUid &&
        iAmSender;
    final bool youReplied = _hasReply && iAmSender && !repliedToSelf;

    final Widget? contextLabel = (!youReplied && !repliedToSelf)
        ? null
        : Padding(
            padding: const EdgeInsets.only(bottom: 4, left: 4, right: 4),
            child: Text(
              repliedToSelf ? 'Replied to yourself' : 'You replied',
              style: TextStyle(
                fontSize: 10,
                color: Colors.grey.shade500,
                fontWeight: FontWeight.w600,
              ),
            ),
          );

    // === The visible audio bubble ===
    final maxBubbleW =
        MediaQuery.of(context).size.width * (widget.isMe ? 0.65 : 0.7);

    final Color bubbleBg = widget.isMe
        ? Theme.of(context).colorScheme.primary
        : Colors.grey.shade200;
    final Color fg = widget.isMe ? Colors.white : Colors.black87;

    final borderRadius =
        _bubbleRadius(widget.isMe, widget.connectPrev, widget.connectNext);

    // LEFT: play/pause icon (filled triangle like screenshot)
    final leftPlay = IconButton(
      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
      padding: EdgeInsets.zero,
      icon: Icon(
        _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
        size: 24,
        color: fg,
      ),
      onPressed: (status == 'failed') ? null : _togglePlay,
    );

    // CENTER: lead dots + waveform (animated while playing, only if active)
    final centerWave = _LeadInWaveform(
      isActive: _playing && _iAmActive,
      isMe: widget.isMe,
      barCount: 13,
      height: 24,
    );

    // RIGHT: timer — show elapsed or total if known
    final rightTime = Text(
      _fmt(_totalSec == 0 ? _posSec : _posSec.clamp(0, _totalSec)),
      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: fg),
    );

    // Row layout = [play] ... [waveform] ... [time]
    final contentRow = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        leftPlay,
        const SizedBox(width: 4),
        Expanded(child: centerWave),
        const SizedBox(width: 12),
        rightTime,
      ],
    );

    final baseBubble = Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      constraints: BoxConstraints(maxWidth: maxBubbleW),
      decoration: BoxDecoration(color: bubbleBg, borderRadius: borderRadius),
      child: contentRow,
    );

    // Ripple + gestures
    final rippleWrapped = Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: _togglePlay,
        onDoubleTap: () => ChatService.toggleReaction(
          chatId: widget.chatId,
          messageId: widget.messageId,
          emoji: "❤️",
        ),
        borderRadius: borderRadius,
        splashColor:
            widget.isMe ? Colors.white24 : Colors.black.withOpacity(0.08),
        highlightColor: Colors.transparent,
        child: baseBubble,
      ),
    );

    final reactionWrapped = GestureDetector(
      behavior: HitTestBehavior.translucent,
      onLongPressStart: (d) => _showPickerCentered(context, d.globalPosition),
      child: rippleWrapped,
    );

    // Corner chips hugging the bubble
    final chips = _AudioCornerChips(
      chatId: widget.chatId,
      messageId: widget.messageId,
      isMe: widget.isMe,
    );

    final stackThatMoves = Stack(
      clipBehavior: Clip.none,
      children: [
        reactionWrapped,
        Positioned(
          bottom: -14,
          right: widget.isMe ? 6 : null,
          left: widget.isMe ? null : 6,
          child: chips,
        ),
      ],
    );

    // Swipe-to-reply
    final swipeAll = _AudioSwipeToReply(
      isMe: widget.isMe,
      onConfirm: () => widget.onReply?.call(widget.messageId, widget.message),
      child: stackThatMoves,
    );

    return Align(
      alignment: widget.isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Padding(
        padding: EdgeInsets.only(
          bottom: widget.connectNext ? 4 : 8,
          left: 8,
          right: 8,
        ),
        child: Column(
          crossAxisAlignment:
              widget.isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            if (contextLabel != null) contextLabel,
            if (_hasReply)
              _AudioReplyPreview(
                isMe: widget.isMe,
                type: _replyType,
                text: _replyTextPreview,
                thumb: _replyThumb,
                deleted: _replyDeleted,
              ),
            _AudioReactionSpacer(
              countsStream:
                  ChatService.reactionCounts(widget.chatId, widget.messageId),
              child: swipeAll,
            ),
            _AudioAnimatedTime(
              visible: widget.showTime && createdAt != null,
              child: _AudioTimeBelowBubble(
                chatId: widget.chatId,
                messageId: widget.messageId,
                isMe: widget.isMe,
                text: _timeWithStatus(
                  isMe: widget.isMe,
                  createdAt: createdAt ?? DateTime.now(),
                  networkStatus: widget.networkStatus,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Centered (Instagram-style) reaction tray
  void _showPickerCentered(BuildContext context, Offset tapPos) {
    final overlay = Overlay.of(context);
    if (overlay == null) return;

    late OverlayEntry entry;

    const double trayHeight = 56;
    const double vGap = 10;

    final size = MediaQuery.of(context).size;
    final top = (tapPos.dy - trayHeight - vGap).clamp(8.0, size.height - 140.0);

    entry = OverlayEntry(
      builder: (_) => Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              onTap: () {
                if (entry.mounted) entry.remove();
              },
            ),
          ),
          Positioned(
            top: top.toDouble(),
            left: 0,
            right: 0,
            child: Center(
              child: ReactionPicker(
                emojis: kSupportedReactions,
                emojiSize: kReactionTrayEmojiSize,
                onPick: (emoji) async {
                  await ChatService.toggleReaction(
                    chatId: widget.chatId,
                    messageId: widget.messageId,
                    emoji: emoji,
                  );
                  if (entry.mounted) entry.remove();
                },
              ),
            ),
          ),
        ],
      ),
    );

    overlay.insert(entry);
    Future.delayed(kReactionTrayAutoDismiss, () {
      if (entry.mounted) entry.remove();
    });
  }

  static BorderRadius _bubbleRadius(
      bool isMe, bool connectPrev, bool connectNext) {
    const outer = 18.0;
    const inner = 6.0;
    final topLeft = isMe ? outer : (connectNext ? inner : outer);
    final bottomLeft = isMe ? outer : (connectPrev ? inner : outer);
    final topRight = isMe ? (connectNext ? inner : outer) : outer;
    final bottomRight = isMe ? (connectPrev ? inner : outer) : outer;
    return BorderRadius.only(
      topLeft: Radius.circular(topLeft),
      bottomLeft: Radius.circular(bottomLeft),
      topRight: Radius.circular(topRight),
      bottomRight: Radius.circular(bottomRight),
    );
  }

  static String _timeWithStatus({
    required bool isMe,
    required DateTime createdAt,
    String? networkStatus,
  }) {
    final time = TimeFormat.exactTime(createdAt);
    if (!isMe) return time;
    final s = (networkStatus ?? 'sent');
    final human = (s == 'uploading')
        ? 'Uploading…'
        : (s == 'sent' ? 'Sent' : (s == 'failed' ? 'Failed' : s));
    return '$time · $human';
  }
}

/// ---------------------------------------------------------------------------
/// RECORDING BAR (composer) — matches your 1st screenshot
/// Usage in composer while mic is recording.
/// ---------------------------------------------------------------------------
class RecordingBar extends StatefulWidget {
  final Duration elapsed;
  final VoidCallback onDelete;
  final VoidCallback onSend;
  final bool isMeTheme; // true => primary bg

  const RecordingBar({
    super.key,
    required this.elapsed,
    required this.onDelete,
    required this.onSend,
    this.isMeTheme = true,
  });

  @override
  State<RecordingBar> createState() => _RecordingBarState();
}

class _RecordingBarState extends State<RecordingBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 900))
        ..repeat();

  String _fmt(Duration d) {
    final s = d.inSeconds;
    final m = (s ~/ 60).toString().padLeft(1, '0');
    final r = (s % 60).toString().padLeft(2, '0');
    return '$m:$r';
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Color bg = widget.isMeTheme
        ? Theme.of(context).colorScheme.primary
        : Colors.grey.shade200;
    final bool isDarkBg = widget.isMeTheme;
    final Color fg = isDarkBg ? Colors.white : Colors.black87;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        children: [
          // Left white circle with grey trash icon
          InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: widget.onDelete,
            child: Container(
              width: 36,
              height: 36,
              decoration: const BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.delete_outline, color: Colors.black54),
            ),
          ),
          const SizedBox(width: 10),

          // Animated lead dots + waveform (always active while recording)
          Expanded(
            child: _LeadInWaveform(
              isActive: true,
              isMe: widget.isMeTheme,
              barCount: 18,
              height: 24,
            ),
          ),

          const SizedBox(width: 12),

          // Timer
          Text(
            _fmt(widget.elapsed),
            style: TextStyle(
              color: fg,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),

          const SizedBox(width: 12),

          // Send arrow (white on right, no circle to match screenshot)
          InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: widget.onSend,
            child: SizedBox(
              width: 32,
              height: 32,
              child: Icon(
                Icons.north_east, // up-right arrow to resemble your image
                color: Colors.white,
                size: 22,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// ---------------------------------------------------------------------------
/// Waveform with three "lead" dots + bars (used in both recording & sent)
/// ---------------------------------------------------------------------------
class _LeadInWaveform extends StatefulWidget {
  final bool isActive;     // true when animating
  final bool isMe;         // colors
  final int barCount;      // number of vertical bars (after the 3 dots)
  final double height;     // max bar height

  const _LeadInWaveform({
    required this.isActive,
    required this.isMe,
    this.barCount = 13,
    this.height = 24,
  });

  @override
  State<_LeadInWaveform> createState() => _LeadInWaveformState();
}

class _LeadInWaveformState extends State<_LeadInWaveform>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 900))
        ..repeat();

  @override
  void didUpdateWidget(covariant _LeadInWaveform oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !_ctrl.isAnimating) {
      _ctrl.repeat();
    } else if (!widget.isActive && _ctrl.isAnimating) {
      _ctrl.stop(canceled: false);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Color bar = widget.isMe ? Colors.white : Colors.black87;
    final Color dot = bar.withOpacity(0.85);

    return SizedBox(
      height: widget.height,
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (_, __) {
          final t = _ctrl.value; // 0..1
          // lead dots spacing animation
          final dotOffset = widget.isActive ? (2.0 + 1.0 * math.sin(t * 2 * math.pi)) : 2.0;
          return Row(
            children: [
              // three lead dots
              Padding(
                padding: EdgeInsets.only(right: 6 + dotOffset),
                child: Row(
                  children: [
                    _dot(dot, 4),
                    SizedBox(width: 3 + dotOffset * .5),
                    _dot(dot, 6),
                    SizedBox(width: 3 + dotOffset * .5),
                    _dot(dot, 4),
                  ],
                ),
              ),

              // bars
              Expanded(
                child: LayoutBuilder(
                  builder: (context, c) {
                    final bars = widget.barCount.clamp(7, 25);
                    final spacing = 3.0;
                    final barW = 4.0;
                    return Row(
                      mainAxisAlignment: MainAxisAlignment.start,
                      children: List.generate(bars, (i) {
                        final base = 0.55 + 0.45 * math.sin((i * 0.8) + (t * 2 * math.pi));
                        final h = (widget.isActive
                                ? base
                                : (0.22 + 0.10 * math.sin(i * 0.8)))
                            * widget.height;
                        return Padding(
                          padding: EdgeInsets.only(right: i == bars - 1 ? 0 : spacing),
                          child: Container(
                            width: barW,
                            height: h.clamp(3.0, widget.height),
                            decoration: BoxDecoration(
                              color: bar,
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                        );
                      }),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _dot(Color c, double size) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: c, shape: BoxShape.circle),
      );
}

// ====== Reaction chips / timestamp scaffolding (unchanged) ======

class _AudioCornerChips extends StatelessWidget {
  final String chatId;
  final String messageId;
  final bool isMe;
  const _AudioCornerChips({
    required this.chatId,
    required this.messageId,
    required this.isMe,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Map<String, int>>(
      stream: ChatService.reactionCounts(chatId, messageId),
      builder: (context, snap) {
        final counts = snap.data ?? const {};
        if (counts.isEmpty) return const SizedBox.shrink();

        return Container(
          padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 6),
          decoration: BoxDecoration(
            color: kReactionChipFill,
            borderRadius: BorderRadius.circular(kReactionChipRadius),
            border: Border.all(color: kReactionChipBorder),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.06),
                blurRadius: 6,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Wrap(
            spacing: 4,
            children: counts.entries
                .map((e) => Text(
                      "${e.key} ${e.value}",
                      style: const TextStyle(fontSize: kReactionChipFontSize),
                    ))
                .toList(),
          ),
        );
      },
    );
  }
}

class _AudioAnimatedTime extends StatelessWidget {
  final bool visible;
  final Widget child;
  const _AudioAnimatedTime({required this.visible, required this.child});

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 160),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      transitionBuilder: (child, anim) {
        final slide =
            Tween<Offset>(begin: const Offset(0, .15), end: Offset.zero)
                .animate(anim);
        return FadeTransition(
          opacity: anim,
          child: SlideTransition(position: slide, child: child),
        );
      },
      child: visible
          ? KeyedSubtree(key: const ValueKey('audio-time-visible'), child: child)
          : const KeyedSubtree(
              key: ValueKey('audio-time-hidden'),
              child: SizedBox.shrink(),
            ),
    );
  }
}

class _AudioTimeBelowBubble extends StatelessWidget {
  final String chatId;
  final String messageId;
  final bool isMe;
  final String text;

  const _AudioTimeBelowBubble({
    required this.chatId,
    required this.messageId,
    required this.isMe,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Map<String, int>>(
      stream: ChatService.reactionCounts(chatId, messageId),
      builder: (context, snap) {
        final hasReactions = (snap.data ?? const {}).isNotEmpty;
        return Padding(
          padding: EdgeInsets.only(top: hasReactions ? 8 : 4),
          child: Text(text, style: TextStyle(fontSize: 10, color: Colors.grey.shade600)),
        );
      },
    );
  }
}

class _AudioReactionSpacer extends StatelessWidget {
  final Widget child;
  final Stream<Map<String, int>>? countsStream;
  final double expandedBottom;

  const _AudioReactionSpacer({
    required this.child,
    this.countsStream,
    this.expandedBottom = 10,
  });

  @override
  Widget build(BuildContext context) {
    if (countsStream == null) return child;
    return StreamBuilder<Map<String, int>>(
      stream: countsStream,
      builder: (context, snap) {
        final hasPills = (snap.data ?? const {}).isNotEmpty;
        final pad = hasPills ? expandedBottom : 0.0;
        return AnimatedPadding(
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          padding: EdgeInsets.only(bottom: pad),
          child: child,
        );
      },
    );
  }
}

class _AudioSwipeToReply extends StatefulWidget {
  final Widget child;
  final bool isMe;
  final VoidCallback? onConfirm;
  const _AudioSwipeToReply({
    required this.child,
    required this.isMe,
    this.onConfirm,
  });

  @override
  State<_AudioSwipeToReply> createState() => _AudioSwipeToReplyState();
}

class _AudioSwipeToReplyState extends State<_AudioSwipeToReply>
    with SingleTickerProviderStateMixin {
  static const double _trigger = 56;
  static const double _maxReveal = 72;

  double _dx = 0;
  bool _armed = false;

  @override
  Widget build(BuildContext context) {
    final sign = widget.isMe ? -1.0 : 1.0;

    return Stack(
      alignment: widget.isMe ? Alignment.centerRight : Alignment.centerLeft,
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: Opacity(
            opacity: (_dx.abs() / _trigger).clamp(0, 1),
            child: const Padding(
              padding: EdgeInsets.only(right: 8),
              child: SizedBox(
                width: 36,
                height: 36,
                child: Icon(Icons.reply, size: 30, color: Colors.black54),
              ),
            ),
          ),
        ),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: (_) {
            _dx = 0;
            _armed = false;
          },
          onHorizontalDragUpdate: (d) {
            final delta = d.delta.dx * sign;
            setState(() {
              _dx = (_dx + delta).clamp(0, _maxReveal);
              _armed = _dx >= _trigger;
            });
          },
          onHorizontalDragEnd: (_) {
            if (_armed && widget.onConfirm != null) widget.onConfirm!();
            setState(() {
              _dx = 0;
              _armed = false;
            });
          },
          onHorizontalDragCancel: () {
            setState(() {
              _dx = 0;
              _armed = false;
            });
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            curve: Curves.easeOut,
            transform: Matrix4.translationValues(_dx * sign, 0, 0),
            child: widget.child,
          ),
        ),
      ],
    );
  }
}

class _AudioReplyPreview extends StatelessWidget {
  final bool isMe;
  final String type; // text | image
  final String? text;
  final String? thumb;
  final bool deleted;

  const _AudioReplyPreview({
    required this.isMe,
    required this.type,
    required this.text,
    required this.thumb,
    required this.deleted,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final Color bubbleBg = isDark ? const Color(0xFF2B2B2D) : Colors.white;
    final Color bubbleFg =
        isDark ? Colors.white.withOpacity(.85) : Colors.black87;
    final BoxBorder? bubbleBorder =
        !isDark ? Border.all(color: const Color(0xFFE0E0E0), width: 0.6) : null;

    final Widget connector = Container(
      width: 2,
      height: 28,
      decoration: BoxDecoration(
        color: isDark ? Colors.white12 : Colors.black12,
        borderRadius: BorderRadius.circular(1),
      ),
    );

    final List<Widget> contents = [
      if (thumb != null && thumb!.isNotEmpty) ...[
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.network(thumb!, width: 34, height: 34, fit: BoxFit.cover),
        ),
        const SizedBox(width: 8),
      ] else if (type == 'image') ...[
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: isDark ? Colors.white12 : Colors.black12,
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Icon(Icons.image, size: 18, color: Colors.black38),
        ),
        const SizedBox(width: 8),
      ],
      Flexible(
        child: Text(
          deleted
              ? 'Original message deleted'
              : (text?.isNotEmpty == true
                  ? text!
                  : (type == 'image' ? 'Photo' : 'Message')),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 13,
            color: bubbleFg,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    ];

    final miniBubble = Container(
      constraints: const BoxConstraints(maxWidth: 320),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: bubbleBg,
        borderRadius: BorderRadius.circular(18),
        border: bubbleBorder,
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: contents),
    );

    final children = <Widget>[
      if (!isMe) connector,
      if (!isMe) const SizedBox(width: 6),
      Flexible(child: miniBubble),
      if (isMe) const SizedBox(width: 6),
      if (isMe) connector,
    ];

    return Padding(
      padding: const EdgeInsets.only(bottom: 6, left: 4, right: 4),
      child: Row(
        mainAxisAlignment:
            isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: children,
      ),
    );
  }
}
