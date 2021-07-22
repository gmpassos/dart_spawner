import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as path_tool;

extension IsolateExtension on Isolate {
  Future<Directory> packageDirectory(String directoryPath) async {
    var mainDir = await packageMainDirectory;
    return mainDir.subDirectory(directoryPath);
  }

  Future<File> packageFile(String filePath) async {
    var mainDir = await packageMainDirectory;
    return mainDir.subFile(filePath);
  }

  Future<Directory> get packageMainDirectory async {
    var packageConfigUri = await Isolate.packageConfig;
    if (packageConfigUri == null) {
      return Directory.current;
    }

    var packageConfigFile = packageConfigUri.toFile().absolute;

    var dir = packageConfigFile.parent.absolute;

    if (dir.name == '.dart_tool') {
      dir = dir.parent.absolute;
    }

    return dir;
  }
}

extension UriExtension on Uri {
  File toFile({bool? windows}) => File(toFilePath(windows: windows));
}

extension FileSystemEntityExtension on FileSystemEntity {
  List<String> get pathParts => path_tool.split(path);

  String get name => pathParts.last;
}

extension DirectoryExtension on Directory {
  File subFile(String subFilePath) => File(path_tool.join(path, subFilePath));

  Directory subDirectory(String subDirectoryPath) =>
      Directory(path_tool.join(path, subDirectoryPath));
}
