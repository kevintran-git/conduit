/// Thrown by gateway clients when an HTTP call returns a non-2xx status.
///
/// Includes the response body so chat error UI can surface the real reason
/// instead of falling through Conduit's generic "400 image issue" message.
class GatewayHttpException implements Exception {
  GatewayHttpException({
    required this.path,
    required this.statusCode,
    required this.body,
  });

  final String path;
  final int statusCode;
  final String body;

  @override
  String toString() {
    final excerpt = body.length > 800 ? '${body.substring(0, 800)}…' : body;
    return '[GATEWAY $path] HTTP $statusCode: $excerpt';
  }
}

/// Thrown when a gateway request fails before reaching the server (DNS, TLS,
/// timeout). Distinct from [GatewayHttpException] so the UI can tell the user
/// "network unreachable" vs "server rejected".
class GatewayTransportException implements Exception {
  GatewayTransportException({required this.path, required this.cause});

  final String path;
  final Object cause;

  @override
  String toString() => '[GATEWAY $path] transport error: $cause';
}
