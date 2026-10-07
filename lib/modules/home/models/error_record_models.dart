import 'dart:typed_data';

class ErrorRecordSummary {
  const ErrorRecordSummary({
    required this.id,
    required this.occurredAt,
    required this.title,
    this.scriptName,
    this.timestampMs = 0,
  });

  final String id;
  final String occurredAt;
  final String title;
  final String? scriptName;
  final int timestampMs;

  bool belongsTo(String account) => account.isNotEmpty && scriptName == account;

  ErrorRecordSummary withScriptName(String? owner) => ErrorRecordSummary(
    id: id,
    occurredAt: occurredAt,
    title: title,
    scriptName: owner,
    timestampMs: timestampMs,
  );
}

class ErrorRecordImage {
  const ErrorRecordImage({required this.name, required this.bytes});

  final String name;
  final Uint8List bytes;
}

class ErrorRecordDetail {
  const ErrorRecordDetail({
    required this.summary,
    required this.logText,
    this.images = const [],
    this.warning,
  });

  final ErrorRecordSummary summary;
  final String logText;
  final List<ErrorRecordImage> images;
  final String? warning;
}
