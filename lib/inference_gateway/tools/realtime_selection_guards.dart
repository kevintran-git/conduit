import '../../features/chat/providers/chat_providers.dart';
import '../../features/tools/providers/tools_providers.dart';
import '../config/gateway_providers.dart' show realtimeCallActiveProvider;

const String _directServerPrefix = 'direct_server:';
const String _adminToolServerPrefix = 'server:';

bool isRealtimeCallCompatibleToolId(String id) =>
    id.startsWith(_directServerPrefix) || id.startsWith(_adminToolServerPrefix);

class GatewayGuardedToolIds extends SelectedToolIds {
  List<String>? _preCallSelection;

  @override
  List<String> build() {
    ref.listen<bool>(realtimeCallActiveProvider, (previous, active) {
      if (active) {
        _preCallSelection = state;
        state = state.where(isRealtimeCallCompatibleToolId).toList();
      } else if (_preCallSelection != null) {
        state = _preCallSelection!;
        _preCallSelection = null;
      }
    });
    return super.build();
  }

  @override
  void set(List<String> ids) {
    if (!ref.read(realtimeCallActiveProvider)) {
      super.set(ids);
      return;
    }
    super.set(ids.where(isRealtimeCallCompatibleToolId).toList());
  }
}

class GatewayGuardedFilterIds extends SelectedFilterIds {
  List<String>? _preCallSelection;

  @override
  List<String> build() {
    ref.listen<bool>(realtimeCallActiveProvider, (previous, active) {
      if (active) {
        _preCallSelection = state;
        state = const [];
      } else if (_preCallSelection != null) {
        state = _preCallSelection!;
        _preCallSelection = null;
      }
    });
    return super.build();
  }

  @override
  void set(List<String> ids) {
    if (ref.read(realtimeCallActiveProvider)) return;
    super.set(ids);
  }

  @override
  void toggle(String id) {
    if (ref.read(realtimeCallActiveProvider)) return;
    super.toggle(id);
  }

  @override
  void clear() {
    if (ref.read(realtimeCallActiveProvider)) return;
    super.clear();
  }
}

class GatewayGuardedTerminalId extends SelectedTerminalId {
  String? _preCallSelection;
  bool _hadPreCallSelection = false;

  @override
  String? build() {
    ref.listen<bool>(realtimeCallActiveProvider, (previous, active) {
      if (active) {
        _preCallSelection = state;
        _hadPreCallSelection = true;
        state = null;
      } else if (_hadPreCallSelection) {
        state = _preCallSelection;
        _preCallSelection = null;
        _hadPreCallSelection = false;
      }
    });
    return super.build();
  }

  @override
  void set(String? id) {
    if (ref.read(realtimeCallActiveProvider)) return;
    super.set(id);
  }

  @override
  void clear() {
    if (ref.read(realtimeCallActiveProvider)) return;
    super.clear();
  }
}

class GatewayGuardedWebSearchEnabled extends WebSearchEnabledNotifier {
  @override
  bool build() {
    if (ref.watch(realtimeCallActiveProvider)) return false;
    return super.build();
  }

  @override
  void set(bool value) {
    if (ref.read(realtimeCallActiveProvider)) return;
    super.set(value);
  }
}

class GatewayGuardedImageGenerationEnabled
    extends ImageGenerationEnabledNotifier {
  @override
  bool build() {
    if (ref.watch(realtimeCallActiveProvider)) return false;
    return super.build();
  }

  @override
  void set(bool value) {
    if (ref.read(realtimeCallActiveProvider)) return;
    super.set(value);
  }
}
