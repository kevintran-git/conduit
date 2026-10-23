import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:conduit_core/models/chat_message.dart';

import '../../utils/ask_conduit_context_menu.dart';
import '../horizontal_gesture_ownership.dart';
import 'compiled_markdown_document.dart';
import 'markdown_config.dart';
import 'markdown_compile_service.dart';
import 'markdown_display_part.dart';
import 'markdown_document_controller.dart';
import 'markdown_render_gate.dart';
import 'markdown_loading_skeleton.dart';

import 'package:conduit_core/utils/streaming_markdown_preparation.dart';

import 'renderer/block_renderer.dart';
import 'renderer/chunked_block_column.dart';
import 'renderer/conduit_markdown_widget.dart';

const int _streamingDiagnosticsSampleInterval = 16;

@visibleForTesting
bool debugShouldSampleStreamingMarkdownDiagnostics(
  int revision, {
  bool diagnosticsEnabled = true,
}) =>
    diagnosticsEnabled &&
    (revision == 1 || revision % _streamingDiagnosticsSampleInterval == 0);

@visibleForTesting
Map<String, Object> buildStreamingMarkdownSnapshotForTesting(
  String content, {
  bool streaming = true,
}) {
  return _buildMarkdownSnapshot(content, streaming: streaming).toMap();
}

_MarkdownRenderSnapshot _buildMarkdownSnapshot(
  String content, {
  required bool streaming,
}) {
  return _MarkdownRenderSnapshot.full(
    prepareMarkdownContent(content, streaming: streaming),
  );
}

class _MarkdownRenderSnapshot {
  const _MarkdownRenderSnapshot.empty()
    : preparedContent = const PreparedMarkdownText.empty(),
      patch = null;

  _MarkdownRenderSnapshot.full(String normalizedContent)
    : preparedContent = PreparedMarkdownText.fromString(normalizedContent),
      patch = null;

  const _MarkdownRenderSnapshot.prepared({
    required this.preparedContent,
    required this.patch,
  });

  final PreparedMarkdownText preparedContent;
  final MarkdownPreparationPatch? patch;

  String get normalizedContent => preparedContent.materialize();
  int get length => preparedContent.length;
  bool get isBlank => preparedContent.isBlank;

  Map<String, Object> toMap() => {'normalizedContent': normalizedContent};

  @override
  bool operator ==(Object other) {
    if (other is! _MarkdownRenderSnapshot) return false;
    if (patch != null || other.patch != null) {
      return patch?.sessionId == other.patch?.sessionId &&
          patch?.revision == other.patch?.revision;
    }
    return other.preparedContent == preparedContent;
  }

  @override
  int get hashCode => patch == null
      ? preparedContent.hashCode
      : Object.hash(patch!.sessionId, patch!.revision);
}

class StreamingMarkdownWidget extends ConsumerStatefulWidget {
  const StreamingMarkdownWidget({
    super.key,
    required this.content,
    required this.isStreaming,
    this.onTapLink,
    this.imageBuilderOverride,
    this.sources,
    this.onSourceTap,
    this.askConduitComposerTargetId,
    this.stateScopeId,
    this.enableStreamingTextFade = true,
    this.debugTreatAsWidgetTest,
    this.debugRenderInterval,
    this.debugOnCompiledViewMounted,
    this.debugOnCompiledViewDisposed,
    this.debugOnStreamingRefreshFrame,
    this.debugOnBaseRender,
  });

  final String content;
  final bool isStreaming;
  final MarkdownLinkTapCallback? onTapLink;
  final Widget Function(Uri uri, String? title, String? alt)?
  imageBuilderOverride;

  final List<ChatSourceReference>? sources;

  final void Function(int sourceIndex)? onSourceTap;

  final String? askConduitComposerTargetId;

  final String? stateScopeId;

  final bool enableStreamingTextFade;

  @visibleForTesting
  final bool? debugTreatAsWidgetTest;

  @visibleForTesting
  final Duration? debugRenderInterval;

  @visibleForTesting
  final VoidCallback? debugOnCompiledViewMounted;

  @visibleForTesting
  final VoidCallback? debugOnCompiledViewDisposed;

  @visibleForTesting
  final VoidCallback? debugOnStreamingRefreshFrame;

  @visibleForTesting
  final VoidCallback? debugOnBaseRender;

  @override
  ConsumerState<StreamingMarkdownWidget> createState() =>
      _StreamingMarkdownWidgetState();
}

class _StreamingMarkdownWidgetState
    extends ConsumerState<StreamingMarkdownWidget>
    with WidgetsBindingObserver {
  late final MarkdownCompileService _compileService;
  late final MarkdownDocumentController _documentController;
  final GlobalKey _markdownContentKey = GlobalKey();
  final Map<String, CompiledMarkdownDocument> _displayPartDocumentCache =
      <String, CompiledMarkdownDocument>{};
  CompiledMarkdownDocument? _displayPartsSourceDocument;
  bool _displayPartsWereStreaming = false;
  List<MarkdownDisplayPart>? _displayPartsMemo;
  static int _scopelessInstanceCounter = 0;
  static int _preparationSessionCounter = 0;
  late final String _scopelessFallbackScopeId =
      'sm${_scopelessInstanceCounter++}';
  String? _preparationSessionId;
  int _nextPreparationRevision = 1;
  int _acknowledgedPreparationRevision = 0;
  PreparedMarkdownText _preparedStreamingContent =
      const PreparedMarkdownText.empty();
  _MarkdownRenderSnapshot _snapshot = const _MarkdownRenderSnapshot.empty();
  Timer? _debugStreamingDelayTimer;
  bool _snapshotInFlight = false;
  bool _settledSnapshotInFlight = false;
  bool _settledPreparationPending = false;
  ({String content, int generation, bool clearStaleDocument})?
  _pendingSettledSnapshot;
  bool _streamingRefreshFrameScheduled = false;
  String? _pendingStreamingContent;
  String? _selectedText;
  int _snapshotGeneration = 0;
  bool _isAppForeground = true;
  bool _isRouteVisible = true;
  ImageBuilder? _adaptedImageBuilder;
  final MarkdownRenderGate _renderGate = MarkdownRenderGate();

  CompiledMarkdownDocument? get _compiledDocument =>
      _documentController.compiledDocument;

  String get _compiledPreparedContent =>
      _documentController.compiledPreparedContent;

  bool _compiledMatchesSnapshot(_MarkdownRenderSnapshot snapshot) {
    final patch = snapshot.patch;
    if (patch == null) {
      return _compiledPreparedContent == snapshot.normalizedContent;
    }
    return _documentController.compiledStreamingSessionId == patch.sessionId &&
        _documentController.compiledStreamingRevision == patch.revision;
  }

  bool get _selectionTooLarge =>
      (_displayPartsMemo?.length ?? 0) > markdownChunkedPartInflationThreshold;

  void _handleRenderGateChanged() {
    if (!mounted || _selectionTooLarge) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _renderGate.addListener(_handleRenderGateChanged);
    _isAppForeground = _isLifecycleForeground(
      WidgetsBinding.instance.lifecycleState,
    );
    _compileService = ref.read(markdownCompileServiceProvider);
    _adaptedImageBuilder = _adaptImageBuilder(widget.imageBuilderOverride);
    _documentController = MarkdownDocumentController(
      readCompiler: () => _compileService,
      isWidgetTest: () => _isWidgetTest,
      onStateChanged: _applyCompiledDocumentState,
    );
    final compiler = _compileService;
    if (!widget.isStreaming) {
      _mountSettledContent(compiler);
    } else if (compiler.shouldPrepareSynchronously(
      widget.content,
      widgetTest: _isWidgetTest,
    )) {
      _snapshot = _buildMarkdownSnapshot(widget.content, streaming: true);
      _resolveCompiledDocument(_snapshot);
    } else if (widget.content.trim().isNotEmpty) {
      _initStreamingDeferredMount();
    }
  }

  static const int _settledSynchronousMountCharCap = 20000;

  void _mountSettledContent(MarkdownCompileService compiler) {
    final content = widget.content;
    final memoizedPrepared = compiler.peekSettledPrepared(content);
    if (memoizedPrepared != null) {
      final cachedDocument = compiler.peekPrepared(memoizedPrepared);
      if (cachedDocument != null) {
        _snapshot = _MarkdownRenderSnapshot.full(memoizedPrepared);
        _documentController.applyDirectDocument(cachedDocument);
        return;
      }
    }
    if (_isWidgetTest || content.length <= _settledSynchronousMountCharCap) {
      final prepared =
          memoizedPrepared ?? prepareMarkdownContent(content, streaming: false);
      compiler.memoizeSettledPrepared(content, prepared);
      _snapshot = _MarkdownRenderSnapshot.full(prepared);
      final document =
          compiler.peekPrepared(prepared) ??
          compiler.compilePreparedSynchronously(prepared);
      _documentController.applyDirectDocument(document);
      return;
    }
    _queueSettledSnapshot(content, generation: _snapshotGeneration);
  }

  void _initStreamingDeferredMount() {
    if (widget.content.length > markdownSynchronousPrepareThreshold) {
      _markPendingStreamingContent(widget.content);
      _scheduleStreamingRefresh();
    } else {
      unawaited(_refreshStreamingSnapshot(widget.content));
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateRouteVisibility();
  }

  @override
  void didUpdateWidget(covariant StreamingMarkdownWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    final scopeChanged = widget.stateScopeId != oldWidget.stateScopeId;
    final imageBuilderChanged = !identical(
      widget.imageBuilderOverride,
      oldWidget.imageBuilderOverride,
    );
    if (scopeChanged) {
      _retirePreparationSession();
    }
    if (imageBuilderChanged) {
      _adaptedImageBuilder = _adaptImageBuilder(widget.imageBuilderOverride);
    }
    if (!identical(widget.sources, oldWidget.sources) ||
        widget.onSourceTap != oldWidget.onSourceTap ||
        widget.onTapLink != oldWidget.onTapLink ||
        imageBuilderChanged ||
        scopeChanged) {
      setState(() {});
    }
    if (!scopeChanged &&
        widget.content == oldWidget.content &&
        widget.isStreaming == oldWidget.isStreaming) {
      return;
    }

    if (!widget.isStreaming) {
      _retirePreparationSession();
      _invalidatePendingAsyncSnapshot();
      final compiler = _compileService;
      if (compiler.shouldPrepareSynchronously(
        widget.content,
        widgetTest: _isWidgetTest,
      )) {
        _settledPreparationPending = false;
        _applyPreparedSnapshotIfNeeded(
          prepareMarkdownContent(widget.content, streaming: false),
          clearStaleDocument: scopeChanged,
        );
      } else {
        if (scopeChanged) {
          _documentController.clearDocument();
        }
        final generation = _snapshotGeneration;
        _queueSettledSnapshot(
          widget.content,
          generation: generation,
          clearStaleDocument: scopeChanged,
        );
      }
      return;
    }

    final compiler = _compileService;
    if (_canActivelyRefreshStreamingMarkdown &&
        compiler.shouldPrepareSynchronously(
          widget.content,
          widgetTest: _isWidgetTest,
        )) {
      _retirePreparationSession();
      final preparedContent = prepareMarkdownContent(
        widget.content,
        streaming: true,
      );
      if (_needsPreparedSnapshotUpdate(preparedContent)) {
        widget.debugOnStreamingRefreshFrame?.call();
      }
      _invalidatePendingAsyncSnapshot();
      _applyPreparedSnapshotIfNeeded(
        preparedContent,
        clearStaleDocument: scopeChanged,
      );
      return;
    }

    _pendingSettledSnapshot = null;
    _settledPreparationPending = false;
    if (scopeChanged) {
      _documentController.clearDocument();
    }
    _markPendingStreamingContent(widget.content);
    _scheduleStreamingRefresh();
  }

  bool get _isWidgetTest =>
      widget.debugTreatAsWidgetTest ??
      WidgetsBinding.instance.runtimeType.toString().contains('Test');

  String _ensurePreparationSession() {
    final existing = _preparationSessionId;
    if (existing != null) return existing;
    final scope = widget.stateScopeId ?? _scopelessFallbackScopeId;
    final sessionId = 'markdown-${_preparationSessionCounter++}:$scope';
    _preparationSessionId = sessionId;
    _nextPreparationRevision = 1;
    _acknowledgedPreparationRevision = 0;
    _preparedStreamingContent = const PreparedMarkdownText.empty();
    return sessionId;
  }

  void _retirePreparationSession() {
    final sessionId = _preparationSessionId;
    _preparationSessionId = null;
    _nextPreparationRevision = 1;
    _acknowledgedPreparationRevision = 0;
    _preparedStreamingContent = const PreparedMarkdownText.empty();
    if (sessionId == null) return;
    unawaited(_compileService.releaseStreamingPreparationSession(sessionId));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _renderGate
      ..removeListener(_handleRenderGateChanged)
      ..dispose();
    _debugStreamingDelayTimer?.cancel();
    _retirePreparationSession();
    _documentController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final nextIsForeground = _isLifecycleForeground(state);
    if (_isAppForeground == nextIsForeground) {
      return;
    }
    _isAppForeground = nextIsForeground;
    if (!nextIsForeground) {
      _compileService.retireIdleWorkers();
    }
    _handleStreamingRefreshVisibilityChanged();
  }

  @override
  void didHaveMemoryPressure() {
    _displayPartDocumentCache.clear();
    _displayPartsSourceDocument = null;
    _displayPartsMemo = null;
    _compileService.handleMemoryPressure();
  }

  void _scheduleStreamingRefresh() {
    if (!widget.isStreaming || !_canActivelyRefreshStreamingMarkdown) {
      _debugStreamingDelayTimer?.cancel();
      _debugStreamingDelayTimer = null;
      return;
    }
    if (_streamingRefreshFrameScheduled || _debugStreamingDelayTimer != null) {
      return;
    }
    final interval = _isWidgetTest ? Duration.zero : widget.debugRenderInterval;
    if (interval != null && interval > Duration.zero) {
      _debugStreamingDelayTimer = Timer(
        interval,
        _scheduleStreamingRefreshFrame,
      );
      return;
    }
    _scheduleStreamingRefreshFrame();
  }

  void _invalidatePendingAsyncSnapshot() {
    _debugStreamingDelayTimer?.cancel();
    _debugStreamingDelayTimer = null;
    _pendingStreamingContent = null;
    _pendingSettledSnapshot = null;
    _settledPreparationPending = false;
    _snapshotGeneration += 1;
    _documentController.invalidatePending();
  }

  void _markPendingStreamingContent(String content) {
    if (_pendingStreamingContent == content) {
      return;
    }
    _pendingStreamingContent = content;
    _snapshotGeneration += 1;
  }

  void _scheduleStreamingRefreshFrame() {
    _debugStreamingDelayTimer?.cancel();
    _debugStreamingDelayTimer = null;
    if (!widget.isStreaming ||
        !_canActivelyRefreshStreamingMarkdown ||
        _streamingRefreshFrameScheduled ||
        _snapshotInFlight) {
      return;
    }
    _streamingRefreshFrameScheduled = true;
    WidgetsBinding.instance.scheduleFrameCallback((_) {
      _streamingRefreshFrameScheduled = false;
      if (!mounted ||
          !widget.isStreaming ||
          !_canActivelyRefreshStreamingMarkdown) {
        return;
      }
      final pendingContent = _pendingStreamingContent;
      if (pendingContent == null) {
        return;
      }
      if (_snapshotInFlight) {
        return;
      }
      widget.debugOnStreamingRefreshFrame?.call();
      _pendingStreamingContent = null;
      unawaited(_refreshStreamingSnapshot(pendingContent));
    });
  }

  Future<void> _refreshStreamingSnapshot(String content) async {
    if (_snapshotInFlight) {
      _markPendingStreamingContent(content);
      return;
    }

    _snapshotInFlight = true;
    final generation = _snapshotGeneration;
    try {
      final compiler = _compileService;
      if (compiler.shouldPrepareSynchronously(
        content,
        widgetTest: _isWidgetTest,
      )) {
        final synchronousPrepared = prepareMarkdownContent(
          content,
          streaming: true,
        );
        _applyPreparedSnapshotIfNeeded(synchronousPrepared);
        return;
      }
      final sessionId = _ensurePreparationSession();
      final revision = _nextPreparationRevision++;
      final collectDiagnostics =
          !kReleaseMode &&
          debugShouldSampleStreamingMarkdownDiagnostics(revision);
      final patch = await compiler.prepareStreamingContent(
        MarkdownPreparationRequest(
          sessionId: sessionId,
          revision: revision,
          expectedBaseRevision: _acknowledgedPreparationRevision,
          content: content,
          streaming: true,
          collectMetrics: collectDiagnostics,
          verifyParity: kDebugMode && collectDiagnostics,
        ),
      );
      if (_preparationSessionId != sessionId || patch.isStale) {
        return;
      }
      if (patch.isIncremental &&
          patch.baseRevision != _acknowledgedPreparationRevision) {
        _retirePreparationSession();
        if (mounted && generation == _snapshotGeneration) {
          _applyPreparedSnapshotIfNeeded(
            prepareMarkdownContent(content, streaming: true),
          );
        }
        return;
      }

      final previousPreparedContent = _preparedStreamingContent;
      final preparedContent = previousPreparedContent.applyPatch(patch);
      _preparedStreamingContent = preparedContent;
      _acknowledgedPreparationRevision = patch.revision;
      final preparedChanged =
          patch.preparedRetainLength != previousPreparedContent.length ||
          patch.replacementTail.isNotEmpty;
      final visibleAlreadyMatches =
          !preparedChanged && _snapshot.preparedContent == preparedContent;
      if ((!preparedChanged && visibleAlreadyMatches) ||
          !mounted ||
          generation != _snapshotGeneration) {
        return;
      }
      _applyPreparedPatchIfNeeded(preparedContent, patch);
    } catch (_) {
      if (!mounted || generation != _snapshotGeneration) {
        return;
      }
      _retirePreparationSession();
      _applyPreparedSnapshotIfNeeded(
        prepareMarkdownContent(content, streaming: true),
      );
    } finally {
      _snapshotInFlight = false;
      if (_pendingStreamingContent != null &&
          (generation != _snapshotGeneration ||
              _pendingStreamingContent != content) &&
          mounted) {
        _scheduleStreamingRefresh();
      }
    }
  }

  Future<void> _refreshSettledSnapshot(
    String content, {
    required int generation,
    bool clearStaleDocument = false,
  }) async {
    String preparedContent;
    try {
      preparedContent = await ref
          .read(markdownCompileServiceProvider)
          .prepareContent(content, streaming: false);
    } catch (_) {
      preparedContent = prepareMarkdownContent(content, streaming: false);
    }
    if (!mounted ||
        generation != _snapshotGeneration ||
        widget.isStreaming ||
        widget.content != content) {
      if (mounted && _pendingSettledSnapshot == null) {
        _settledPreparationPending = false;
      }
      return;
    }

    final needsUpdate = _needsPreparedSnapshotUpdate(preparedContent);
    _settledPreparationPending = false;
    if (needsUpdate) {
      _applyPreparedSnapshotIfNeeded(
        preparedContent,
        clearStaleDocument: clearStaleDocument,
      );
    } else {
      setState(() {});
    }
  }

  void _queueSettledSnapshot(
    String content, {
    required int generation,
    bool clearStaleDocument = false,
  }) {
    final previous = _pendingSettledSnapshot;
    _pendingSettledSnapshot = (
      content: content,
      generation: generation,
      clearStaleDocument:
          clearStaleDocument || (previous?.clearStaleDocument ?? false),
    );
    _settledPreparationPending = true;
    if (!_settledSnapshotInFlight) {
      unawaited(_drainSettledSnapshots());
    }
  }

  Future<void> _drainSettledSnapshots() async {
    if (_settledSnapshotInFlight) return;
    _settledSnapshotInFlight = true;
    try {
      while (mounted) {
        final pending = _pendingSettledSnapshot;
        if (pending == null) break;
        _pendingSettledSnapshot = null;
        await _refreshSettledSnapshot(
          pending.content,
          generation: pending.generation,
          clearStaleDocument: pending.clearStaleDocument,
        );
      }
    } finally {
      _settledSnapshotInFlight = false;
      if (mounted && _pendingSettledSnapshot != null) {
        unawaited(_drainSettledSnapshots());
      }
    }
  }

  void _applySnapshot(
    _MarkdownRenderSnapshot nextSnapshot, {
    bool clearStaleDocument = false,
  }) {
    final changed = _snapshot != nextSnapshot;
    if (!changed) {
      if (_compiledDocument == null ||
          !_compiledMatchesSnapshot(nextSnapshot)) {
        _resolveCompiledDocument(
          nextSnapshot,
          clearStaleDocument: clearStaleDocument,
        );
      }
      return;
    }
    if (!mounted) {
      _snapshot = nextSnapshot;
      _resolveCompiledDocument(
        nextSnapshot,
        clearStaleDocument: clearStaleDocument,
      );
      return;
    }
    setState(() => _snapshot = nextSnapshot);
    _resolveCompiledDocument(
      nextSnapshot,
      clearStaleDocument: clearStaleDocument,
    );
  }

  ImageBuilder? _adaptImageBuilder(
    Widget Function(Uri uri, String? title, String? alt)? override,
  ) {
    if (override == null) return null;
    return (String src, String? alt, String? title) {
      final uri = Uri.tryParse(src);
      if (uri == null) return const SizedBox.shrink();
      return override(uri, title, alt);
    };
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    if (snapshot.isBlank) {
      if (_settledPreparationPending && widget.content.trim().isNotEmpty) {
        return MarkdownLoadingSkeleton(contentLength: widget.content.length);
      }
      return const SizedBox.shrink();
    }

    final compiledDocument = _compiledDocument;
    final hasFreshCompiledDocument =
        compiledDocument != null && _compiledMatchesSnapshot(snapshot);
    if (_shouldShowLoadingSkeleton(
      snapshot: snapshot,
      compiledDocument: compiledDocument,
      hasFreshCompiledDocument: hasFreshCompiledDocument,
    )) {
      return MarkdownLoadingSkeleton(contentLength: snapshot.length);
    }
    if (compiledDocument == null) {
      return const SizedBox.shrink();
    }

    final result = KeyedSubtree(
      key: _markdownContentKey,
      child: MarkdownRenderGateScope(
        gate: _renderGate,
        child: _buildMarkdownDisplayParts(compiledDocument),
      ),
    );

    if (widget.isStreaming ||
        _settledPreparationPending ||
        !hasFreshCompiledDocument ||
        !_renderGate.isComplete ||
        _selectionTooLarge) {
      return result;
    }

    return HorizontalGestureExclusion(
      child: SelectionArea(
        contextMenuBuilder: (context, selectableRegionState) {
          return buildAskConduitSelectionAreaContextMenu(
            selectableRegionState: selectableRegionState,
            ref: ref,
            selectedText: _selectedText,
            composerTargetId: widget.askConduitComposerTargetId,
          );
        },
        onSelectionChanged: (content) {
          _selectedText = content?.plainText;
        },
        child: PrioritizedHorizontalGesture(child: result),
      ),
    );
  }

  Widget _buildMarkdownDisplayParts(CompiledMarkdownDocument document) {
    var stableParts = _displayPartsMemo;
    if (stableParts == null ||
        !identical(document, _displayPartsSourceDocument) ||
        widget.isStreaming != _displayPartsWereStreaming) {
      final parts = buildMarkdownDisplayParts(
        document,
        isStreaming: widget.isStreaming,
      );
      stableParts = parts.isEmpty
          ? const <MarkdownDisplayPart>[]
          : _reuseStableDisplayPartDocuments(parts);
      _displayPartsSourceDocument = document;
      _displayPartsWereStreaming = widget.isStreaming;
      _displayPartsMemo = stableParts;
    }
    if (stableParts.isEmpty) {
      _displayPartDocumentCache.clear();
      return _buildMarkdownWithCitations(
        document: document,
        stateScopeId: widget.stateScopeId,
        enableStreamingTextFade:
            widget.isStreaming && widget.enableStreamingTextFade,
        trimLastBlockBottomPadding: true,
      );
    }

    final partWidgets = <Widget>[
      for (var index = 0; index < stableParts.length; index += 1)
        KeyedSubtree(
          key: ValueKey<String>(
            'markdown-display-part:${stableParts[index].partId}',
          ),
          child: _buildMarkdownWithCitations(
            document: stableParts[index].document,
            stateScopeId: _stateScopeIdForPart(stableParts[index]),
            enableStreamingTextFade:
                widget.isStreaming &&
                widget.enableStreamingTextFade &&
                stableParts[index].isMutableTail,
            trimLastBlockBottomPadding: index == stableParts.length - 1,
          ),
        ),
    ];

    return ChunkedBlockColumn(
      revealImmediately: widget.isStreaming,
      children: partWidgets,
    );
  }

  List<MarkdownDisplayPart> _reuseStableDisplayPartDocuments(
    List<MarkdownDisplayPart> parts,
  ) {
    final activePartIds = <String>{};
    final stableParts = <MarkdownDisplayPart>[];
    for (final part in parts) {
      activePartIds.add(part.partId);
      final previousDocument = _displayPartDocumentCache[part.partId];
      final stableDocument =
          previousDocument != null && previousDocument == part.document
          ? previousDocument
          : part.document;
      _displayPartDocumentCache[part.partId] = stableDocument;
      stableParts.add(part.copyWith(document: stableDocument));
    }
    _displayPartDocumentCache.removeWhere(
      (partId, _) => !activePartIds.contains(partId),
    );
    return stableParts;
  }

  Widget _buildMarkdownWithCitations({
    required CompiledMarkdownDocument document,
    required String? stateScopeId,
    required bool enableStreamingTextFade,
    required bool trimLastBlockBottomPadding,
  }) {
    return ConduitMarkdownWidget(
      compiledDocument: document,
      onLinkTap: widget.onTapLink,
      imageBuilder: _adaptedImageBuilder,
      sources: widget.sources,
      onSourceTap: widget.onSourceTap,
      stateScopeId: stateScopeId,
      enableStreamingTextFade: enableStreamingTextFade,
      heavyBlockPolicy: widget.isStreaming
          ? MarkdownHeavyBlockPolicy.defer
          : MarkdownHeavyBlockPolicy.eager,
      trimLastBlockBottomPadding: trimLastBlockBottomPadding,
      debugOnCompiledViewMounted: widget.debugOnCompiledViewMounted,
      debugOnCompiledViewDisposed: widget.debugOnCompiledViewDisposed,
      debugOnBaseRender: widget.debugOnBaseRender,
    );
  }

  String? _stateScopeIdForPart(MarkdownDisplayPart part) {
    final scope = widget.stateScopeId;
    if (scope == null || scope.isEmpty) {
      return '$_scopelessFallbackScopeId:${part.partId}';
    }
    return '$scope:${part.partId}';
  }

  void _resolveCompiledDocument(
    _MarkdownRenderSnapshot snapshot, {
    bool clearStaleDocument = false,
  }) {
    if (widget.isStreaming) {
      final patch = snapshot.patch;
      if (patch != null) {
        _documentController.resolveStreamingPreparedPatch(
          snapshot.preparedContent,
          patch,
          clearDocumentWhenAsync: clearStaleDocument,
        );
      } else {
        _documentController.resolveStreamingPrepared(
          snapshot.normalizedContent,
          clearDocumentWhenAsync: clearStaleDocument,
        );
      }
      return;
    }
    _documentController.resolvePrepared(
      snapshot.normalizedContent,
      clearDocumentWhenAsync: clearStaleDocument,
    );
  }

  bool _needsPreparedSnapshotUpdate(String preparedContent) {
    if (preparedContent != _snapshot.normalizedContent) {
      return true;
    }
    return _compiledDocument == null ||
        _compiledPreparedContent != preparedContent;
  }

  void _applyPreparedSnapshotIfNeeded(
    String preparedContent, {
    bool clearStaleDocument = false,
  }) {
    if (!_needsPreparedSnapshotUpdate(preparedContent)) {
      return;
    }
    _applySnapshot(
      _MarkdownRenderSnapshot.full(preparedContent),
      clearStaleDocument: clearStaleDocument,
    );
  }

  void _applyPreparedPatchIfNeeded(
    PreparedMarkdownText preparedContent,
    MarkdownPreparationPatch patch, {
    bool clearStaleDocument = false,
  }) {
    final nextSnapshot = _MarkdownRenderSnapshot.prepared(
      preparedContent: preparedContent,
      patch: patch,
    );
    if (_snapshot == nextSnapshot &&
        _compiledDocument != null &&
        _compiledMatchesSnapshot(nextSnapshot)) {
      return;
    }
    _applySnapshot(nextSnapshot, clearStaleDocument: clearStaleDocument);
  }

  bool get _canActivelyRefreshStreamingMarkdown =>
      _isAppForeground && _isRouteVisible;

  bool _isLifecycleForeground(AppLifecycleState? state) =>
      state == null ||
      state == AppLifecycleState.resumed ||
      state == AppLifecycleState.inactive;

  bool _computeRouteVisibility() {
    return TickerMode.valuesOf(context).enabled &&
        (ModalRoute.isCurrentOf(context) ?? true);
  }

  void _updateRouteVisibility() {
    final nextIsRouteVisible = _computeRouteVisibility();
    if (_isRouteVisible == nextIsRouteVisible) {
      return;
    }
    _isRouteVisible = nextIsRouteVisible;
    _handleStreamingRefreshVisibilityChanged();
  }

  void _handleStreamingRefreshVisibilityChanged() {
    if (!widget.isStreaming) {
      return;
    }
    if (!_canActivelyRefreshStreamingMarkdown) {
      _debugStreamingDelayTimer?.cancel();
      _debugStreamingDelayTimer = null;
      return;
    }
    if (_pendingStreamingContent != null) {
      _scheduleStreamingRefresh();
    }
  }

  bool _shouldShowLoadingSkeleton({
    required _MarkdownRenderSnapshot snapshot,
    required CompiledMarkdownDocument? compiledDocument,
    required bool hasFreshCompiledDocument,
  }) {
    if (widget.isStreaming || snapshot.isBlank) {
      return false;
    }
    if (hasFreshCompiledDocument) {
      return false;
    }
    if (compiledDocument != null) {
      return false;
    }
    return true;
  }

  void _applyCompiledDocumentState(CompiledMarkdownDocument? document) {
    if (!mounted) {
      return;
    }
    setState(() {});
    scheduleEmbeddedPreviewEligibilityRecheck();
  }
}

extension StreamingMarkdownExtension on String {
  Widget toMarkdown({
    required BuildContext context,
    bool isStreaming = false,
    bool enableStreamingTextFade = true,
    MarkdownLinkTapCallback? onTapLink,
    List<ChatSourceReference>? sources,
    void Function(int sourceIndex)? onSourceTap,
    String? askConduitComposerTargetId,
    String? stateScopeId,
  }) {
    return StreamingMarkdownWidget(
      content: this,
      isStreaming: isStreaming,
      enableStreamingTextFade: enableStreamingTextFade,
      onTapLink: onTapLink,
      sources: sources,
      onSourceTap: onSourceTap,
      askConduitComposerTargetId: askConduitComposerTargetId,
      stateScopeId: stateScopeId,
    );
  }
}

class MarkdownWithLoading extends StatelessWidget {
  const MarkdownWithLoading({
    super.key,
    this.content,
    required this.isLoading,
    this.enableStreamingTextFade = true,
  });

  final String? content;
  final bool isLoading;
  final bool enableStreamingTextFade;

  @override
  Widget build(BuildContext context) {
    final value = content ?? '';
    if (isLoading && value.trim().isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    return StreamingMarkdownWidget(
      content: value,
      isStreaming: isLoading,
      enableStreamingTextFade: enableStreamingTextFade,
    );
  }
}
