import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../../../shared/theme/theme_extensions.dart';
import '../../chat_tts/gateway_text_to_speech_service.dart';
import '../read_aloud_engine.dart';
import '../read_aloud_plan.dart';
import 'read_aloud_overlay.dart';

const List<double> readAloudSpeeds = [0.75, 1, 1.25, 1.5, 1.75, 2];

String formatReadAloudSpeed(double speed) {
  final text = speed == speed.roundToDouble()
      ? speed.toStringAsFixed(0)
      : speed.toStringAsFixed(2).replaceFirst(RegExp(r'0$'), '');
  return '$text×';
}

enum _Sheet { none, speed, voices }

class ReadAloudPanel extends StatefulWidget {
  const ReadAloudPanel({
    super.key,
    required this.service,
    required this.onCollapse,
  });

  final GatewayTextToSpeechService service;
  final VoidCallback onCollapse;

  @override
  State<ReadAloudPanel> createState() => _ReadAloudPanelState();
}

class _ReadAloudPanelState extends State<ReadAloudPanel> {
  _Sheet _sheet = _Sheet.none;
  ReadAloudSnapshot? _last;

  GatewayTextToSpeechService get service => widget.service;

  void _toggle(_Sheet sheet) =>
      setState(() => _sheet = _sheet == sheet ? _Sheet.none : sheet);

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final onCollapse = widget.onCollapse;
    return Material(
      color: theme.surfaceBackground,
      child: SafeArea(
        child: ValueListenableBuilder<ReadAloudSnapshot?>(
          valueListenable: service.readAloud,
          builder: (context, live, _) {
            final snapshot = live ?? _last;
            _last = snapshot;
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
                if (snapshot.device)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: Spacing.lg),
                    child: Row(
                      children: [
                        Icon(
                          Icons.phone_android,
                          size: IconSize.md,
                          color: theme.iconSecondary,
                        ),
                        const SizedBox(width: Spacing.xs),
                        Expanded(
                          child: Text(
                            'Device voice',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: theme.textSecondary),
                          ),
                        ),
                        TextButton(
                          onPressed: () =>
                              unawaited(service.retryGatewayVoice()),
                          child: const Text('Retry gateway'),
                        ),
                      ],
                    ),
                  ),
                Expanded(
                  child: AnimatedSwitcher(
                    duration: AnimationDuration.fast,
                    child: _sheet == _Sheet.voices && !snapshot.device
                        ? _VoiceList(
                            key: const ValueKey('voices'),
                            service: service,
                            onDone: () => setState(() => _sheet = _Sheet.none),
                          )
                        : _ReadAloudText(snapshot: snapshot, service: service),
                  ),
                ),
                _Scrubber(snapshot: snapshot, service: service),
                _Controls(snapshot: snapshot, service: service),
                if (!snapshot.device) ...[
                  AnimatedSize(
                    duration: AnimationDuration.fast,
                    child: _sheet == _Sheet.speed
                        ? _SpeedChoices(
                            speed: snapshot.speed,
                            onPick: (speed) {
                              setState(() => _sheet = _Sheet.none);
                              unawaited(service.setReadAloudSpeed(speed));
                            },
                          )
                        : const SizedBox(width: double.infinity),
                  ),
                  _Options(
                    snapshot: snapshot,
                    voice: service.readAloudVoice,
                    sheet: _sheet,
                    onSpeed: () => _toggle(_Sheet.speed),
                    onVoice: () => _toggle(_Sheet.voices),
                  ),
                ],
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
  final List<int> segments = [];
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
  List<Widget?> _built = const [];
  List<Object?> _builtSignature = const [];
  TextStyle? _builtStyle;
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
    final buffers = <StringBuffer>[];
    _paragraphOfPart.clear();
    for (var p = 0; p < plan.parts.length; p++) {
      if (paragraphs.isEmpty || plan.paragraphStarts.contains(p)) {
        paragraphs.add(_Paragraph([]));
        buffers.add(StringBuffer());
      }
      final paragraph = paragraphs.last;
      final buffer = buffers.last;
      if (buffer.isNotEmpty) buffer.write(' ');
      paragraph.partStarts.add(buffer.length);
      buffer.write(plan.parts[p]);
      paragraph.parts.add(p);
      _paragraphOfPart[p] = paragraphs.length - 1;
    }
    for (var i = 0; i < paragraphs.length; i++) {
      paragraphs[i].text = buffers[i].toString();
    }
    for (final segment in plan.segments) {
      final p = _paragraphOfPart[segment.partIndex];
      if (p != null) paragraphs[p].segments.add(segment.index);
    }
    _paragraphs = paragraphs;
    _keys = [for (final _ in paragraphs) GlobalKey()];
    _built = List<Widget?>.filled(paragraphs.length, null);
    _builtSignature = List<Object?>.filled(paragraphs.length, null);
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
    final textScaler = MediaQuery.textScalerOf(context);
    if (base != _builtStyle) {
      _builtStyle = base;
      _built = List<Widget?>.filled(_paragraphs.length, null);
    }
    _failedByParagraph = _groupFailed();

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
                  _paragraph(i, textScaler, base, current, word, failed),
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

  Map<int, List<int>> _failedByParagraph = const {};

  Map<int, List<int>> _groupFailed() {
    final plan = _plan;
    final failed = widget.snapshot.failed;
    if (plan == null || failed.isEmpty) return const {};
    final grouped = <int, List<int>>{};
    for (final index in failed) {
      if (index < 0 || index >= plan.segments.length) continue;
      final p = _paragraphOfPart[plan.segments[index].partIndex];
      if (p != null) (grouped[p] ??= []).add(index);
    }
    for (final list in grouped.values) {
      list.sort();
    }
    return grouped;
  }

  Object _signature(int paragraphIndex, TextScaler textScaler) {
    final snapshot = widget.snapshot;
    final plan = _plan!;
    final segment = snapshot.segment;
    final isCurrent =
        segment >= 0 &&
        segment < plan.segments.length &&
        _paragraphOfPart[plan.segments[segment].partIndex] == paragraphIndex;
    final failed = _failedByParagraph[paragraphIndex];
    return (
      isCurrent ? segment : -1,
      isCurrent ? snapshot.word : -1,
      failed?.join(','),
      textScaler,
    );
  }

  Widget _paragraph(
    int i,
    TextScaler textScaler,
    TextStyle base,
    TextStyle current,
    TextStyle word,
    TextStyle failed,
  ) {
    final signature = _signature(i, textScaler);
    final cached = _built[i];
    if (cached != null && _builtSignature[i] == signature) return cached;
    final built = RepaintBoundary(
      child: Padding(
        padding: const EdgeInsets.only(bottom: Spacing.md),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (details) => _onTap(i, details),
          child: RichText(
            key: _keys[i],
            textScaler: textScaler,
            text: TextSpan(
              style: base,
              children: _spans(i, base, current, word, failed),
            ),
          ),
        ),
      ),
    );
    _built[i] = built;
    _builtSignature[i] = signature;
    return built;
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

    final failedHere = _failedByParagraph[paragraphIndex] ?? const <int>[];
    for (final segmentIndex in paragraph.segments) {
      final segment = plan.segments[segmentIndex];
      final range = _segmentRange(segment.index)!;
      plain(range.start, base);
      final isCurrent = segment.index == snapshot.segment;
      final isFailed = failedHere.contains(segment.index);
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
                  _format(
                    Duration(milliseconds: (value / snapshot.speed).round()),
                  ),
                  style: caption,
                ),
                Text(
                  '${snapshot.durationExact ? '' : '~'}'
                  '${_format(snapshot.duration * (1 / snapshot.speed))}',
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
          onPressed: () {
            unawaited(HapticFeedback.selectionClick());
            unawaited(service.skipSegments(-1));
          },
        ),
        ReadAloudPlayButton(
          snapshot: snapshot,
          service: service,
          size: IconSize.xxl,
        ),
        IconButton(
          tooltip: 'Next sentence',
          icon: Icon(Icons.skip_next_rounded, color: theme.iconPrimary),
          onPressed: () {
            unawaited(HapticFeedback.selectionClick());
            unawaited(service.skipSegments(1));
          },
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

class _Options extends StatelessWidget {
  const _Options({
    required this.snapshot,
    required this.voice,
    required this.sheet,
    required this.onSpeed,
    required this.onVoice,
  });

  final ReadAloudSnapshot snapshot;
  final String voice;
  final _Sheet sheet;
  final VoidCallback onSpeed;
  final VoidCallback onVoice;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _OptionChip(
          icon: Icons.speed,
          label: formatReadAloudSpeed(snapshot.speed),
          selected: sheet == _Sheet.speed,
          tooltip: 'Playback speed',
          onTap: onSpeed,
        ),
        const SizedBox(width: Spacing.sm),
        _OptionChip(
          icon: Icons.record_voice_over_outlined,
          label: voice.isEmpty ? 'Default voice' : voice,
          selected: sheet == _Sheet.voices,
          tooltip: 'Voice',
          onTap: onVoice,
        ),
      ],
    );
  }
}

class _OptionChip extends StatelessWidget {
  const _OptionChip({
    required this.icon,
    required this.label,
    required this.selected,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final color = selected ? theme.buttonPrimary : theme.textSecondary;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: selected
            ? theme.buttonPrimary.withValues(alpha: 0.12)
            : theme.cardBackground,
        shape: StadiumBorder(side: BorderSide(color: theme.dividerColor)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Spacing.md,
              vertical: Spacing.xs,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: IconSize.sm, color: color),
                const SizedBox(width: Spacing.xs),
                Text(
                  label,
                  style: Theme.of(context).textTheme.labelLarge
                      ?.copyWith(color: color),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SpeedChoices extends StatelessWidget {
  const _SpeedChoices({required this.speed, required this.onPick});

  final double speed;
  final ValueChanged<double> onPick;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.sm),
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: Spacing.xs,
        children: [
          for (final option in readAloudSpeeds)
            ChoiceChip(
              label: Text(formatReadAloudSpeed(option)),
              selected: (option - speed).abs() < 0.01,
              selectedColor: theme.buttonPrimary.withValues(alpha: 0.2),
              onSelected: (_) => onPick(option),
            ),
        ],
      ),
    );
  }
}

class _VoiceList extends StatefulWidget {
  const _VoiceList({super.key, required this.service, required this.onDone});

  final GatewayTextToSpeechService service;
  final VoidCallback onDone;

  @override
  State<_VoiceList> createState() => _VoiceListState();
}

class _VoiceListState extends State<_VoiceList> {
  late final Future<List<String>> _voices = widget.service.readAloudVoices();

  void _pick(String voice) {
    widget.onDone();
    if (voice == widget.service.readAloudVoice) return;
    unawaited(widget.service.switchReadAloudVoice(voice));
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final current = widget.service.readAloudVoice;
    return FutureBuilder<List<String>>(
      future: _voices,
      builder: (context, result) {
        if (result.connectionState != ConnectionState.done) {
          return Center(
            child: CircularProgressIndicator(color: theme.loadingIndicator),
          );
        }
        final voices = result.data ?? const <String>[];
        final entries = ['', ...voices.where((v) => v != '')];
        return ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: Spacing.sm),
          itemCount: entries.length + (result.hasError ? 1 : 0),
          itemBuilder: (context, index) {
            if (index == entries.length) {
              return ListTile(
                title: Text(
                  'Could not load the gateway voice list.',
                  style: TextStyle(color: theme.textSecondary),
                ),
              );
            }
            final voice = entries[index];
            final selected = voice == current;
            return ListTile(
              title: Text(
                voice.isEmpty ? 'Default voice' : voice,
                style: TextStyle(
                  color: theme.textPrimary,
                  fontWeight: selected ? FontWeight.w600 : null,
                ),
              ),
              trailing: selected
                  ? Icon(Icons.check, color: theme.buttonPrimary)
                  : null,
              onTap: () => _pick(voice),
            );
          },
        );
      },
    );
  }
}
