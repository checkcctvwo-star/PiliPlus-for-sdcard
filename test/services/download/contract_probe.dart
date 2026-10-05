/// Shared probe utilities for the Flutter <-> Kotlin MethodChannel contract
/// tests.
///
/// Background
/// ----------
/// `lib/services/download/*` talks to `MainActivity.kt` over
/// `MethodChannel('com.piliplus/download')`. Both sides agree on the *method
/// name*, but nothing in the type system forces them to agree on the *argument
/// map keys*. When the keys drift apart the Kotlin handler silently reads
/// `null` and replies `result.error("INVALID_ARGS", ...)`, which the Dart side
/// usually swallows. The result is a feature that looks like it works but never
/// does anything.
///
/// These helpers let a test assert the contract directly:
///   * [parseKotlinHandler] reads the real `MainActivity.kt` and extracts the
///     argument keys the native handler actually reads.
///   * [findDartCallSites] reads the real Dart sources and extracts the keys
///     each call site actually sends.
///   * [StrictKotlinDownloadChannel] installs a mock that enforces the
///     Kotlin-derived contract, rejecting mismatched keys exactly as the
///     device would.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The channel name shared by `DownloadManager` and `MainActivity`.
const String kDownloadChannelName = 'com.piliplus/download';

/// A single `<method, argumentKey>` pair observed on the Dart side.
class ChannelCallSite {
  const ChannelCallSite({
    required this.method,
    required this.argKeys,
    required this.file,
    required this.line,
  });

  /// The channel method name, e.g. `deleteSafFile`.
  final String method;

  /// Argument map keys this call site sends, e.g. `{path}`.
  final Set<String> argKeys;

  /// Production file the call was found in.
  final String file;

  /// 1-based line number, for readable failures.
  final int line;

  @override
  String toString() => '$method sends $argKeys @ $file:$line';
}

/// The argument keys a Kotlin handler reads.
class KotlinHandlerContract {
  const KotlinHandlerContract({
    required this.method,
    required this.requiredKeys,
    required this.optionalKeys,
    required this.line,
  });

  final String method;

  /// Keys that must be present and non-null, or the handler answers
  /// `INVALID_ARGS`.
  final Set<String> requiredKeys;

  /// Keys read through an elvis fallback such as
  /// `call.argument<String>("newPath") ?: call.argument<String>("newUri")`,
  /// where any one of the group is sufficient.
  final Set<String> optionalKeys;

  final int line;

  @override
  String toString() =>
      '$method requires $requiredKeys (optional alternatives: $optionalKeys)';
}

/// Locates the production sources under test.
class ProductionSources {
  const ProductionSources({
    required this.downloadServicePath,
    required this.downloadManagerPath,
    required this.mainActivityPath,
    required this.extraSettingsPath,
  });

  factory ProductionSources.fromPackageRoot(String packageRoot) {
    return ProductionSources(
      downloadServicePath:
          '$packageRoot/lib/services/download/download_service.dart',
      downloadManagerPath:
          '$packageRoot/lib/services/download/download_manager.dart',
      mainActivityPath:
          '$packageRoot/android/app/src/main/kotlin/com/example/piliplus/MainActivity.kt',
      extraSettingsPath:
          '$packageRoot/lib/pages/setting/models/extra_settings.dart',
    );
  }

  final String downloadServicePath;
  final String downloadManagerPath;
  final String mainActivityPath;

  /// `extra_settings.dart` writes the persisted download path after a
  /// directory switch, which is where a `content://` URI can leak into the
  /// filesystem-path variable.
  final String extraSettingsPath;
}

/// Reads the contract of the Kotlin handler registered for [method].
///
/// Throws [StateError] when no handler exists, so a method renamed on the
/// native side fails loudly instead of silently passing.
KotlinHandlerContract parseKotlinHandler({
  required String source,
  required String method,
}) {
  final marker = '"$method" ->';
  final markerIndex = source.indexOf(marker);
  if (markerIndex < 0) {
    throw StateError(
      'No Kotlin handler for "$method". The method name may have been renamed '
      'on the native side; update this contract test to match.',
    );
  }
  final braceStart = source.indexOf('{', markerIndex + marker.length);
  if (braceStart < 0) {
    throw StateError('Kotlin handler for "$method" has no body.');
  }
  final body = _readBalancedBraces(source, braceStart);

  // `a ?: b` means either key is acceptable, so neither is strictly required.
  final alternatives = <String>{};
  final elvis = RegExp(
    r'call\.argument<[^>]*>\(\s*"([^"]+)"\s*\)\s*\?:'
    r'\s*call\.argument<[^>]*>\(\s*"([^"]+)"\s*\)',
  );
  for (final m in elvis.allMatches(body)) {
    alternatives.add(m.group(1)!);
    alternatives.add(m.group(2)!);
  }

  final all = <String>{};
  final argPattern = RegExp(r'call\.argument<[^>]*>\(\s*"([^"]+)"\s*\)');
  for (final m in argPattern.allMatches(body)) {
    all.add(m.group(1)!);
  }

  return KotlinHandlerContract(
    method: method,
    requiredKeys: all.difference(alternatives),
    optionalKeys: alternatives,
    line: _lineOf(source, markerIndex),
  );
}

/// Whether `MainActivity.kt` declares a handler for [method].
bool kotlinHandles(String source, String method) =>
    source.contains('"$method" ->');

/// The body text of the Kotlin handler for [method], braces excluded.
///
/// Uses balanced-brace scanning rather than a regex so nested blocks and
/// string literals cannot truncate the result.
String kotlinHandlerBody({required String source, required String method}) {
  final marker = '"$method" ->';
  final markerIndex = source.indexOf(marker);
  if (markerIndex < 0) {
    throw StateError('No Kotlin handler for "$method".');
  }
  final braceStart = source.indexOf('{', markerIndex + marker.length);
  if (braceStart < 0) {
    throw StateError('Kotlin handler for "$method" has no body.');
  }
  return _readBalancedBraces(source, braceStart);
}

/// The body text of the Dart method [method], braces excluded.
///
/// Only declarations are matched: a candidate is accepted when the token after
/// the parameter list is `{`, optionally behind an `async`/`sync*` modifier.
/// That distinguishes `Future<void> deepScanRecovery() async {` from a call
/// site such as `_downloadService.deepScanRecovery();`.
///
/// Throws [StateError] when no declaration exists, so a renamed or deleted
/// method fails loudly instead of silently making the assertions pass.
String dartMethodBody({required String source, required String method}) {
  final candidates = RegExp(r'\b' + RegExp.escape(method) + r'\s*(<[^>]*>)?\s*\(')
      .allMatches(source)
      .toList();

  for (final match in candidates) {
    final parenStart = source.indexOf('(', match.start);
    final parenEnd = _matchingParen(source, parenStart);
    if (parenEnd < 0) continue;

    var i = _skipWhitespace(source, parenEnd + 1);
    // Skip `async`, `sync*`, `async*` modifiers.
    final modifier = RegExp(r'^(?:async\*?|sync\*)\b').firstMatch(source.substring(i));
    if (modifier != null) i = _skipWhitespace(source, i + modifier.end);

    if (i < source.length && source[i] == '{') {
      return _readBalancedBraces(source, i);
    }
  }

  throw StateError(
    'No Dart method declaration for "$method". It may have been renamed or '
    'removed; update this contract test to match.',
  );
}

/// Index of the `)` matching the `(` at [start], or -1.
int _matchingParen(String source, int start) {
  var depth = 0;
  var i = start;
  while (i < source.length) {
    final c = source[i];
    if (c == "'" || c == '"') {
      i = _skipString(source, i);
      continue;
    }
    if (c == '(') {
      depth++;
    } else if (c == ')') {
      depth--;
      if (depth == 0) return i;
    }
    i++;
  }
  return -1;
}

/// [body] with `//` line comments removed and their text replaced by spaces.
///
/// Necessary because the defect markers these tests search for routinely appear
/// in the very comment that documents the defect — `// skip bangumi for now`
/// sits on the line that drops every bangumi directory. Matching against the
/// raw body would let a comment satisfy an assertion about code.
String stripDartComments(String body) {
  final out = StringBuffer();
  for (var i = 0; i < body.length; i++) {
    final c = body[i];
    if (c == "'" || c == '"') {
      final end = _skipString(body, i);
      out.write(body.substring(i, end));
      i = end - 1;
      continue;
    }
    if (body.startsWith('//', i)) {
      final nl = body.indexOf('\n', i);
      final stop = nl < 0 ? body.length : nl;
      // Preserve offsets so reported columns/indices stay meaningful.
      out.write(' ' * (stop - i));
      i = stop - 1;
      continue;
    }
    out.write(c);
  }
  return out.toString();
}

/// Finds every Dart call site of [method] across [sources].
///
/// [sources] maps a file label to its text, so failures can name the file.
List<ChannelCallSite> findDartCallSites({
  required Map<String, String> sources,
  required String method,
}) {
  final sites = <ChannelCallSite>[];
  final pattern = RegExp(
    r'\binvoke[A-Za-z]*Method(?:<[^>]*>)?\s*\(\s*' "'$method'",
  );

  sources.forEach((file, source) {
    for (final match in pattern.allMatches(source)) {
      final afterName = match.end;
      final comma = _skipWhitespace(source, afterName);
      var keys = const <String>{};
      if (comma < source.length && source[comma] == ',') {
        final brace = _skipWhitespace(source, comma + 1);
        if (brace < source.length && source[brace] == '{') {
          keys = _topLevelMapKeys(_readBalancedBraces(source, brace));
        }
      }
      sites.add(ChannelCallSite(
        method: method,
        argKeys: keys,
        file: file,
        line: _lineOf(source, match.start),
      ));
    }
  });
  return sites;
}

/// The union of argument keys sent for [method], asserting there is at least
/// one call site.
Set<String> parseDartArgKeys({
  required Map<String, String> sources,
  required String method,
}) {
  final sites = findDartCallSites(sources: sources, method: method);
  if (sites.isEmpty) {
    throw StateError(
      'No Dart invocation of "$method" found in ${sources.keys.toList()}. '
      'The call may have been renamed or removed; update this contract test.',
    );
  }
  return sites.expand((s) => s.argKeys).toSet();
}

/// Every channel method name invoked in [source].
///
/// Matches the shape `invokeMethod('name', ...)` / `invokeMethod<T>('name')`
/// / `invokeListMethod<String>('name')`, which is how both `DownloadManager`
/// and `DownloadService` call this channel.
Set<String> dartMethodNamesIn(String source) {
  final names = <String>{};
  final pattern = RegExp(
    r"""\binvoke[A-Za-z]*Method(?:<[^>]*>)?\s*\(\s*'([A-Za-z_][A-Za-z0-9_]*)'""",
  );
  for (final m in pattern.allMatches(source)) {
    names.add(m.group(1)!);
  }
  return names;
}

/// The error code `MainActivity.kt` uses for a missing/invalid argument.
const String kInvalidArgsCode = 'INVALID_ARGS';

/// A mock handler reproducing the argument validation of `MainActivity.kt`.
///
/// The accepted keys are derived from the real Kotlin source on every call, so
/// this mock cannot drift away from the native implementation. A call whose
/// argument map lacks a required key is rejected with a [PlatformException]
/// carrying [kInvalidArgsCode], exactly as `call.argument<String>(...) == null`
/// triggers `result.error("INVALID_ARGS", ...)` on a real device.
class StrictKotlinDownloadChannel {
  StrictKotlinDownloadChannel({required this.source, MethodChannel? channel})
      : channel = channel ?? const MethodChannel(kDownloadChannelName);

  /// The real `MainActivity.kt` text.
  final String source;

  final MethodChannel channel;

  /// Every call this mock observed, in order.
  final List<MethodCall> observedCalls = [];

  /// Names the mocked `scanSafDirectory` reports as first-level directories.
  List<String> scanSafDirectoryFixture = <String>[];

  /// Relative path -> size, as the recursive part of `scanSafDirectory` and
  /// the whole of `scanSafFiles` report it.
  Map<String, int> scanSafFilesFixture = <String, int>{};

  /// The timestamp the mocked native scan stamps its result with.
  int scanSafScannedAtFixture = 0;

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handle);
  }

  void remove() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  }

  KotlinHandlerContract contractFor(String method) =>
      parseKotlinHandler(source: source, method: method);

  Future<Object?> handle(MethodCall call) async {
    observedCalls.add(call);
    if (!kotlinHandles(source, call.method)) {
      throw MissingPluginException(
        'MainActivity.kt declares no handler for "${call.method}"',
      );
    }
    final contract = contractFor(call.method);
    final args = _asMap(call.arguments);

    for (final key in contract.requiredKeys) {
      if (args[key] == null) {
        // Mirrors: val x = call.argument<String>("key")
        //          if (x == null) result.error("INVALID_ARGS", ...)
        throw PlatformException(
          code: kInvalidArgsCode,
          message: '${call.method}: call.argument("$key") is null. '
              'Dart sent keys: ${args.keys.toList()}. Kotlin requires '
              '${contract.requiredKeys}.',
        );
      }
    }

    switch (call.method) {
      case 'deleteSafFile':
      case 'deleteSafPath':
        return true;
      case 'startDownload':
      case 'saveToSafDirectory':
        return 'content://com.piliplus.download/tree/${args['targetDir'] ?? ''}';
      case 'scanSafDirectory':
        // Mirrors the native payload: first-level directory names for the
        // scan plan, plus the recursive file listing (relative path -> size)
        // and the timestamp that lets the caller tell a stale snapshot from a
        // fresh one.
        return <String, dynamic>{
          'dirs': scanSafDirectoryFixture,
          'files': scanSafFilesFixture,
          'scannedAt': scanSafScannedAtFixture,
        };
      case 'scanSafFiles':
        return scanSafFilesFixture;
      case 'resolveContentUriToPath':
        return '/storage/emulated/0/Download/resolved';
      case 'getUnfinishedTasks':
        return <Map<String, dynamic>>[];
      case 'pauseDownload':
      case 'pauseAll':
      case 'resumeAll':
      case 'resumeFailedTasks':
        return call.arguments == null ? null : true;
      default:
        return null;
    }
  }

  static Map<String, dynamic> _asMap(Object? arguments) {
    if (arguments is Map) {
      return arguments.map((k, v) => MapEntry(k.toString(), v));
    }
    return const {};
  }
}

/// Builds a representative argument map for [method] using [keys].
///
/// `uri` keys get a `content://` string and everything else a filesystem path,
/// mirroring what each side means by the value. This lets a test send the
/// *actual* key set production uses and observe whether the Kotlin contract
/// accepts it.
Map<String, dynamic> buildArgsFor(String method, Set<String> keys) {
  return {
    for (final key in keys)
      key: key == 'uri'
          ? 'content://com.piliplus.download/tree/document%3A%2Ftest'
          : '/storage/emulated/0/Download/$method/$key',
  };
}

/// Collects the top-level keys of a Dart map literal body.
///
/// [body] is the text *between* the outer braces; nesting is tracked so keys
/// of nested maps are not collected.
Set<String> _topLevelMapKeys(String body) {
  final keys = <String>{};
  var depth = 0;
  var i = 0;
  while (i < body.length) {
    final ch = body[i];
    if (ch == "'" || ch == '"') {
      // A top-level `'key':` pair contributes a key; anything else is a value.
      if (depth == 0) {
        final end = _skipString(body, i);
        var j = end;
        while (j < body.length && (body[j] == ' ' || body[j] == '\t')) {
          j++;
        }
        if (j < body.length && body[j] == ':') {
          keys.add(body.substring(i + 1, end - 1));
        }
      }
      i = _skipString(body, i);
      continue;
    }
    if (ch == '{' || ch == '[' || ch == '(') {
      depth++;
    } else if (ch == '}' || ch == ']' || ch == ')') {
      depth--;
    }
    i++;
  }
  return keys;
}

/// Returns the text between the brace pair that starts at [start].
String _readBalancedBraces(String source, int start) {
  var depth = 0;
  var i = start;
  while (i < source.length) {
    final c = source[i];
    if (c == "'" || c == '"') {
      i = _skipString(source, i);
      continue;
    }
    if (source.startsWith('//', i)) {
      final nl = source.indexOf('\n', i);
      i = nl < 0 ? source.length : nl + 1;
      continue;
    }
    if (c == '{') {
      depth++;
    } else if (c == '}') {
      depth--;
      if (depth == 0) return source.substring(start + 1, i);
    }
    i++;
  }
  throw StateError('Unbalanced "{" starting at offset $start');
}

/// Returns the index just past the string literal that starts at [start].
int _skipString(String s, int start) {
  final quote = s[start];
  var i = start + 1;
  while (i < s.length) {
    final c = s[i];
    // Written as '\\' rather than r'\' because a raw string cannot end with a
    // backslash.
    if (c == '\\') {
      i += 2;
      continue;
    }
    if (quote == '"' && s.startsWith('"""', i)) {
      final close = s.indexOf('"""', i);
      return close < 0 ? s.length : close + 3;
    }
    if (c == quote) return i + 1;
    i++;
  }
  return s.length;
}

int _skipWhitespace(String s, int i) {
  while (i < s.length &&
      (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r')) {
    i++;
  }
  return i;
}

int _lineOf(String source, int offset) {
  var line = 1;
  for (var i = 0; i < offset && i < source.length; i++) {
    if (source[i] == '\n') line++;
  }
  return line;
}
