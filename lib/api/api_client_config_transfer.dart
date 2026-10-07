part of 'api_client.dart';

extension ApiClientConfigTransferX on ApiClient {
  ConfigTransferApi configTransfers() {
    final backend = address;
    return ConfigTransferApi((request) async {
      if (address != backend || backend.isEmpty) {
        throw const ConfigTransferException('后端地址已更改，请重新打开此操作。');
      }
      final cancel = CancelToken();
      try {
        final response = await NetOptions.instance.dio.request<dynamic>(
          '${backend.replaceFirst(RegExp(r'/+$'), '')}${request.path}',
          data: request.data,
          queryParameters: request.query,
          cancelToken: cancel,
          onReceiveProgress: (received, total) {
            if (received > configTransferMaxBytes + 65536) {
              cancel.cancel('Transfer response exceeds the size limit');
            }
          },
          options: Options(
            method: request.method,
            followRedirects: false,
            validateStatus: (_) => true,
            responseType: request.bytes
                ? ResponseType.bytes
                : ResponseType.json,
            extra: _cacheOptions
                .copyWith(policy: CachePolicy.noCache)
                .toExtra(),
            headers: const {'Cache-Control': 'no-store'},
            receiveTimeout: const Duration(seconds: 20),
          ),
        );
        var data = response.data;
        // The existing interceptor wraps every response, including binary ones.
        if (data is Map &&
            data.containsKey('code') &&
            data.containsKey('data')) {
          data = data['data'];
        }
        final status = response.statusCode ?? 0;
        if (status >= 400 && data is List<int>) {
          try {
            data = jsonDecode(utf8.decode(data));
          } on FormatException {
            data = null;
          }
        }
        return ConfigTransferResponse(status, data);
      } on DioException {
        throw const ConfigTransferException('无法连接当前后端，或传输已超时／超过大小限制，请重试。');
      }
    });
  }
}
