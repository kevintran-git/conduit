import 'package:dio/dio.dart';
import 'package:inference_kit/inference_kit.dart' as ik;

const _openApiHttpMethods = {
  'get',
  'put',
  'post',
  'delete',
  'options',
  'head',
  'patch',
  'trace',
};

class _OpenApiOperation {
  _OpenApiOperation({
    required this.name,
    required this.description,
    required this.parameters,
    required this.routePath,
    required this.httpMethod,
    required this.pathParamNames,
    required this.queryParamNames,
    required this.hasRequestBody,
  });

  final String name;
  final String description;
  final Map<String, dynamic> parameters;
  final String routePath;
  final String httpMethod;
  final Set<String> pathParamNames;
  final Set<String> queryParamNames;
  final bool hasRequestBody;
}

List<ik.ToolSpec> buildToolSpecsForOpenApiServer({
  required Map<String, dynamic> openapi,
  required Dio dio,
  required String baseUrl,
  required String? token,
}) {
  final trimmedBase =
      baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
  return [
    for (final operation in _extractOperations(openapi))
      ik.ToolSpec(
        name: operation.name,
        description: operation.description,
        parameters: operation.parameters,
        handler: (args) => _executeOperation(
          dio: dio,
          baseUrl: trimmedBase,
          token: token,
          operation: operation,
          args: args,
        ),
      ),
  ];
}

List<_OpenApiOperation> _extractOperations(Map<String, dynamic> openapi) {
  final paths = openapi['paths'];
  if (paths is! Map) return const [];
  final components =
      openapi['components'] is Map ? openapi['components'] as Map : null;

  final operations = <_OpenApiOperation>[];
  for (final pathEntry in paths.entries) {
    final routePath = pathEntry.key.toString();
    final methods = pathEntry.value;
    if (methods is! Map) continue;
    final pathLevelParams =
        methods['parameters'] is List ? methods['parameters'] as List : const [];

    for (final methodEntry in methods.entries) {
      final httpMethod = methodEntry.key.toString().toLowerCase();
      if (!_openApiHttpMethods.contains(httpMethod)) continue;
      final operation = methodEntry.value;
      if (operation is! Map) continue;
      final operationId = operation['operationId'];
      if (operationId is! String || operationId.isEmpty) continue;

      final opParams =
          operation['parameters'] is List ? operation['parameters'] as List : const [];
      final merged = <String, Map<String, dynamic>>{};
      for (final param in [...pathLevelParams, ...opParams]) {
        if (param is Map && param['name'] != null) {
          merged['${param['name']}:${param['in'] ?? ''}'] =
              Map<String, dynamic>.from(param);
        }
      }

      final properties = <String, dynamic>{};
      final required = <String>[];
      final pathParamNames = <String>{};
      final queryParamNames = <String>{};
      for (final param in merged.values) {
        final paramName = param['name']?.toString();
        if (paramName == null) continue;
        final paramIn = param['in']?.toString();
        final schema = _resolveSchema(param['schema'], components);
        var description =
            (schema['description'] ?? param['description'] ?? '').toString();
        final enumValues = schema['enum'];
        if (enumValues is List) {
          description = '$description. Possible values: ${enumValues.join(', ')}';
        }
        properties[paramName] = {
          'type': schema['type'] ?? 'string',
          'description': description,
          if (enumValues is List) 'enum': enumValues,
        };
        if (param['required'] == true) required.add(paramName);
        if (paramIn == 'path') pathParamNames.add(paramName);
        if (paramIn == 'query') queryParamNames.add(paramName);
      }

      var parameters = <String, dynamic>{
        'type': 'object',
        'properties': properties,
        'required': required,
      };

      final requestBody = operation['requestBody'];
      var hasRequestBody = false;
      if (requestBody is Map) {
        final content = requestBody['content'];
        if (content is Map && content['application/json'] is Map) {
          hasRequestBody = true;
          final schema = (content['application/json'] as Map)['schema'];
          final resolved = _resolveSchema(schema, components);
          if (resolved['properties'] is Map) {
            parameters = {
              'type': 'object',
              'properties': {
                ...properties,
                ...Map<String, dynamic>.from(resolved['properties'] as Map),
              },
              'required': {
                ...required,
                ...((resolved['required'] is List)
                    ? (resolved['required'] as List).map((e) => e.toString())
                    : const <String>[]),
              }.toList(),
            };
          } else if (resolved['type'] == 'array') {
            parameters = resolved;
          }
        }
      }

      operations.add(
        _OpenApiOperation(
          name: operationId,
          description:
              (operation['description'] ?? operation['summary'] ?? 'No description available.')
                  .toString(),
          parameters: parameters,
          routePath: routePath,
          httpMethod: httpMethod,
          pathParamNames: pathParamNames,
          queryParamNames: queryParamNames,
          hasRequestBody: hasRequestBody,
        ),
      );
    }
  }
  return operations;
}

Map<String, dynamic> _resolveSchema(
  dynamic schemaRef,
  Map? components, [
  Set<String>? resolvedSchemas,
]) {
  resolvedSchemas ??= <String>{};
  if (schemaRef is! Map) return const {};
  final map = Map<String, dynamic>.from(schemaRef);

  final ref = map[r'$ref'];
  if (ref is String) {
    final schemaName = ref.split('/').last;
    if (resolvedSchemas.contains(schemaName)) return const {};
    resolvedSchemas.add(schemaName);
    final schemas = components?['schemas'];
    final referenced = schemas is Map ? schemas[schemaName] : null;
    return _resolveSchema(referenced, components, resolvedSchemas);
  }

  final type = map['type'];
  if (type is String) {
    final result = <String, dynamic>{'type': type};
    if (map['description'] != null) result['description'] = map['description'];
    if (map['enum'] is List) result['enum'] = map['enum'];
    if (type == 'object') {
      final properties = <String, dynamic>{};
      final props = map['properties'];
      if (props is Map) {
        for (final entry in props.entries) {
          properties[entry.key.toString()] = _resolveSchema(entry.value, components);
        }
      }
      result['properties'] = properties;
      result['required'] =
          map['required'] is List ? List<dynamic>.from(map['required'] as List) : <dynamic>[];
    } else if (type == 'array') {
      result['items'] = _resolveSchema(map['items'], components);
    }
    return result;
  }

  final allOf = map['allOf'];
  if (allOf is List) {
    final merged = <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{},
      'required': <String>[],
    };
    for (final inner in allOf) {
      final resolved = _resolveSchema(inner, components, resolvedSchemas);
      if (resolved['properties'] is Map) {
        (merged['properties'] as Map<String, dynamic>).addAll(
          resolved['properties'] as Map<String, dynamic>,
        );
      }
      if (resolved['required'] is List) {
        (merged['required'] as List<String>).addAll(
          (resolved['required'] as List).map((e) => e.toString()),
        );
      }
    }
    if (map['description'] != null) merged['description'] = map['description'];
    return merged;
  }

  for (final keyword in const ['oneOf', 'anyOf']) {
    final value = map[keyword];
    if (value is List && value.isNotEmpty) {
      final first = _resolveSchema(value.first, components, resolvedSchemas);
      return {
        ...first,
        if (map['description'] != null) 'description': map['description'],
      };
    }
  }
  return const {};
}

Future<Map<String, dynamic>> _executeOperation({
  required Dio dio,
  required String baseUrl,
  required String? token,
  required _OpenApiOperation operation,
  required Map<String, dynamic> args,
}) async {
  var path = operation.routePath;
  for (final name in operation.pathParamNames) {
    if (args.containsKey(name)) {
      path = path.replaceAll('{$name}', Uri.encodeComponent(args[name].toString()));
    }
  }
  final queryParams = <String, dynamic>{
    for (final name in operation.queryParamNames)
      if (args.containsKey(name)) name: args[name],
  };

  try {
    final response = await dio.request<dynamic>(
      '$baseUrl$path',
      queryParameters: queryParams.isEmpty ? null : queryParams,
      data: operation.hasRequestBody ? args : null,
      options: Options(
        method: operation.httpMethod.toUpperCase(),
        headers: {
          'Content-Type': 'application/json',
          if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
        },
        validateStatus: (status) => status != null && status < 600,
      ),
    );
    final status = response.statusCode ?? 0;
    if (status < 200 || status >= 300) {
      return {'error': 'HTTP $status: ${response.data}'};
    }
    final data = response.data;
    return data is Map ? Map<String, dynamic>.from(data) : {'result': data};
  } catch (error) {
    return {'error': '$error'};
  }
}
