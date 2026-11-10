import 'dart:io';

import 'package:path/path.dart' as p;

/// Canonical path resolution for workspace tools (PRD #8).
///
/// For a new target, the nearest existing ancestor is resolved first. This is
/// important for paths such as `workspace/link/new/file.txt`: checking only
/// the not-yet-existing parent lexically would miss a symlink that points
/// outside the workspace.
class PathSafety {
  static String? resolveInRoot(String root, String relativeOrAbs) {
    if (relativeOrAbs.contains('\u0000')) return null;
    try {
      final rootPath = p.normalize(p.absolute(root));
      if (FileSystemEntity.typeSync(rootPath, followLinks: true) !=
          FileSystemEntityType.directory) {
        return null;
      }
      final rootReal = Directory(rootPath).resolveSymbolicLinksSync();
      final candidate = p.normalize(
        p.isAbsolute(relativeOrAbs)
            ? relativeOrAbs
            : p.join(rootReal, relativeOrAbs),
      );
      if (candidate != rootReal && !p.isWithin(rootReal, candidate)) {
        return null;
      }

      var current = candidate;
      final missingSegments = <String>[];
      String resolvedAncestor;
      while (true) {
        final type = FileSystemEntity.typeSync(current, followLinks: false);
        if (type == FileSystemEntityType.notFound) {
          final parent = p.dirname(current);
          if (parent == current) return null;
          missingSegments.insert(0, p.basename(current));
          current = parent;
          continue;
        }

        if (type == FileSystemEntityType.link) {
          resolvedAncestor = Link(current).resolveSymbolicLinksSync();
        } else if (type == FileSystemEntityType.file) {
          resolvedAncestor = File(current).resolveSymbolicLinksSync();
        } else if (type == FileSystemEntityType.directory) {
          resolvedAncestor = Directory(current).resolveSymbolicLinksSync();
        } else {
          // Sockets, devices, and other special files are not valid tool paths.
          return null;
        }
        break;
      }

      if (resolvedAncestor != rootReal && !p.isWithin(rootReal, resolvedAncestor)) {
        return null;
      }
      final resolved = p.normalize(p.joinAll([resolvedAncestor, ...missingSegments]));
      if (resolved != rootReal && !p.isWithin(rootReal, resolved)) return null;
      return resolved;
    } catch (_) {
      // Fail closed on broken symlinks, permissions, and filesystem races.
      return null;
    }
  }
}
