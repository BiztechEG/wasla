import 'dart:async';
import 'dart:js_interop';
import 'dart:ui' show Offset;

import 'package:web/web.dart' as web;

import 'chat_models.dart';
import 'drops.dart';
import 'picker.dart';

FileDrops platformFileDrops() => _WebDrops.instance;

/// Follows the browser window's drag events. Files dropped anywhere are
/// kept from replacing the app with the file itself.
class _WebDrops implements FileDrops {
  _WebDrops._() {
    web.window
      ..addEventListener('dragenter', _enter.toJS)
      ..addEventListener('dragover', _over.toJS)
      ..addEventListener('dragleave', _leave.toJS)
      ..addEventListener('drop', _drop.toJS);
  }

  static final instance = _WebDrops._();

  final _hover = StreamController<Offset?>.broadcast();
  final _dropped = StreamController<FileDrop>.broadcast();

  /// Entering and leaving the page's inner elements fire in pairs.
  var _depth = 0;

  @override
  Stream<Offset?> get hover => _hover.stream;

  @override
  Stream<FileDrop> get dropped => _dropped.stream;

  static bool _hasFiles(web.DragEvent e) {
    final types = e.dataTransfer?.types.toDart ?? const <JSString>[];
    return types.any((t) => t.toDart == 'Files');
  }

  static Offset _at(web.DragEvent e) =>
      Offset(e.clientX.toDouble(), e.clientY.toDouble());

  void _enter(web.DragEvent e) {
    if (!_hasFiles(e)) return;
    e.preventDefault();
    _depth++;
    _hover.add(_at(e));
  }

  void _over(web.DragEvent e) {
    if (!_hasFiles(e)) return;
    e.preventDefault();
    e.dataTransfer?.dropEffect = 'copy';
    _hover.add(_at(e));
  }

  void _leave(web.DragEvent e) {
    if (!_hasFiles(e)) return;
    if (--_depth <= 0) {
      _depth = 0;
      _hover.add(null);
    }
  }

  void _drop(web.DragEvent e) {
    if (!_hasFiles(e)) return;
    e.preventDefault();
    _depth = 0;
    _hover.add(null);
    final list = e.dataTransfer?.files;
    if (list == null) return;
    final files = [for (var i = 0; i < list.length; i++) ?list.item(i)];
    _read(_at(e), files);
  }

  Future<void> _read(Offset at, List<web.File> files) async {
    final read = <Upload>[];
    var tooLarge = 0;
    for (final f in files.take(maxFilesPerPick + 1)) {
      if (f.size > maxUploadBytes) {
        tooLarge++;
        continue;
      }
      try {
        final buffer = await f.arrayBuffer().toDart;
        read.add(
          Upload(
            bytes: buffer.toDart.asUint8List(),
            name: f.name,
            mime: f.type.isEmpty ? mimeFor(f.name) : f.type,
          ),
        );
      } catch (_) {
        // A folder, or a file that could not be read: left out.
      }
    }
    _dropped.add((at: at, files: read, tooLarge: tooLarge));
  }
}
