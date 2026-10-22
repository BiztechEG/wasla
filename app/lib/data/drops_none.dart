import 'dart:ui' show Offset;

import 'drops.dart';

/// Phones take files from the attach sheet only.
FileDrops platformFileDrops() => const _NoDrops();

class _NoDrops implements FileDrops {
  const _NoDrops();

  @override
  Stream<Offset?> get hover => const Stream.empty();

  @override
  Stream<FileDrop> get dropped => const Stream.empty();
}
