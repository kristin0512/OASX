part of 'api_client.dart';

extension ApiClientStatisticsX on ApiClient {
  /// Runhey does not expose AzurTian's optional statistics routes. Discover this
  /// before requesting dates, so the unchanged UI uses its existing empty state.
  Future<bool> supportsScriptStatistics() {
    final supported = _statisticsSupported;
    if (supported != null) return Future.value(supported);
    return _statisticsProbe ??= _loadStatisticsCapability();
  }

  Future<bool> _loadStatisticsCapability() async {
    final requestedAddress = address;
    try {
      final result = await _getStatisticsDocument('/openapi.json', probe: true);
      if (!result.isSuccess) {
        throw StateError(
          result.error ?? 'Unable to inspect backend capabilities',
        );
      }
      final supported = statisticsRoutesAvailable(result.data);
      if (address == requestedAddress) _statisticsSupported = supported;
      return supported;
    } finally {
      if (address == requestedAddress) _statisticsProbe = null;
    }
  }

  Future<ApiResult<dynamic>> _getStatisticsDocument(
    String path, {
    bool probe = false,
  }) {
    final override = _statisticsGetOverride;
    if (override != null) return override(path);
    return request(
      () => get(
        path,
        options: Options(
          extra: {
            ..._cacheOptions.copyWith(policy: CachePolicy.noCache).toExtra(),
            if (probe) 'optionalCapabilityProbe': true,
          },
        ),
      ),
    );
  }

  Future<ScriptStatisticsDateList> getScriptStatisticsDates(
    String scriptName,
  ) async {
    if (!await supportsScriptStatistics()) {
      return ScriptStatisticsDateList(scriptName: scriptName, dates: const []);
    }
    final path = '/stats/${Uri.encodeComponent(scriptName)}/dates';
    final res = await _getStatisticsDocument(path);
    if (!res.isSuccess || res.data is! Map) {
      throw Exception(res.error ?? 'Invalid statistics dates response');
    }
    return ScriptStatisticsDateList.fromJson(
      Map<String, dynamic>.from(res.data),
    );
  }

  Future<ScriptStatisticsDay> getScriptStatisticsDay(
    String scriptName,
    String dateKey,
  ) async {
    if (!await supportsScriptStatistics()) {
      throw UnsupportedError('This backend does not provide script statistics');
    }
    final path = '/stats/${Uri.encodeComponent(scriptName)}?date=$dateKey';
    final res = await _getStatisticsDocument(path);
    if (!res.isSuccess || res.data is! Map) {
      throw Exception(res.error ?? 'Invalid statistics day response');
    }
    return parseScriptStatisticsDayAsync(
      Map<String, dynamic>.from(res.data),
      dateKey: dateKey,
    );
  }

  Uri buildScriptStatisticsSseUri(String scriptName, String dateKey) {
    final addressText = ApiClient.resolveAddress(address);
    final baseAddress =
        addressText.startsWith('http://') || addressText.startsWith('https://')
        ? addressText
        : 'http://$addressText';
    return Uri.parse(
      '$baseAddress/stats/${Uri.encodeComponent(scriptName)}/stream?date=$dateKey',
    );
  }
}

/// Requires the actual HTTP and live-stream API, never infers results from logs.
bool statisticsRoutesAvailable(dynamic document) {
  if (document is! Map || document['paths'] is! Map) {
    throw const FormatException('Invalid backend OpenAPI document');
  }
  final paths = document['paths'] as Map;
  final getPaths = paths.entries
      .where((entry) => entry.value is Map && entry.value['get'] is Map)
      .map(
        (entry) => entry.key.toString().replaceAll(RegExp(r'\{[^}]+\}'), '{}'),
      )
      .toSet();
  return getPaths.containsAll({
    '/stats/{}/dates',
    '/stats/{}',
    '/stats/{}/stream',
  });
}
