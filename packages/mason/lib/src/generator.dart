import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory, File, FileMode, FileSystemEntity, Process;
import 'dart:isolate';

import 'package:checked_yaml/checked_yaml.dart';
import 'package:collection/collection.dart';
import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:mason/mason.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:pool/pool.dart';

part 'hooks.dart';

// This is intentionally a getter instead of a constant since nested hook
// execution depends on being able to detect the runtime dynamically.
// ignore: prefer_const_constructors, do_not_use_environment
bool get _isAotCompiled => bool.fromEnvironment('dart.vm.product');

final _descriptorPool = Pool(32);
final _partialRegExp = RegExp(r'\{\{~\s(.+)\s\}\}');
final _fileRegExp = RegExp(r'{{%\s?([a-zA-Z]+)\s?%}}');
final _delimiterRegExp = RegExp('{{([^;,=]*?)}}');
final _loopKeyRegExp = RegExp('{{#(.*?)}}');
final _loopValueReplaceRegExp = RegExp('({{{.*?}}})');
final _lambdas = RegExp(
  '''(camelCase|constantCase|dotCase|headerCase|lowerCase|pascalCase|paramCase|pathCase|sentenceCase|snakeCase|titleCase|upperCase)''',
);

RegExp _loopRegExp([String name = '.*?']) {
  return RegExp('({{#$name}}.*?{{{.*?}}}.*?{{/$name}})');
}

RegExp _loopValueRegExp([String name = '.*?']) {
  return RegExp('{{#$name}}.*?{{{(.*?)}}}.*?{{/$name}}');
}

RegExp _loopInnerRegExp([String name = '.*?']) {
  return RegExp('{{#$name}}(.*?{{{.*?}}}.*?){{/$name}}');
}

/// {@template mason_generator}
/// A [MasonGenerator] which extends [Generator] and
/// exposes the ability to create a [Generator] from a
/// [Brick].
/// {@endtemplate}
class MasonGenerator extends Generator {
  /// {@macro mason_generator}
  MasonGenerator(
    String id,
    String description, {
    List<TemplateFile?> files = const <TemplateFile>[],
    GeneratorHooks hooks = const GeneratorHooks(),
    this.vars = const <String>[],
  }) : super(id, description, hooks) {
    for (final file in files) {
      addTemplateFile(file);
    }
  }

  /// Factory which creates a [MasonGenerator] based on
  /// a local [MasonBundle].
  static Future<MasonGenerator> fromBundle(MasonBundle bundle) async {
    final bytes = await Isolate.run(
      () => utf8.encode(json.encode(bundle.toJson())),
    );
    final hash = sha1.convert(bytes).toString();
    final target = Directory(
      p.join(BricksJson.bundled.path, '${bundle.name}_${bundle.version}_$hash'),
    );
    if (!target.existsSync()) unpackBundle(bundle, target);
    return MasonGenerator._fromBrick(target.path);
  }

  /// Factory which creates a [MasonGenerator] based on
  /// a [GitPath] for a remote [BrickYaml] file.
  static Future<MasonGenerator> fromBrick(Brick brick) async {
    final path = brick.location.path != null
        ? brick.location.path!
        : (await BricksJson.temp().add(brick)).path;
    return MasonGenerator._fromBrick(path);
  }

  static Future<MasonGenerator> _fromBrick(String path) async {
    final file = File(p.join(path, BrickYaml.file));
    final brickYaml = checkedYamlDecode(
      file.readAsStringSync(),
      (m) => BrickYaml.fromJson(m!),
    ).copyWith(path: file.path);
    final brickDirectory = Directory(p.join(path, BrickYaml.dir));
    final brickFiles = brickDirectory.existsSync()
        ? brickDirectory
            .listSync(recursive: true)
            .whereType<File>()
            .map((file) {
            return () async {
              final resource = await _descriptorPool.request();
              try {
                final content = await File(file.path).readAsBytes();
                final relativePath = file.path.substring(
                  file.path.indexOf(BrickYaml.dir) + 1 + BrickYaml.dir.length,
                );
                return TemplateFile.fromBytes(relativePath, content);
              } on Exception {
                return null;
              } finally {
                resource.release();
              }
            }();
          })
        : <Future<TemplateFile?>>[];

    return MasonGenerator(
      brickYaml.name,
      brickYaml.description,
      vars: brickYaml.vars.keys.toList(),
      files: await Future.wait(brickFiles),
      hooks: await GeneratorHooks.fromBrickYaml(brickYaml),
    );
  }

  /// Optional list of variables which will be used to populate
  /// the corresponding mustache variables within the template.
  final List<String> vars;
}

/// The status of a generated file.
enum GeneratedFileStatus {
  /// File was newly created.
  created,

  /// File already existed and previous contents were overwritten.
  overwritten,

  /// File already existed and new content was appended.
  appended,

  /// File already existed and previous contents were left unmodified.
  skipped,

  /// File already exists and contents were identical.
  identical,
}

/// {@template generated_file}
/// A file generated by a [Generator] which includes the file [path]
/// and [status].
/// {@endtemplate}
class GeneratedFile {
  const GeneratedFile._({required this.path, required this.status});

  /// {@macro generated_file}
  const GeneratedFile.created({required String path})
      : this._(path: path, status: GeneratedFileStatus.created);

  /// {@macro generated_file}
  const GeneratedFile.overwritten({required String path})
      : this._(path: path, status: GeneratedFileStatus.overwritten);

  /// {@macro generated_file}
  const GeneratedFile.appended({required String path})
      : this._(path: path, status: GeneratedFileStatus.appended);

  /// {@macro generated_file}
  const GeneratedFile.skipped({required String path})
      : this._(path: path, status: GeneratedFileStatus.skipped);

  /// {@macro generated_file}
  const GeneratedFile.identical({required String path})
      : this._(path: path, status: GeneratedFileStatus.identical);

  /// The file path.
  final String path;

  /// The [status] of the generated file.
  final GeneratedFileStatus status;
}

/// {@template generator}
/// An abstract class which both defines a template generator and can generate a
/// user project based on this template.
/// {@endtemplate}
abstract class Generator implements Comparable<Generator> {
  /// {@macro generator}
  Generator(this.id, this.description, [this.hooks = const GeneratorHooks()]);

  /// Unique identifier for the generator.
  final String id;

  /// Description of the generator.
  final String description;

  /// Hooks associated with the generator.
  final GeneratorHooks hooks;

  /// List of [TemplateFile] which will be used to generate files.
  final List<TemplateFile> files = [];

  /// Map of partial files which will be used as includes.
  ///
  /// Contains a Map of partial file path to partial file content.
  final Map<String, List<int>> partials = {};

  /// Add a new template file.
  void addTemplateFile(TemplateFile? file) {
    if (file == null) return;
    _partialRegExp.hasMatch(file.path)
        ? partials.addAll({file.path: file.content})
        : files.add(file);
  }

  /// Generates files based on the provided [GeneratorTarget] and [vars].
  /// Returns a list of [GeneratedFile].
  Future<List<GeneratedFile>> generate(
    GeneratorTarget target, {
    Map<String, dynamic> vars = const <String, dynamic>{},
    FileConflictResolution? fileConflictResolution,
    Logger? logger,
  }) async {
    final overwriteRule = fileConflictResolution?.toOverwriteRule();
    final generatedFiles = <GeneratedFile>[];
    await Future.forEach<TemplateFile>(files, (TemplateFile file) async {
      final fileMatch = _fileRegExp.firstMatch(file.path);
      if (fileMatch != null) {
        final resultFile = await _fetch(vars[fileMatch[1]] as String);
        if (resultFile.path.isEmpty) return;
        final generatedFile = await target.createFile(
          p.basename(resultFile.path),
          resultFile.content,
          logger: logger,
          overwriteRule: overwriteRule,
        );
        generatedFiles.add(generatedFile);
      } else {
        final resultFiles = await _runSubstitutionAsync(
          file,
          Map<String, dynamic>.of(vars),
          Map<String, List<int>>.of(partials),
        );
        final root = RegExp(r'\w:\\|\w:\/');
        final separator = RegExp(r'\/|\\');
        final rootOrSeparator = RegExp('$root|$separator');
        final wasRoot = file.path.startsWith(rootOrSeparator);
        for (final file in resultFiles) {
          final isRoot = file.path.startsWith(rootOrSeparator);
          if (!wasRoot && isRoot) continue;
          if (file.path.isEmpty) continue;
          if (file.path.split(separator).contains('')) continue;
          final generatedFile = await target.createFile(
            file.path,
            file.content,
            logger: logger,
            overwriteRule: overwriteRule,
          );
          generatedFiles.add(generatedFile);
        }
      }
    });
    return generatedFiles;
  }

  @override
  int compareTo(Generator other) =>
      id.toLowerCase().compareTo(other.id.toLowerCase());

  @override
  String toString() => '[$id: $description]';

  Future<FileContents> _fetch(String path) async {
    final file = File(path);
    final isLocal = file.existsSync();
    if (isLocal) {
      final target = p.join(Directory.current.path, p.basename(file.path));
      final bytes = await file.readAsBytes();
      return FileContents(target, bytes);
    } else {
      final uri = Uri.parse(path);
      final target = p.join(Directory.current.path, p.basename(uri.path));
      final response = await http.Client().get(uri);
      return FileContents(target, response.bodyBytes);
    }
  }
}

/// File conflict resolution strategies used during
/// the generation process.
enum FileConflictResolution {
  /// Always prompt the user for each file conflict.
  prompt,

  /// Always overwrite conflicting files.
  overwrite,

  /// Always skip conflicting files.
  skip,

  /// Always append conflicting files.
  append,
}

/// The overwrite rule when generating code and a conflict occurs.
enum OverwriteRule {
  /// Always overwrite the existing file.
  alwaysOverwrite,

  /// Always skip overwriting the existing file.
  alwaysSkip,

  /// Always append the existing file.
  alwaysAppend,

  /// Overwrite one time.
  overwriteOnce,

  /// Do not overwrite one time.
  skipOnce,

  /// Append one time
  appendOnce,
}

/// {@template directory_generator_target}
/// A [GeneratorTarget] based on a provided [Directory].
/// {@endtemplate}
class DirectoryGeneratorTarget extends GeneratorTarget {
  /// {@macro directory_generator_target}
  DirectoryGeneratorTarget(this.dir) {
    dir.createSync(recursive: true);
  }

  /// The target [Directory].
  final Directory dir;

  OverwriteRule? _overwriteRule;

  @override
  Future<GeneratedFile> createFile(
    String path,
    List<int> contents, {
    Logger? logger,
    OverwriteRule? overwriteRule,
  }) async {
    _overwriteRule ??= overwriteRule;
    final file = File(p.join(dir.path, path));
    final filePath = darkGray.wrap(p.relative(file.path));
    final fileExists = file.existsSync();

    if (!fileExists) {
      await file
          .create(recursive: true)
          .then<File>((_) => file.writeAsBytes(contents))
          .whenComplete(
            () => logger?.delayed('  ${green.wrap('created')} $filePath'),
          );
      return GeneratedFile.created(path: file.path);
    }

    final existingContents = file.readAsBytesSync();

    if (const ListEquality<int>().equals(existingContents, contents)) {
      logger?.delayed('  ${cyan.wrap('identical')} $filePath');
      return GeneratedFile.identical(path: file.path);
    }

    final shouldPrompt = logger != null &&
        (_overwriteRule != OverwriteRule.alwaysOverwrite &&
            _overwriteRule != OverwriteRule.alwaysSkip &&
            _overwriteRule != OverwriteRule.alwaysAppend);

    if (shouldPrompt) {
      logger.info('${red.wrap(styleBold.wrap('conflict'))} $filePath');
      _overwriteRule = logger
          .prompt(
            lightYellow.wrap('Overwrite ${p.basename(file.path)}? (Yyna)'),
          )
          .toOverwriteRule();
    }

    switch (_overwriteRule) {
      case OverwriteRule.alwaysSkip:
      case OverwriteRule.skipOnce:
        logger?.delayed('  ${yellow.wrap('skipped')} $filePath');
        return GeneratedFile.skipped(path: file.path);
      case OverwriteRule.alwaysOverwrite:
      case OverwriteRule.overwriteOnce:
      case OverwriteRule.appendOnce:
      case OverwriteRule.alwaysAppend:
      case null:
        final shouldAppend = _overwriteRule == OverwriteRule.appendOnce ||
            _overwriteRule == OverwriteRule.alwaysAppend;
        await file
            .create(recursive: true)
            .then<File>(
              (_) => file.writeAsBytes(
                contents,
                mode: shouldAppend ? FileMode.append : FileMode.write,
              ),
            )
            .whenComplete(
              () => shouldAppend
                  ? logger?.delayed('  ${lightBlue.wrap('modified')} $filePath')
                  : logger?.delayed('  ${green.wrap('created')} $filePath'),
            );

        return shouldAppend
            ? GeneratedFile.appended(path: file.path)
            : GeneratedFile.overwritten(path: file.path);
    }
  }
}

/// A target for a [Generator].
/// This class knows how to create files given a path and contents.
///
/// See also:
///
/// * [DirectoryGeneratorTarget], a [GeneratorTarget] based on a provided
/// [Directory].
// ignore: one_member_abstracts
abstract class GeneratorTarget {
  /// Create a file at the given path with the given contents.
  Future<GeneratedFile> createFile(
    String path,
    List<int> contents, {
    Logger? logger,
    OverwriteRule? overwriteRule,
  });
}

/// {@template template_file}
/// This class represents a file in a generator template.
/// The contents should be text and may contain mustache
/// variables that can be substituted (`{{myVar}}`).
/// {@endtemplate}
class TemplateFile {
  /// {@macro template_file}
  TemplateFile(String path, String content)
      : this.fromBytes(path, utf8.encode(content));

  /// {@macro template_file}
  TemplateFile.fromBytes(this.path, this.content);

  /// The template file path.
  final String path;

  /// The template file content.
  final List<int> content;

  /// Performs a substitution on the [path] based on the incoming [parameters].
  Set<FileContents> runSubstitution(
    Map<String, dynamic> parameters,
    Map<String, List<int>> partials,
  ) {
    var filePath = path.replaceAll(r'\', '/');
    if (_loopRegExp().hasMatch(filePath)) {
      final matches = _loopKeyRegExp.allMatches(filePath);

      for (final match in matches) {
        final key = match.group(1);
        if (key == null || _lambdas.hasMatch(key)) continue;
        if (parameters[key] is! Iterable) continue;
        final value = _loopValueRegExp(key).firstMatch(filePath)![1];
        if (value == '.') {
          filePath = filePath.replaceFirst(_loopRegExp(key), '{{$key}}');
        } else {
          final inner = _loopInnerRegExp(key).firstMatch(filePath)![1];
          final target = inner!.replaceFirst(
            _loopValueReplaceRegExp,
            '{{$key.$value}}',
          );
          filePath = filePath.replaceFirst(_loopRegExp(key), target);
        }
      }

      final fileContents = <FileContents>{};
      final parameterKeys =
          parameters.keys.where((key) => parameters[key] is List).toList();
      final permutations = _Permutations<dynamic>(
        [
          ...parameters.entries
              .where((entry) => entry.value is List)
              .map((entry) => entry.value as List),
        ],
      ).generate();
      for (final permutation in permutations) {
        final param = Map<String, dynamic>.of(parameters);
        for (var i = 0; i < permutation.length; i++) {
          param.addAll(<String, dynamic>{parameterKeys[i]: permutation[i]});
        }
        final newPath = filePath.render(param);
        final newContents = TemplateFile(
          newPath,
          utf8.decode(content),
        )._createContent(parameters..addAll(param), partials);
        fileContents.add(FileContents(newPath, newContents));
      }

      return fileContents;
    } else {
      final newPath = filePath.render(parameters);
      final newContents = _createContent(parameters, partials);
      return {FileContents(newPath, newContents)};
    }
  }

  List<int> _createContent(
    Map<String, dynamic> vars,
    Map<String, List<int>> partials,
  ) {
    try {
      final decoded = utf8.decode(content);
      if (!decoded.contains(_delimiterRegExp)) return content;
      final rendered = decoded.render(vars, partials);
      return utf8.encode(rendered);
    } on Exception {
      return content;
    }
  }
}

/// {@template file_contents}
/// A representation of the contents for a specific file.
/// {@endtemplate}
@immutable
class FileContents {
  /// {@macro file_contents}
  const FileContents(this.path, this.content);

  /// The file path.
  final String path;

  /// The contents of the file.
  final List<int> content;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    final listEquals = const DeepCollectionEquality().equals;

    return other is FileContents &&
        other.path == path &&
        listEquals(other.content, content);
  }

  @override
  int get hashCode => path.hashCode ^ content.length.hashCode;
}

class _Permutations<T> {
  _Permutations(this.elements);
  final List<List<T>> elements;

  List<List<T>> generate() {
    final perms = <List<T>>[];
    _generatePermutations(elements, perms, 0, []);
    return perms;
  }

  void _generatePermutations(
    List<List<T>> lists,
    List<List<T>> result,
    int depth,
    List<T> current,
  ) {
    if (depth == lists.length) {
      result.add(current);
      return;
    }

    for (var i = 0; i < lists[depth].length; i++) {
      _generatePermutations(
        lists,
        result,
        depth + 1,
        [...current, lists[depth][i]],
      );
    }
  }
}

Future<Set<FileContents>> _runSubstitutionAsync(
  TemplateFile file,
  Map<String, dynamic> vars,
  Map<String, List<int>> partials,
) async {
  return Isolate.run(() => file.runSubstitution(vars, partials));
}

extension on FileConflictResolution {
  OverwriteRule? toOverwriteRule() {
    switch (this) {
      case FileConflictResolution.overwrite:
        return OverwriteRule.alwaysOverwrite;
      case FileConflictResolution.skip:
        return OverwriteRule.alwaysSkip;
      case FileConflictResolution.append:
        return OverwriteRule.alwaysAppend;
      case FileConflictResolution.prompt:
        return null;
    }
  }
}

extension on String {
  OverwriteRule toOverwriteRule() {
    switch (this) {
      case 'n':
        return OverwriteRule.skipOnce;
      case 'a':
        return OverwriteRule.appendOnce;
      case 'Y':
        return OverwriteRule.alwaysOverwrite;
      case 'y':
      default:
        return OverwriteRule.overwriteOnce;
    }
  }
}

extension on HookFile {
  Directory get directory => File(path).parent;

  Directory get buildDirectory {
    return Directory(
      p.join(
        directory.path,
        'build',
        'hooks',
        p.basenameWithoutExtension(path),
      ),
    );
  }

  File intermediate(String checksum) {
    return File(
      p.join(
        buildDirectory.path,
        '${p.basenameWithoutExtension(path)}_$checksum.dart',
      ),
    );
  }

  File module(String checksum) {
    final extension = _isAotCompiled ? 'aot' : 'dill';
    return File(
      p.join(
        buildDirectory.path,
        '${p.basenameWithoutExtension(path)}_$checksum.$extension',
      ),
    );
  }
}
