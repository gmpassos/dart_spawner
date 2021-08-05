import 'dart:io';

import 'package:path/path.dart' as pack_path;

bool isFileInDirectory(Directory parentDir, File file) {
  var parentPath = parentDir.path;

  if (!parentPath.endsWith(pack_path.separator)) {
    parentPath = '$parentPath${pack_path.separator}';
  }

  return file.path.startsWith(parentPath);
}

void deleteFile(Directory directoryScope, File file, {bool verbose = false}) {
  if (!isFileInDirectory(directoryScope, file)) {
    throw StateError(
        "File out of directory scope! directoryScope: $directoryScope ; file: $file");
  }

  if (FileSystemEntity.isDirectorySync(file.path)) {
    var dir = Directory(file.path);
    if (dir.existsSync()) {
      if (verbose) {
        print('-- Delete directory: $dir');
      }

      dir.deleteSync();
    }
  } else {
    if (file.existsSync()) {
      if (verbose) {
        print('-- Delete file: $file');
      }

      file.deleteSync();
    }
  }
}

void deleteDirectory(Directory directoryScope, Directory dir,
    {bool recursive = false, bool verbose = false}) {
  var files = dir.listSync(recursive: recursive, followLinks: false);

  for (var f in files) {
    if (!FileSystemEntity.isDirectorySync(f.path)) {
      deleteFile(directoryScope, File(f.path), verbose: verbose);
    }
  }

  files = dir.listSync(recursive: recursive, followLinks: false);

  files.sort((a, b) {
    var p1 = pack_path.split(a.path).length;
    var p2 = pack_path.split(b.path).length;
    return p2.compareTo(p1);
  });

  for (var f in files) {
    deleteFile(directoryScope, File(f.path), verbose: verbose);
  }

  dir.deleteSync();
}
