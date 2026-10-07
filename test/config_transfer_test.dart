import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_nb_net/flutter_net.dart' show FormData;
import 'package:flutter_test/flutter_test.dart';
import 'package:oasx/api/config_transfer_api.dart';
import 'package:oasx/api/config_transfer_models.dart';
import 'package:oasx/service/config_transfer_files.dart';

const capabilities = {
  'version': 1,
  'max_bytes': configTransferMaxBytes,
  'modes': ['backup', 'share'],
  'config_import': true,
  'task_import': true,
};

class _NoNetwork extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      throw StateError('Transfer tests must not reach any backend');
}

void main() {
  setUp(() => HttpOverrides.global = _NoNetwork());
  tearDown(() => HttpOverrides.global = null);

  test(
    'JSON validation bounds file size and hides parser/account contents',
    () {
      expect(
        () => ConfigTransferDocument.parse('a.json', []),
        throwsA(isA<ConfigTransferException>()),
      );
      expect(
        () => ConfigTransferDocument.parse(
          'a.json',
          Uint8List(configTransferMaxBytes + 1),
        ),
        throwsA(isA<ConfigTransferException>()),
      );
      expect(
        () => ConfigTransferDocument.parse('a.txt', utf8.encode('{}')),
        throwsA(isA<ConfigTransferException>()),
      );
      expect(
        () => ConfigTransferDocument.parse('a.json', utf8.encode('[1]')),
        throwsA(isA<ConfigTransferException>()),
      );
      expect(
        () => ConfigTransferDocument.parse('a.json', [255]),
        throwsA(isA<ConfigTransferException>()),
      );
      try {
        ConfigTransferDocument.parse(
          'a.json',
          utf8.encode('{"private":"secret-value"'),
        );
      } catch (e) {
        expect(e.toString(), isNot(contains('secret-value')));
      }
      expect(
        ConfigTransferDocument.parse(
          'a.json',
          utf8.encode('\uFEFF{"task": {}}'),
        ).bytes,
        isNotEmpty,
      );
    },
  );

  test(
    'import names stay in one config directory and cannot replace existing names',
    () {
      for (final name in [
        '../config',
        'x/y',
        r'x\y',
        'Home',
        'template',
        'CON',
        'nul',
        'LPT1',
        '',
        '.',
      ]) {
        expect(validateConfigImportName(name, []), isNotNull, reason: name);
      }
      expect(validateConfigImportName('BACKUP.json', ['backup']), isNotNull);
      expect(validateConfigImportName('演示-新配置1', []), isNull);
      expect(normalizeConfigImportName('new.JSON'), 'new');
      expect(transferFileName(r'..\directory/CON.json'), '_CON.json');
      expect(transferFileName('a:b?.json'), 'a_b_.json');
    },
  );

  test(
    'legacy backend gets capability request only, no missing or write APIs',
    () async {
      final requests = <String>[];
      final api = ConfigTransferApi((request) async {
        requests.add('${request.method} ${request.path}');
        return const ConfigTransferResponse(404, {'detail': 'Not Found'});
      });
      await expectLater(
        api.export('09', ConfigExportMode.backup),
        throwsA(
          isA<ConfigTransferException>().having(
            (e) => e.message,
            'message',
            contains('尚未支持'),
          ),
        ),
      );
      await expectLater(
        api.importConfig(
          'new',
          ConfigTransferDocument.parse('a.json', utf8.encode('{"task":{}}')),
        ),
        throwsA(isA<ConfigTransferException>()),
      );
      expect(requests, [
        'GET /config/transfer/capabilities',
        'GET /config/transfer/capabilities',
      ]);
    },
  );

  test('legacy share-only capability cannot be called a full backup', () async {
    final requests = <String>[];
    final api = ConfigTransferApi((request) async {
      requests.add(request.path);
      final data = Map<String, dynamic>.from(capabilities)
        ..['modes'] = ['share'];
      return ConfigTransferResponse(200, data);
    });
    await expectLater(
      api.export('09', ConfigExportMode.backup),
      throwsA(isA<ConfigTransferException>()),
    );
    expect(requests, ['/config/transfer/capabilities']);
  });

  test(
    'backup/share request separate modes and validate bytes before saving',
    () async {
      final requests = <ConfigTransferRequest>[];
      final api = ConfigTransferApi((request) async {
        requests.add(request);
        if (request.path.endsWith('capabilities')) {
          return const ConfigTransferResponse(200, capabilities);
        }
        return ConfigTransferResponse(
          200,
          Uint8List.fromList(
            utf8.encode(
              '{"task": {"account": "${request.query['mode'] == 'backup' ? 'original' : '__OAS_REDACTED__'}"}}',
            ),
          ),
        );
      });
      final backup = await api.export('09', ConfigExportMode.backup);
      final share = await api.export(
        '09',
        ConfigExportMode.share,
        taskName: 'Chess',
      );
      expect(requests.map((r) => r.path), [
        '/config/transfer/capabilities',
        '/config/export',
        '/config/task/export',
      ]);
      expect(requests[1].query, {'name': '09', 'mode': 'backup'});
      expect(requests[2].query, {
        'config_name': '09',
        'task_name': 'Chess',
        'mode': 'share',
      });
      expect(utf8.decode(backup.bytes), contains('original'));
      expect(utf8.decode(share.bytes), contains('__OAS_REDACTED__'));
      expect(share.fileName, '09-Chess-share.json');
    },
  );

  test(
    'new config and single task uploads use AZ multipart protocol only',
    () async {
      final requests = <ConfigTransferRequest>[];
      final api = ConfigTransferApi((request) async {
        requests.add(request);
        if (request.path.endsWith('capabilities')) {
          return const ConfigTransferResponse(200, capabilities);
        }
        if (request.path == '/config/import') {
          return const ConfigTransferResponse(200, {
            'name': 'new',
            'file': 'new.json',
            'warnings': ['任务已停用'],
          });
        }
        return const ConfigTransferResponse(200, {
          'config_name': '09',
          'task_name': 'Chess',
          'file': '09.json',
          'updated': true,
        });
      });
      final doc = ConfigTransferDocument.parse(
        'file.json',
        utf8.encode('{"Chess":{}}'),
      );
      final result = await api.importConfig('new.json', doc);
      await api.importTask('09', 'Chess', doc);
      expect(result.warnings, ['任务已停用']);
      expect(requests[1].method, 'POST');
      final config = requests[1].data as FormData;
      expect(Map.fromEntries(config.fields), {'name': 'new'});
      expect(config.files.single.value.filename, 'file.json');
      final task = requests[2].data as FormData;
      expect(Map.fromEntries(task.fields), {
        'config_name': '09',
        'task_name': 'Chess',
      });
      expect(
        requests.every(
          (r) => !r.path.contains('start') && !r.path.contains('stop'),
        ),
        isTrue,
      );
    },
  );

  test(
    'running config protection and validation field errors reach the dialog',
    () async {
      var status = 409;
      final api = ConfigTransferApi((request) async {
        if (request.path.endsWith('capabilities')) {
          return const ConfigTransferResponse(200, capabilities);
        }
        return status == 409
            ? const ConfigTransferResponse(409, {'detail': '运行中的配置不能导入'})
            : const ConfigTransferResponse(400, {
                'detail': {
                  'message': '参数不合法',
                  'fields': ['Chess.scheduler.enable'],
                },
              });
      });
      final doc = ConfigTransferDocument.parse(
        'file.json',
        utf8.encode('{"Chess":{}}'),
      );
      await expectLater(
        api.importTask('09', 'Chess', doc),
        throwsA(
          isA<ConfigTransferException>().having((e) => e.code, 'code', 409),
        ),
      );
      status = 400;
      await expectLater(
        api.importTask('09', 'Chess', doc),
        throwsA(
          isA<ConfigTransferException>().having(
            (e) => e.message,
            'field',
            contains('Chess.scheduler.enable'),
          ),
        ),
      );
    },
  );

  test(
    'selected disk file is read with a bound and never from account profiles',
    () async {
      final dir = await Directory.systemTemp.createTemp('oasx-transfer-test-');
      try {
        final file = File('${dir.path}/demo.json');
        await file.writeAsString('{"demo":{}}');
        expect(
          (await ConfigTransferFiles.readJsonFile(file, 'demo.json')).bytes,
          isNotEmpty,
        );
        await file.writeAsBytes(Uint8List(configTransferMaxBytes + 1));
        await expectLater(
          ConfigTransferFiles.readJsonFile(file, 'demo.json'),
          throwsA(isA<ConfigTransferException>()),
        );
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );
}
