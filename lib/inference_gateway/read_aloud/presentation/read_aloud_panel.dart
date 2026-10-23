import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';

import '../../../shared/theme/theme_extensions.dart';
import '../../chat_tts/gateway_text_to_speech_service.dart';
import '../read_aloud_engine.dart';
import '../read_aloud_plan.dart';
import 'read_aloud_overlay.dart';

class ReadAloudPanel extends StatelessWidget {
  const ReadAloudPanel({
    super.key,
    required this.service,
    required this.onCollapse,
  });

  final GatewayTextToSpeechService service;
  final VoidCallback onCollapse;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return Material(
      color: theme.surfaceBackground,
      child: SafeArea(
        child: ValueListenableBuilder<ReadAloudSnapshot?>(
          valueListenable: service.readAloud,
          builder: (context, snapshot, _) {
            if (snapshot == null) return const SizedBox.shrink();
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Spacing.xs),
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: 'Collapse',
                        icon: Icon(
                          Icons.close_fullscreen,
                          color: theme.iconSecondary,
                        ),
                        onPressed: onCollapse,
                      ),
                      Expanded(
                        child: Text(
                          snapshot.stalled
                              ? 'Connection lost'
                              : snapshot.retrying
                              ? 'Reconnecting…'
                              : snapshot.buffering
                              ? 'Buffering…'
                              : 'Read aloud',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(color: theme.textPrimary),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Stop',
                        icon: Icon(Icons.close, color: theme.iconSecondary),
                        onPressed: () => unawaited(service.stop()),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: _ReadAloudText(snapshot: snapshot, service: service),
                ),
                _Scrubber(snapshot: snapshot, service: service),
                _Controls(snapshot: snapshot, service: service),
                const SizedBox(height: Spacing.sm),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _Paragraph {
  _Paragraph(this.parts);

  final List<int> parts;
  final List<int> partStarts = [];
  String text = '';
}

class _ReadAloudText extends StatefulWidget {
  const _ReadAloudText({required this.snapshot, required this.service});

  final ReadAloudSnapshot snapshot;
  final GatewayTextToSpeechService service;

  @override
  State<_ReadAloudText> createState() => _ReadAloudTextState();
}

class _ReadAloudTextState extends State<_ReadAloudText> {
  final ScrollController _scroll = ScrollController();
  ReadAloudPlan? _plan;
  List<_Paragraph> _paragraphs = const [];
  List<GlobalKey> _keys = const [];
  final Map<int, int> _paragraphOfPart = {};
  bool _follow = true;
  int _revealedSegment = -1;

  @override
  void initState() {
    super.initState();
    _layout();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reveal(jump: true));
  }

  @override
  void didUpdateWidget(_ReadAloudText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.snapshot.plan, _plan)) {
      _layout();
      _revealedSegment = -1;
    }
    if (_follow && widget.snapshot.segment != _revealedSegment) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _reveal());
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _layout() {
    final plan = _plan = widget.snapshot.plan;
    final paragraphs = <_Paragraph>[];
    _paragraphOfPart.clear();
    for (var p = 0; p < plan.parts.length; p++) {
      if (paragraphs.isEmpty || plan.paragraphStarts.contains(p)) {
        paragraphs.add(_Paragraph([]));
      }
      final paragraph = paragraphs.last;
      final buffer = StringBuffer(paragraph.text);
      if (buffer.isNotEmpty) buffer.write(' ');
      paragraph.partStarts.add(buffer.length);
      buffer.write(plan.parts[p]);
      paragraph.text = buffer.toString();
      paragraph.parts.add(p);
      _paragraphOfPart[p] = paragraphs.length - 1;
    }
    _paragraphs = paragraphs;
    _keys = [for (final _ in paragraphs) GlobalKey()];
  }

  ({int paragraph, int start, int end})? _segmentRange(int index) {
    final plan = _plan;
    if (plan == null || index < 0 || index >= plan.segments.length) {
      return null;
    }
    final segment = plan.segments[index];
    final p = _paragraphOfPart[segment.partIndex];
    if (p == null) return null;
    final paragraph = _paragraphs[p];
    final base =
        paragraph.partStarts[paragraph.parts.indexOf(segment.partIndex)];
    return (paragraph: p, start: base + segment.start, end: base + segment.end);
  }

  void _reveal({bool jump = false}) {
    if (!mounted || !_scroll.hasClients) return;
    final index = widget.snapshot.segment;
    final range = _segmentRange(index);
    if (range == null) return;
    final render = _keys[range.paragraph].currentContext?.findRenderObject();
    if (render is! RenderParagraph || !render.attached) return;
    final boxes = render.getBoxesForSelection(
      TextSelection(baseOffset: range.start, extentOffset: range.end),
    );
    final rect = boxes.isEmpty
        ? Offset.zero & render.size
        : boxes.first.toRect();
    final viewport = RenderAbstractViewport.maybeOf(render);
    if (viewport == null) return;
    final target = viewport
        .getOffsetToReveal(render, 0.3, rect: rect)
        .offset
        .clamp(0.0, _scroll.position.maxScrollExtent);
    _revealedSegment = index;
    if (jump) {
      _scroll.jumpTo(target);
    } else {
      unawaited(
        _scroll.animateTo(
          target,
          duration: AnimationDuration.medium,
          curve: Curves.easeOut,
        ),
      );
    }
  }

  void _onTap(int paragraphIndex, TapUpDetails details) {
    final render = _keys[paragraphIndex].currentContext?.findRenderObject();
    final plan = _plan;
    if (render is! RenderParagraph || plan == null) return;
    final offset = render.getPositionForOffset(details.localPosition).offset;
    final paragraph = _paragraphs[paragraphIndex];
    var slot = 0;
    for (var i = 0; i < paragraph.partStarts.length; i++) {
      if (paragraph.partStarts[i] <= offset) slot = i;
    }
    final part = paragraph.parts[slot];
    final inPart = offset - paragraph.partStarts[slot];
    final segmentIndex = plan.segmentAtPartOffset(part, inPart);
    final segment = plan.segments[segmentIndex];
    var word = 0;
    for (var w = 0; w < segment.words.length; w++) {
      if (segment.words[w].start <= inPart) word = w;
    }
    setState(() => _follow = true);
    unawaited(widget.service.playSegment(segmentIndex, word: word));
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final base =
        Theme.of(context).textTheme.bodyLarge
            ?.copyWith(color: theme.textPrimary, height: 1.5) ??
        TextStyle(color: theme.textPrimary, height: 1.5);
    final current = base.copyWith(
      backgroundColor: theme.buttonPrimary.withValues(alpha: 0.12),
    );
    final word = base.copyWith(
      backgroundColor: theme.buttonPrimary.withValues(alpha: 0.3),
      fontWeight: FontWeight.w600,
    );
    final failed = base.copyWith(
      decoration: TextDecoration.underline,
      decorationStyle: TextDecorationStyle.wavy,
      decorationColor: theme.error,
    );

    return Stack(
      children: [
        NotificationListener<UserScrollNotification>(
          onNotification: (notification) {
            if (_follow && notification.direction != ScrollDirection.idle) {
              setState(() => _follow = false);
            }
            return false;
          },
          child: SingleChildScrollView(
            controller: _scroll,
            padding: const EdgeInsets.fromLTRB(
              Spacing.lg,
              Spacing.sm,
              Spacing.lg,
              Spacing.xxl,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < _paragraphs.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Spacing.md),
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapUp: (details) => _onTap(i, details),
                      child: RichText(
                        key: _keys[i],
                        textScaler: MediaQuery.textScalerOf(context),
                        text: TextSpan(
                          style: base,
                          children: _spans(i, base, current, word, failed),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (!_follow)
          Positioned(
            right: Spacing.md,
            bottom: Spacing.md,
            child: FloatingActionButton.small(
              heroTag: null,
              tooltip: 'Jump to current',
              backgroundColor: theme.buttonPrimary,
              foregroundColor: theme.buttonPrimaryText,
              onPressed: () {
                setState(() => _follow = true);
                _reveal();
              },
              child: const Icon(Icons.my_location),
            ),
          ),
      ],
    );
  }

  List<InlineSpan> _spans(
    int paragraphIndex,
    TextStyle base,
    TextStyle current,
    TextStyle word,
    TextStyle failed,
  ) {
    final plan = _plan!;
    final snapshot = widget.snapshot;
    final paragraph = _paragraphs[paragraphIndex];
    final text = paragraph.text;
    final spans = <InlineSpan>[];
    var cursor = 0;

    void plain(int end, TextStyle style) {
      if (end <= cursor) return;
      spans.add(TextSpan(text: text.substring(cursor, end), style: style));
      cursor = end;
    }

    for (final segment in plan.segments) {
      if (_paragraphOfPart[segment.partIndex] != paragraphIndex) continue;
      final range = _segmentRange(segment.index)!;
      plain(range.start, base);
      final isCurrent = segment.index == snapshot.segment;
      final isFailed = snapshot.failed.contains(segment.index);
      final style = isFailed ? failed : (isCurrent ? current : base);
      if (isCurrent &&
          snapshot.word >= 0 &&
          snapshot.word < segment.words.length) {
        final w = segment.words[snapshot.word];
        final offset = range.start - segment.start;
        plain(math.max(cursor, offset + w.start), style);
        plain(offset + w.end, word);
      }
      plain(range.end, style);
    }
    plain(text.length, base);
    return spans;
  }
}

class _Scrubber extends StatefulWidget {
  const _Scrubber({required this.snapshot, required this.service});

  final ReadAloudSnapshot snapshot;
  final GatewayTextToSpeechService service;

  @override
  State<_Scrubber> createState() => _ScrubberState();
}

class _ScrubberState extends State<_Scrubber> {
  double? _drag;

  static String _format(Duration value) {
    final minutes = value.inMinutes;
    final seconds = value.inSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final snapshot = widget.snapshot;
    final max = math.max(1, snapshot.duration.inMilliseconds).toDouble();
    final value = (_drag ?? snapshot.position.inMilliseconds.toDouble()).clamp(
      0.0,
      max,
    );
    final caption = Theme.of(context).textTheme.bodySmall
        ?.copyWith(color: theme.textSecondary);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
      child: Column(
        children: [
          Slider(
            value: value,
            max: max,
            activeColor: theme.buttonPrimary,
            onChanged: (next) => setState(() => _drag = next),
            onChangeEnd: (next) {
              setState(() => _drag = null);
              unawaited(
                widget.service.seek(Duration(milliseconds: next.round())),
              );
            },
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _format(Duration(milliseconds: value.round())),
                  style: caption,
                ),
                Text(
                  '${snapshot.durationExact ? '' : '~'}'
                  '${_format(snapshot.duration)}',
                  style: caption,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({required this.snapshot, required this.service});

  final ReadAloudSnapshot snapshot;
  final GatewayTextToSpeechService service;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        IconButton(
          tooltip: 'Back 10 seconds',
          icon: Icon(Icons.replay_10, color: theme.iconPrimary),
          onPressed: () =>
              unawaited(service.skipBy(const Duration(seconds: -10))),
        ),
        IconButton(
          tooltip: 'Previous sentence',
          icon: Icon(Icons.skip_previous_rounded, color: theme.iconPrimary),
          onPressed: () => unawaited(service.skipSegments(-1)),
        ),
        ReadAloudPlayButton(
          snapshot: snapshot,
          service: service,
          size: IconSize.xxl,
        ),
        IconButton(
          tooltip: 'Next sentence',
          icon: Icon(Icons.skip_next_rounded, color: theme.iconPrimary),
          onPressed: () => unawaited(service.skipSegments(1)),
        ),
        IconButton(
          tooltip: 'Forward 10 seconds',
          icon: Icon(Icons.forward_10, color: theme.iconPrimary),
          onPressed: () =>
              unawaited(service.skipBy(const Duration(seconds: 10))),
        ),
      ],
    );
  }
}
