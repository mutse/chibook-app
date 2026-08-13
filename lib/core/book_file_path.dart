/// Convert a persisted book path into a path inside the current app container.
///
/// iOS may assign a new sandbox container UUID after an app reinstall/update.
/// Absolute paths saved by an older build then point at a non-existent
/// `Documents` directory even though the copied book is still available in the
/// current container. Imported books are always owned by `Documents/library`,
/// so only that suffix is migrated.
String? resolveBookFilePath(String? storedPath, String documentsPath) {
  if (storedPath == null || storedPath.isEmpty) return storedPath;
  final stored = storedPath.replaceAll('\\', '/');
  final documents = _withoutTrailingSlash(documentsPath.replaceAll('\\', '/'));
  const relativeLibrary = 'library/';
  if (stored.startsWith(relativeLibrary)) return '$documents/$stored';

  final libraryMarker = stored.lastIndexOf('/library/');
  if (libraryMarker >= 0) {
    return '$documents/library/${_basename(stored)}';
  }
  return storedPath;
}

/// Make an app-owned book path portable before writing it to preferences.
///
/// Paths outside `Documents/library` are preserved for backwards
/// compatibility; imports created by this app are always under that folder.
String? persistableBookFilePath(String? runtimePath, String documentsPath) {
  if (runtimePath == null || runtimePath.isEmpty) return runtimePath;
  final runtime = runtimePath.replaceAll('\\', '/');
  final documents = _withoutTrailingSlash(documentsPath.replaceAll('\\', '/'));
  final library = '$documents/library/';
  if (runtime.startsWith(library)) return 'library/${_basename(runtime)}';
  return runtimePath;
}

String _basename(String path) {
  final index = path.lastIndexOf('/');
  return index < 0 ? path : path.substring(index + 1);
}

String _withoutTrailingSlash(String path) =>
    path.endsWith('/') ? path.substring(0, path.length - 1) : path;
