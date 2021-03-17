#!/usr/bin/env dart

library installer_windows;

import 'dart:io';

import 'package:yaml/yaml.dart';
import 'package:path/path.dart' as path;
import 'package:jinja/jinja.dart';

final rootDir = path
    .canonicalize(path.join(path.dirname(path.fromUri(Platform.script)), '..'));

// NB: there has got to be a better way to do this
final appDir = path.canonicalize(
    path.join(path.dirname(path.fromUri(Platform.packageConfig!)), '..'));

final pubspecYaml = path.join(appDir, 'pubspec.yaml');

const youDontHaveAProperPubspec = '''
Your app's pubspec.yaml doesn't have a Squirrel section, it is Highly Recommended 
to have one! Here's an example section with all of the available parameters, though
most are optional:

squirrel:
  windows:
    certificateFile: "foo"
    overrideSigningParameters: "bar"
    loadingGif: "baz"
    appIcon: "blamf"
    uninstallIconPngUrl: "blahhgh"
    appFriendlyName: "blaf"
    appDescription: "blaf"
    setupIcon: "bamf"
    releaseDirectory: "blaf"
    buildEnterpriseMsiPackage: false
    dontBuildDeltas: false
''';

String stringOrThrow(dynamic? d, String err) {
  if (d == null) {
    throw Exception(err);
  }

  return d.toString();
}

String parseVersion(dynamic? v) {
  final ver = stringOrThrow(v, 'Your app needs a version');
  return ver.replaceFirst(RegExp(r'[-+].*$'), '').trimLeft();
}

String parseAuthor(dynamic? a) {
  final author = stringOrThrow(a, 'Your pubspec needs an authors section');
  return author.replaceAll(RegExp(r' <.*?>'), '').trimLeft();
}

String? canonicalizePubspecPath(String? relativePath) {
  if (relativePath == null) {
    return null;
  }

  if (path.isAbsolute(relativePath)) {
    return relativePath;
  }

  return path.normalize(path.join(appDir, relativePath));
}

const defaultUninstallPngUrl = 'https://fill/in/this/later';

class PubspecParams {
  final String name;
  final String title;
  final String version;
  final String authors;
  final String description;
  final String appIcon;
  final String? certificateFile;
  final String? overrideSigningParameters;
  final String loadingGif;
  final String? uninstallIconPngUrl;
  final String? setupIcon;
  final String releaseDirectory;
  final bool buildEnterpriseMsiPackage;
  final bool dontBuildDeltas;

  PubspecParams(
      this.name,
      this.title,
      this.version,
      this.authors,
      this.description,
      this.appIcon,
      this.certificateFile,
      this.overrideSigningParameters,
      this.loadingGif,
      this.uninstallIconPngUrl,
      this.setupIcon,
      this.releaseDirectory,
      this.buildEnterpriseMsiPackage,
      this.dontBuildDeltas);

  factory PubspecParams.fromYaml(dynamic appPubspec) {
    dynamic windowsSection = appPubspec['squirrel']['windows'];
    if (windowsSection == null) {
      stderr.writeln(youDontHaveAProperPubspec);
      windowsSection = {};
    }

    final name = appPubspec['name'].toString();
    final title = stringOrThrow(
        windowsSection['appFriendlyName'] ?? appPubspec['title'],
        'Your app needs a description!');
    final version = parseVersion(appPubspec['version']);
    final authors = parseAuthor(appPubspec['authors']);
    final description = stringOrThrow(windowsSection['appDescription'] ?? title,
        'Your app must have a description');
    final appIcon = canonicalizePubspecPath(stringOrThrow(
        windowsSection['appIcon'], 'Your app must have an icon'))!;
    final certificateFile =
        canonicalizePubspecPath(windowsSection['certificateFile']?.toString());
    final overrideSigningParameters =
        windowsSection['overrideSigningParameters']?.toString();
    final loadingGif = canonicalizePubspecPath((windowsSection['loadingGif'] ??
            path.join(rootDir, 'vendor', 'default-loading.gif'))
        .toString())!;
    final uninstallIconPngUrl =
        (windowsSection['uninstallIconPngUrl'] ?? defaultUninstallPngUrl)
            .toString();
    final setupIcon = canonicalizePubspecPath(
        (windowsSection['setupIcon'] ?? appIcon).toString());
    final releaseDirectory = canonicalizePubspecPath(
        windowsSection['releaseDirectory']?.toString() ??
            path.join(appDir, 'build'))!;
    final buildEnterpriseMsiPackage =
        windowsSection['buildEnterpriseMsiPackage'] == true ? true : false;
    final dontBuildDeltas =
        windowsSection['dontBuildDeltas'] == true ? true : false;

    return PubspecParams(
        name,
        title,
        version,
        authors,
        description,
        appIcon,
        certificateFile,
        overrideSigningParameters,
        loadingGif,
        uninstallIconPngUrl,
        setupIcon,
        releaseDirectory,
        buildEnterpriseMsiPackage,
        dontBuildDeltas);
  }
}

Future<ProcessResult> runUtil(String name, List<String> args,
    {String? cwd}) async {
  final cmd = path.join(rootDir, 'vendor', name);
  final ret = await Process.run(cmd, args, workingDirectory: cwd);

  if (ret.exitCode != 0) {
    final msg =
        "Failed to run $cmd ${args.join(' ')}\n${ret.stdout}\n${ret.stderr}";
    throw Exception(msg);
  }

  return ret;
}

Future<int> main(List<String> args) async {
  final yaml = loadYaml(await File(pubspecYaml).readAsString());

  final template = Environment().fromString(
      await File(path.join(rootDir, 'nuspec.jinja')).readAsString());

  final pubspec = PubspecParams.fromYaml(yaml);
  final buildDirectory = canonicalizePubspecPath(
      path.join('build', 'windows', 'runner', 'Release'))!;

  // Copy Squirrel.exe into the app dir and squish the setup icon in
  final tgtSquirrel = path.join(buildDirectory, 'squirrel.exe');
  if (!await File(tgtSquirrel).exists()) {
    await File(path.join(rootDir, 'vendor', 'squirrel.exe')).copy(tgtSquirrel);
  }

  if (pubspec.setupIcon != null) {
    await runUtil(
        'rcedit.exe', ['--set-icon', pubspec.setupIcon!, tgtSquirrel]);
  }

  // Squish the icon into main exe
  await runUtil('rcedit.exe', [
    '--set-icon',
    pubspec.appIcon,
    path.join(buildDirectory, '${pubspec.name}.exe')
  ]);

  // ls -r to get our file tree and create a temp dir
  final filePaths = await Directory(buildDirectory)
      .list(recursive: true)
      .where((f) => f.statSync().type == FileSystemEntityType.file)
      .map((f) => f.path.replaceFirst(buildDirectory, '').substring(1))
      .toList();

  final nuspecContent = template
      .render(
          name: pubspec.name,
          title: pubspec.title,
          description: pubspec.description,
          version: pubspec.version,
          authors: pubspec.authors,
          iconUrl: pubspec.uninstallIconPngUrl,
          additionalFiles: filePaths.map((f) => ({'src': f, 'target': f})))
      .toString();

  // NB: NuGet sucks
  final tmpDir = await Directory.systemTemp.createTemp('si-');
  final nuspec = path.join(tmpDir.path, 'spec.nuspec');
  await File(nuspec).writeAsString(nuspecContent);
  await runUtil('nuget.exe', [
    'pack',
    nuspec,
    '-BasePath',
    buildDirectory,
    '-OutputDirectory',
    tmpDir.path,
    '-NoDefaultExcludes'
  ]);

  final nupkgFile =
      (await tmpDir.list().firstWhere((f) => f.path.contains('.nupkg'))).path;

  // Prepare the release directory
  final releaseDir = Directory(pubspec.releaseDirectory);
  if (await releaseDir.exists()) {
    await releaseDir.delete(recursive: true);
  }

  await releaseDir.create(recursive: true);

  // Run syncReleases
  // XXX TODO

  // Releasify!
  var args = [
    '--releasify',
    nupkgFile,
    '--releaseDir',
    releaseDir.path,
    '--loadingGif',
    pubspec.loadingGif,
  ];

  // TODO: Signing!

  if (pubspec.dontBuildDeltas) {
    args.add('--no-delta');
  }

  if (!pubspec.buildEnterpriseMsiPackage) {
    args.add('--no-msi');
  }

  if (pubspec.setupIcon != null) {
    args.addAll(['--setupIcon', pubspec.setupIcon!]);
  }

  await runUtil('squirrel.exe', args);
  return 0;
}
