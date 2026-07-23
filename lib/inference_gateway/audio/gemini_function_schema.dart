import 'package:inference_kit/inference_kit.dart' as ik;

Map<String, dynamic> toGeminiSchema(Map<String, dynamic> jsonSchema) {
  final out = <String, dynamic>{};

  final description = jsonSchema['description'];
  if (description != null) out['description'] = description;

  final enumValues = jsonSchema['enum'];
  if (enumValues != null) out['enum'] = enumValues;

  final required = jsonSchema['required'];
  if (required is List) out['required'] = required;

  final properties = jsonSchema['properties'];
  if (properties is Map) {
    out['properties'] = {
      for (final entry in properties.entries)
        entry.key.toString(): toGeminiSchema(
          Map<String, dynamic>.from(entry.value as Map),
        ),
    };
  }

  final items = jsonSchema['items'];
  if (items is Map) {
    out['items'] = toGeminiSchema(Map<String, dynamic>.from(items));
  }

  final type = jsonSchema['type'];
  out['type'] = type is String && type.isNotEmpty
      ? type.toUpperCase()
      : out.containsKey('properties')
      ? 'OBJECT'
      : out.containsKey('items')
      ? 'ARRAY'
      : 'STRING';

  return out;
}

List<Map<String, dynamic>> toGeminiFunctionDeclarations(
  List<ik.ToolSpec> tools,
) => [
  for (final tool in tools)
    {
      'name': tool.name,
      'description': tool.description,
      'parameters': toGeminiSchema(tool.parameters),
    },
];
