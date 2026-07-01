import 'package:inference_kit/inference_kit.dart' as ik;

// Gemini's Schema type enum is uppercase (STRING/OBJECT/ARRAY/...); ToolSpec.parameters is lowercase JSON Schema. [fact]
Map<String, dynamic> toGeminiSchema(Map<String, dynamic> jsonSchema) {
  final out = <String, dynamic>{};

  final type = jsonSchema['type'];
  if (type is String) out['type'] = type.toUpperCase();

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
