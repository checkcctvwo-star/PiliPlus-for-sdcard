/// Pure logic for deciding **which directories a deep scan should walk, and
/// which recovery path each one needs**.
///
/// Why this exists
/// ---------------
/// `DownloadService.deepScanRecovery()` (download_service.dart:184-345) mixes
/// three hard-to-test concerns in one method: a MethodChannel round trip to the
/// native SAF scanner, real filesystem traversal, and the B站 API call that
/// rebuilds a `BiliDownloadEntryInfo`. The part that actually decides *what to
/// scan* is pure, and that is what went wrong:
///
/// ```dart
/// final folders = <String>{};
/// // ... local directories added as bare names: folders.add(path.basename(...))
/// // ... SAF directories added as bare names too:  folders.addAll(safDirs)
/// for (final avidStr in folders) {
///   if (avidStr.startsWith('s_')) continue;                        // (1)
///   final avidPath = path.join(downloadPathStr, avidStr);   // <-- always local
///   final dir = Directory(avidPath);
///   if (!dir.existsSync()) continue;                        // <-- SAF 100% dropped
/// ```
///
/// Three separate defects live in those five lines:
///
///  * **(1) 番剧被无条件丢弃。** `s_<seasonId>` directories are skipped with a
///    bare `continue` and nothing is recorded, so a season whose `entry.json`
///    was lost is never rebuilt and the user is never told. Skipping is only
///    acceptable if the season is *routed to a different recovery path* and
///    reported — hence [ScanKind.bangumi] below.
///  * **SAF 目录名被当成本地路径。** SAF directories are not filesystem paths;
///    they live behind a `content://` tree URI. Joining a SAF directory name
///    onto the local download path can never resolve, so the `existsSync()`
///    guard silently discards every SAF directory. The user sees "scan
///    finished" and nothing happens.
///
/// This file holds that decision as a pure function so it can be tested
/// without a device, a channel, or a network call.
///
/// **Status: used by `DownloadService.deepScanRecovery`.** The plan splits the
/// discovered names by storage and by recovery path, so the SAF branch is
/// reachable at all and a bangumi season is routed to a pass that can act on it
/// instead of being dropped. The tests in `deep_scan_logic_test.dart` assert
/// both this file's behaviour and the production call sites that consume it.
library;

import 'package:path/path.dart' as p;

/// Where a candidate directory physically lives.
///
/// This is a **storage** question, and it is orthogonal to [ScanKind]: a
/// bangumi season can live on the local filesystem or behind a SAF tree URI,
/// and both need the same *kind* of handling.
enum ScanRootKind {
  /// A real directory on the local filesystem, reachable via `Directory.exists`.
  local,

  /// A directory inside the SAF tree, reachable only through a `content://`
  /// URI. Must never be treated as a local path.
  saf,
}

/// Which recovery path a directory needs.
///
/// The production bug is a missing `case`: `deepScanRecovery` has exactly one
/// path (rebuild an avid entry from the B站 web API) and reaches it by skipping
/// everything that is not an avid. Making the required path explicit is what
/// turns "silently dropped" into "handled by someone".
enum ScanKind {
  /// A regular UGC video keyed by `aid`. Rebuildable from
  /// `https://api.bilibili.com/x/web-interface/view?aid=<id>`.
  avid,

  /// A bangumi season (`s_<seasonId>`). **Must not be fed to the avid
  /// recovery path** — the `aid` lookup would 404 — and **must not be
  /// discarded either**. It needs the PGC season/episode API, so it is routed
  /// out and surfaced for a dedicated pass.
  bangumi,
}

/// One directory the deep scan should visit.
class ScanRoot {
  const ScanRoot({
    required this.name,
    required this.kind,
    required this.scanKind,
    this.uri,
  });

  /// The bare directory name, e.g. `123` (an avid) or `s_456` (a season).
  final String name;

  /// Where the directory physically lives.
  final ScanRootKind kind;

  /// Which recovery path this directory needs.
  final ScanKind scanKind;

  /// The `content://` tree URI, set only when [kind] is [ScanRootKind.saf].
  final String? uri;

  bool get isSaf => kind == ScanRootKind.saf;

  bool get isBangumi => scanKind == ScanKind.bangumi;

  @override
  String toString() => 'ScanRoot($scanKind,${isSaf ? 'saf' : 'local'}:$name'
      '${uri == null ? '' : ',$uri'})';

  @override
  bool operator ==(Object other) =>
      other is ScanRoot &&
      other.name == name &&
      other.kind == kind &&
      other.scanKind == scanKind &&
      other.uri == uri;

  @override
  int get hashCode => Object.hash(name, kind, scanKind, uri);
}

/// The set of directories a deep scan should walk.
///
/// Every discovered directory appears in exactly one of [avidRoots] /
/// [bangumiRoots]. There is deliberately **no** "skipped" bucket: the production
/// defect is precisely that `s_` directories fall out of the scan with no
/// record, and an API that models "skipped" as a first-class list invites
/// re-introducing it. Completeness is what the tests assert instead.
class ScanPlan {
  const ScanPlan({required this.avidRoots, required this.bangumiRoots});

  /// Regular UGC directories, local and SAF kept distinct.
  final List<ScanRoot> avidRoots;

  /// Bangumi season directories routed to the dedicated PGC recovery path.
  ///
  /// Non-empty is normal and healthy. The bug is these being *absent* — today
  /// `deepScanRecovery` `continue`s past them and forgets they exist.
  final List<ScanRoot> bangumiRoots;

  /// Every directory the scan must visit.
  ///
  /// Sized to equal the number of distinct discovered names: nothing is
  /// dropped on the floor.
  List<ScanRoot> get roots => [...avidRoots, ...bangumiRoots];

  Iterable<ScanRoot> get localRoots => roots.where((r) => !r.isSaf);

  Iterable<ScanRoot> get safRoots => roots.where((r) => r.isSaf);

  /// Local UGC directories — the only ones `path.join(downloadPath, name)` is
  /// valid for.
  Iterable<ScanRoot> get localAvidRoots =>
      avidRoots.where((r) => r.kind == ScanRootKind.local);

  /// UGC directories inside the SAF tree. Reachable only via [ScanRoot.uri].
  Iterable<ScanRoot> get safAvidRoots =>
      avidRoots.where((r) => r.kind == ScanRootKind.saf);

  /// The local filesystem path for a local root, or null for a SAF root.
  ///
  /// Returning null for SAF roots is the point: a SAF directory has no local
  /// path, and code that needs one must go through the channel instead. The
  /// production bug is a call site that ignores this null and joins anyway.
  String? localPathFor(ScanRoot root, String localDownloadPath) =>
      root.isSaf ? null : p.join(localDownloadPath, root.name);
}

/// Builds the set of directories to scan and the recovery path each needs.
///
/// [localDirNames] are bare directory names discovered under the local download
/// path. [safDirNames] are the names `scanSafDirectory` reported for the SAF
/// tree, and [safTreeUri] is that tree's `content://` URI.
///
/// Behaviour this encodes, each of which corresponds to a real defect:
///
///  * A SAF directory is a [ScanRootKind.saf] root carrying [safTreeUri]. It is
///    never joined onto the local download path, so it cannot be silently
///    dropped by an `existsSync()` check on a path that never existed.
///  * A name present in both sources yields **two** roots, because they are two
///    different directories holding two different sets of files. Merging them
///    would lose whichever copy the merge dropped.
///  * A `s_`-prefixed name becomes a [ScanKind.bangumi] root rather than being
///    skipped. It is kept out of [ScanPlan.avidRoots] — feeding a season id to
///    the avid `view?aid=` API cannot work — but it is still present in
///    [ScanPlan.roots] and routed to its own pass. `skippedBangumi` in the
///    previous version of this file modelled the defect, not the fix.
///  * [safDirNames] without a [safTreeUri] yields no SAF roots; a name alone
///    cannot address anything in a SAF tree. Those names are reported by
///    [unaddressableSafNames] instead of vanishing.
ScanPlan buildScanPlan({
  required List<String> localDirNames,
  List<String> safDirNames = const [],
  String? safTreeUri,
}) {
  final avid = <ScanRoot>[];
  final bangumi = <ScanRoot>[];

  // A seen-set per (recovery-path, storage) pair, mirroring the `Set<String>`
  // the production code used, so duplicate names within one source stay
  // collapsed.
  final seen = <String>{};

  void add(String name, ScanRootKind kind, String? uri) {
    final scanKind = name.startsWith('s_') ? ScanKind.bangumi : ScanKind.avid;
    if (!seen.add('$scanKind/$kind/$name')) return;
    (scanKind == ScanKind.bangumi ? bangumi : avid)
        .add(ScanRoot(name: name, kind: kind, scanKind: scanKind, uri: uri));
  }

  // Local first, so the common case keeps a stable order.
  for (final name in localDirNames) {
    add(name, ScanRootKind.local, null);
  }

  final hasTree = safTreeUri != null && safTreeUri.isNotEmpty;
  if (hasTree) {
    for (final name in safDirNames) {
      add(name, ScanRootKind.saf, safTreeUri);
    }
  }

  return ScanPlan(avidRoots: avid, bangumiRoots: bangumi);
}

/// SAF directory names that were reported by the native scanner but cannot be
/// visited, because no `content://` tree URI was supplied.
///
/// A bare directory name is not an address in a SAF tree, so these names are
/// unreachable. The defect is not that they are unreachable — it is that
/// `deepScanRecovery` merges them into the local name set anyway and lets
/// `existsSync()` swallow them. Surfacing them here makes the loss explicit.
List<String> unaddressableSafNames({
  required List<String> safDirNames,
  required String? safTreeUri,
}) {
  if (safTreeUri != null && safTreeUri.isNotEmpty) return const [];
  final out = <String>[];
  for (final name in safDirNames) {
    if (!out.contains(name)) out.add(name);
  }
  return out;
}

/// What one deep-scan pass actually did.
///
/// Exists because the UI used to announce "扫描完成" unconditionally: a pass
/// that rebuilt nothing, a pass that silently skipped every SAF directory, and
/// a pass whose channel call threw all produced the same message, so a user
/// whose downloads had vanished had no way to learn that from the app.
///
/// Every field is a count of something, or a value that stopped the scan. A
/// zero therefore means "checked and there was nothing wrong", which is what
/// makes the message worth reading.
class DeepScanReport {
  const DeepScanReport({
    this.recovered = 0,
    this.requeued = 0,
    this.safVerified = 0,
    this.safOrphans = const [],
    this.unrecoveredBangumi = const [],
    this.unreachableSafNames = const [],
    this.bangumiChecked = 0,
    this.safScanned = false,
    this.safScannedAt = 0,
    this.safError,
  });

  /// The all-zero report, used before the first scan runs.
  static const empty = DeepScanReport();

  /// Entries rebuilt from a B站 API lookup after their `entry.json` was lost.
  final int recovered;

  /// Entries found incomplete and pushed back onto the wait queue.
  final int requeued;

  /// Entries whose SAF copies were confirmed present.
  final int safVerified;

  /// Files found in the SAF tree that no local entry claims.
  ///
  /// Reported, never deleted: a previous install may have copied them, and
  /// there is no metadata in the tree to tell a wanted file from a stray one.
  final List<String> safOrphans;

  /// Bangumi season directories this pass could not recover.
  final List<String> unrecoveredBangumi;

  /// SAF directory names that were reported but cannot be addressed, because no
  /// tree URI was available.
  ///
  /// The defect is not that they are unreachable — it is that the scan used to
  /// merge them into the local name set and let an existence check discard
  /// them, so a whole storage backend could go unscanned without a trace.
  final List<String> unreachableSafNames;

  /// Bangumi directories whose integrity was actually checked.
  final int bangumiChecked;

  /// Whether the SAF tree was walked at all this pass.
  ///
  /// False on the automatic pass that runs when the download page opens, so a
  /// quiet report is not mistaken for a clean bill of health for SAF.
  final bool safScanned;

  /// Wall-clock time of the native scan, as reported by the platform.
  final int safScannedAt;

  /// The error that aborted the SAF scan, if any.
  final Object? safError;

  /// Whether anything at all needs the user's attention.
  bool get hasFindings =>
      requeued > 0 ||
      safOrphans.isNotEmpty ||
      unrecoveredBangumi.isNotEmpty ||
      unreachableSafNames.isNotEmpty ||
      safError != null;

  /// A one-line summary for a toast. Describes what the scan did, not just that
  /// it finished, because a silent pass is indistinguishable from a clean one.
  String get message {
    final parts = <String>[
      if (recovered > 0) '重建 $recovered 个任务',
      if (requeued > 0) '重新入队 $requeued 个',
      if (safVerified > 0) 'SAF 校验 $safVerified 个正常',
      if (safOrphans.isNotEmpty) '发现 ${safOrphans.length} 个孤儿文件',
      if (unrecoveredBangumi.isNotEmpty)
        '${unrecoveredBangumi.length} 个番剧无法自动恢复',
      if (unreachableSafNames.isNotEmpty)
        '${unreachableSafNames.length} 个 SAF 目录无法访问',
      if (safError != null) 'SAF 扫描失败: $safError',
    ];
    if (parts.isEmpty) {
      return safScanned ? '没有需要恢复的任务' : '没有需要恢复的任务（未扫描 SAF）';
    }
    return parts.join('，');
  }

  @override
  String toString() => 'DeepScanReport($message)';
}
