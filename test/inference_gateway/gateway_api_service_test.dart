import 'package:checks/checks.dart';
import 'package:conduit/inference_gateway/api/gateway_api_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('false when nothing is selected', () {
    check(needsNativeOwuiTools()).isFalse();
  });

  test('true when native tool ids are selected', () {
    check(needsNativeOwuiTools(toolIds: ['weather'])).isTrue();
  });

  test('true when filter ids are selected', () {
    check(needsNativeOwuiTools(filterIds: ['profanity'])).isTrue();
  });

  test('true when skill ids are selected', () {
    check(needsNativeOwuiTools(skillIds: ['research'])).isTrue();
  });

  test('true when tool servers are selected', () {
    check(
      needsNativeOwuiTools(
        toolServers: [
          {'url': 'https://tools.example.com'},
        ],
      ),
    ).isTrue();
  });

  test('true when a terminal is selected', () {
    check(needsNativeOwuiTools(terminalId: 'srv-1')).isTrue();
  });

  test('false when terminalId is empty', () {
    check(needsNativeOwuiTools(terminalId: '')).isFalse();
  });

  test('true when web search is enabled', () {
    check(needsNativeOwuiTools(enableWebSearch: true)).isTrue();
  });

  test('true when image generation is enabled', () {
    check(needsNativeOwuiTools(enableImageGeneration: true)).isTrue();
  });

  test('true when code interpreter is enabled', () {
    check(needsNativeOwuiTools(enableCodeInterpreter: true)).isTrue();
  });
}
