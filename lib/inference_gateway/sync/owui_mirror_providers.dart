import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'owui_mirror_service.dart';

final owuiMirrorServiceProvider = Provider<OwuiMirrorService>((ref) {
  final service = OwuiMirrorService(ref);
  service.wire();
  ref.onDispose(service.dispose);
  return service;
});
