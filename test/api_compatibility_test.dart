import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:oasx/api/api_client.dart';
import 'package:oasx/api/sse_client.dart';
import 'package:oasx/service/profile_service.dart';

Map<String, dynamic> statisticsOpenApi() => {
  'paths': {
    '/stats/{script_name}/dates': {'get': <String, dynamic>{}},
    '/stats/{script_name}': {'get': <String, dynamic>{}},
    '/stats/{script_name}/stream': {'get': <String, dynamic>{}},
  },
};

class NoNetwork extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    throw StateError('Offline tests must not create HTTP clients');
  }
}

void main() {
  test(
    'mainline statistics produce an empty date list without missing requests',
    () async {
      final requested = <String>[];
      final api = ApiClient.forTesting(
        statisticsGet: (path) async {
          requested.add(path);
          if (path != '/openapi.json') {
            fail('Runhey must not be sent an unsupported stats request: $path');
          }
          return ApiResult.success({
            'paths': {
              '/script_menu': {'get': <String, dynamic>{}},
              '/{script_name}/{task}/args': {'get': <String, dynamic>{}},
            },
          });
        },
      );

      final first = await api.getScriptStatisticsDates('oas1');
      final second = await api.getScriptStatisticsDates('another-account');
      expect(first.scriptName, 'oas1');
      expect(first.dates, isEmpty);
      expect(second.dates, isEmpty);
      expect(api.statisticsSupported, isFalse);
      expect(requested, ['/openapi.json']);
    },
  );

  test(
    'statistics-capable backend retains its actual dates and endpoint',
    () async {
      final requested = <String>[];
      final api = ApiClient.forTesting(
        statisticsGet: (path) async {
          requested.add(path);
          return ApiResult.success(
            path == '/openapi.json'
                ? statisticsOpenApi()
                : {
                    'script_name': '自定义账号',
                    'dates': ['2026-10-05', '2026-10-04'],
                  },
          );
        },
      );

      final result = await api.getScriptStatisticsDates('自定义账号');
      expect(api.statisticsSupported, isTrue);
      expect(result.dates, ['2026-10-05', '2026-10-04']);
      expect(requested, [
        '/openapi.json',
        '/stats/${Uri.encodeComponent('自定义账号')}/dates',
      ]);
    },
  );

  test('concurrent capability checks share one request', () async {
    final ready = Completer<ApiResult<dynamic>>();
    var calls = 0;
    final api = ApiClient.forTesting(
      statisticsGet: (_) {
        calls++;
        return ready.future;
      },
    );
    final first = api.getScriptStatisticsDates('oas1');
    final second = api.getScriptStatisticsDates('oas2');
    ready.complete(ApiResult.success({'paths': <String, dynamic>{}}));
    await Future.wait([first, second]);
    expect(calls, 1);
  });

  test('transport failures remain errors and permit retry', () async {
    var calls = 0;
    final api = ApiClient.forTesting(
      statisticsGet: (_) async {
        calls++;
        return calls == 1
            ? ApiResult.failure('Connection failed', 503)
            : ApiResult.success({'paths': <String, dynamic>{}});
      },
    );
    await expectLater(api.getScriptStatisticsDates('oas1'), throwsStateError);
    expect(api.statisticsSupported, isNull);
    expect((await api.getScriptStatisticsDates('oas1')).dates, isEmpty);
    expect(calls, 2);
  });

  test('capability state resets when the backend address changes', () async {
    var calls = 0;
    final api = ApiClient.forTesting(
      statisticsGet: (_) async {
        calls++;
        return ApiResult.success({'paths': <String, dynamic>{}});
      },
    );
    await api.getScriptStatisticsDates('oas1');
    api.setAddress('http://localhost:22289');
    if (ProfileService.isPreview) {
      expect(api.address, 'http://127.0.0.1:22391');
    } else {
      expect(api.statisticsSupported, isNull);
      await api.getScriptStatisticsDates('oas1');
      expect(calls, 2);
    }
  });

  test('partial or malformed OpenAPI does not claim statistics support', () {
    expect(statisticsRoutesAvailable({'paths': {}}), isFalse);
    expect(
      statisticsRoutesAvailable({
        'paths': {
          '/stats/{name}/dates': {'get': {}},
        },
      }),
      isFalse,
    );
    expect(
      () => statisticsRoutesAvailable({'data': []}),
      throwsFormatException,
    );
  });

  test(
    'preview cannot select a live host while ordinary addresses normalize',
    () {
      for (final input in [
        'http://127.0.0.1:22288',
        '127.0.0.1:22289',
        'https://example.test',
        '',
      ]) {
        expect(
          ApiClient.resolveAddress(input, preview: true),
          'http://127.0.0.1:22391',
        );
      }
      expect(
        ApiClient.resolveAddress(' 127.0.0.1:22289 ', preview: false),
        'http://127.0.0.1:22289',
      );
      expect(
        ApiClient.resolveAddress('https://example.test', preview: false),
        'https://example.test',
      );
      expect(ApiClient.resolveAddress('', preview: false), isEmpty);
    },
  );

  test(
    'compiled profile guards reset, clear and statistics stream addresses',
    () {
      final api = ApiClient.forTesting(
        statisticsGet: (_) async => ApiResult.success({'paths': {}}),
      );
      api.setAddress('http://127.0.0.1:22288');
      expect(
        api.address,
        ProfileService.isPreview
            ? 'http://127.0.0.1:22391'
            : 'http://127.0.0.1:22288',
      );
      api.clearAddress();
      expect(
        api.address,
        ProfileService.isPreview ? 'http://127.0.0.1:22391' : '',
      );
      api.resetAddress();
      expect(api.address, 'http://${ProfileService.defaultAddress}');
      api.address = 'http://127.0.0.1:22288';
      final uri = api.buildScriptStatisticsSseUri('oas1', '2026-10-05');
      expect(uri.port, ProfileService.isPreview ? 22391 : 22288);
    },
  );

  test(
    'preview SSE rejects live URLs before creating a transport',
    () async {
      final states = <ApiSseConnectionState>[];
      final client = ApiSseClient(
        url: Uri.parse('http://127.0.0.1:22289/stats/oas1/stream'),
        onEvent: (_) => fail('A blocked stream cannot receive events'),
        onStateChanged: (state, _) => states.add(state),
      );
      await HttpOverrides.runWithHttpOverrides(() async {
        await client.connect();
        await client.dispose();
      }, NoNetwork());
      expect(states, [ApiSseConnectionState.error]);
    },
    skip: !ProfileService.isPreview,
  );
}
