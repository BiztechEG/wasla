import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../data/chat_models.dart';
import '../data/picker.dart';
import '../state/chat_providers.dart';
import 'chat_format.dart';
import 'widgets.dart';

/// Asks where to pick from (gallery, camera or files) and returns the pick.
Future<Upload?> pickUpload(BuildContext context, WidgetRef ref) async {
  final l = context.l10n;
  final source = await showModalBottomSheet<String>(
    context: context,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: Text(l.attachPhoto),
            onTap: () => Navigator.pop(context, 'gallery'),
          ),
          ListTile(
            leading: const Icon(Icons.photo_camera_outlined),
            title: Text(l.attachCamera),
            onTap: () => Navigator.pop(context, 'camera'),
          ),
          ListTile(
            leading: const Icon(Icons.video_library_outlined),
            title: Text(l.attachVideo),
            onTap: () => Navigator.pop(context, 'video'),
          ),
          ListTile(
            leading: const Icon(Icons.videocam_outlined),
            title: Text(l.attachRecordVideo),
            onTap: () => Navigator.pop(context, 'record'),
          ),
          ListTile(
            leading: const Icon(Icons.insert_drive_file_outlined),
            title: Text(l.attachFile),
            onTap: () => Navigator.pop(context, 'file'),
          ),
        ],
      ),
    ),
  );
  if (source == null || !context.mounted) return null;
  final picker = ref.read(pickerProvider);
  try {
    return switch (source) {
      'file' => await picker.pickFile(),
      'video' => await picker.pickVideo(camera: false),
      'record' => await picker.pickVideo(camera: true),
      _ => await picker.pickImage(camera: source == 'camera'),
    };
  } on FileTooLarge {
    if (context.mounted) showMessage(context, l.fileTooLarge);
  } catch (e) {
    if (context.mounted) showMessage(context, errorText(l, e));
  }
  return null;
}

/// Photos and videos open full screen; anything else opens in the phone's
/// viewer.
Future<void> openFile(
  BuildContext context,
  WidgetRef ref,
  ChatFile file,
) async {
  if (file.isImage) {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => ImageViewerScreen(file: file)),
    );
    return;
  }
  if (file.isVideo) {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => VideoViewerScreen(file: file)),
    );
    return;
  }
  try {
    final url = await ref.read(fileUrlProvider(file.path).future);
    if (context.mounted) await openLink(context, url);
  } catch (e) {
    if (context.mounted) showMessage(context, errorText(context.l10n, e));
  }
}

/// A stored photo, loaded through a short-lived link.
class StoredImage extends ConsumerWidget {
  const StoredImage({
    super.key,
    required this.path,
    this.fit = BoxFit.cover,
    this.placeholderHeight = 180,
  });

  final String path;
  final BoxFit fit;
  final double placeholderHeight;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    Widget box(IconData icon) => Container(
      height: placeholderHeight,
      color: scheme.surfaceContainerHighest,
      alignment: Alignment.center,
      child: Icon(icon, color: scheme.onSurfaceVariant),
    );
    // Offline or an expired link: tap to load it again.
    final failed = GestureDetector(
      onTap: () => ref.invalidate(fileUrlProvider(path)),
      child: box(Icons.refresh),
    );
    final link = ref.watch(fileUrlProvider(path));
    if (link.hasError) return failed;
    final url = link.value;
    if (url == null || url.isEmpty) return box(Icons.image_outlined);
    return Image.network(
      url,
      fit: fit,
      loadingBuilder: (context, child, progress) =>
          progress == null ? child : box(Icons.image_outlined),
      errorBuilder: (_, _, _) => failed,
    );
  }
}

class ImageViewerScreen extends ConsumerWidget {
  const ImageViewerScreen({super.key, required this.file});

  final ChatFile file;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    return Theme(
      data: ThemeData.dark(),
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          title: Text(file.name, overflow: TextOverflow.ellipsis),
          actions: [
            IconButton(
              tooltip: l.openFile,
              icon: const Icon(Icons.open_in_new),
              onPressed: () async {
                final url = await ref.read(fileUrlProvider(file.path).future);
                if (context.mounted) await openLink(context, url);
              },
            ),
          ],
        ),
        body: Center(
          child: InteractiveViewer(
            maxScale: 5,
            child: StoredImage(path: file.path, fit: BoxFit.contain),
          ),
        ),
      ),
    );
  }
}

/// A file as a row: type badge, name, and a line of detail.
class FileRow extends StatelessWidget {
  const FileRow({
    super.key,
    required this.file,
    required this.detail,
    this.dense = false,
  });

  final ChatFile file;
  final String detail;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        FileBadge(name: file.name, size: dense ? 36 : 40),
        const SizedBox(width: 10),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                file.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                detail,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// A photo or video inside a chat bubble, in a bounded frame like WhatsApp:
/// a set width, with tall and wide pictures cropped to sensible proportions.
/// Tapping it opens the full picture.
class ChatMedia extends StatelessWidget {
  const ChatMedia({
    super.key,
    required this.file,
    required this.width,
    required this.onTap,
  });

  final ChatFile file;
  final double width;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: file.isVideo
            ? _VideoTile(file: file, width: width)
            : _FramedPhoto(path: file.path, width: width),
      ),
    );
  }
}

/// Height over width, kept between a slightly tall portrait and a wide
/// landscape so no picture takes over the chat.
const _tallest = 4 / 3;
const _widest = 9 / 16;

/// What each photo's proportions turned out to be, so a bubble keeps its
/// size when it scrolls back into view.
final _shapes = <String, double>{};

class _FramedPhoto extends ConsumerStatefulWidget {
  const _FramedPhoto({required this.path, required this.width});

  final String path;
  final double width;

  @override
  ConsumerState<_FramedPhoto> createState() => _FramedPhotoState();
}

class _FramedPhotoState extends ConsumerState<_FramedPhoto> {
  ImageStream? _stream;
  ImageStreamListener? _listener;
  String? _url;

  @override
  void dispose() {
    _stopListening();
    super.dispose();
  }

  void _stopListening() {
    if (_listener != null) _stream?.removeListener(_listener!);
    _stream = null;
    _listener = null;
  }

  /// Learns the photo's proportions once it has loaded.
  void _measure(ImageProvider image) {
    if (_shapes.containsKey(widget.path)) return;
    _stopListening();
    final stream = image.resolve(createLocalImageConfiguration(context));
    final listener = ImageStreamListener((info, _) {
      final w = info.image.width, h = info.image.height;
      if (w > 0 && h > 0) {
        final shape = (h / w).clamp(_widest, _tallest);
        if (mounted) setState(() => _shapes[widget.path] = shape);
      }
      _stopListening();
    }, onError: (_, _) => _stopListening());
    stream.addListener(listener);
    _stream = stream;
    _listener = listener;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final height = widget.width * (_shapes[widget.path] ?? 3 / 4);
    Widget box(IconData icon) => Container(
      width: widget.width,
      height: height,
      color: scheme.surfaceContainerHighest,
      alignment: Alignment.center,
      child: Icon(icon, color: scheme.onSurfaceVariant),
    );
    // Offline or an expired link: tap to load it again.
    final failed = GestureDetector(
      onTap: () => ref.invalidate(fileUrlProvider(widget.path)),
      child: box(Icons.refresh),
    );
    final link = ref.watch(fileUrlProvider(widget.path));
    if (link.hasError) return failed;
    final url = link.value;
    if (url == null || url.isEmpty) return box(Icons.image_outlined);
    final image = NetworkImage(url);
    if (url != _url) {
      _url = url;
      // A cached photo reports its size at once; wait until after this build.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _measure(image);
      });
    }
    return SizedBox(
      width: widget.width,
      height: height,
      child: Image(
        image: image,
        fit: BoxFit.cover,
        loadingBuilder: (context, child, progress) =>
            progress == null ? child : box(Icons.image_outlined),
        errorBuilder: (_, _, _) => failed,
      ),
    );
  }
}

class _VideoTile extends StatelessWidget {
  const _VideoTile({required this.file, required this.width});

  final ChatFile file;
  final double width;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: width * 9 / 16,
      color: const Color(0xFF1B2422),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.45),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.play_arrow, color: Colors.white, size: 34),
          ),
          PositionedDirectional(
            start: 8,
            bottom: 6,
            end: 8,
            child: Row(
              children: [
                const Icon(Icons.videocam, color: Colors.white70, size: 16),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    fileSize(context.l10n, file.size),
                    maxLines: 1,
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class VideoViewerScreen extends ConsumerStatefulWidget {
  const VideoViewerScreen({super.key, required this.file});

  final ChatFile file;

  @override
  ConsumerState<VideoViewerScreen> createState() => _VideoViewerScreenState();
}

class _VideoViewerScreenState extends ConsumerState<VideoViewerScreen> {
  VideoPlayerController? _player;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      final url = await ref.read(fileUrlProvider(widget.file.path).future);
      final player = VideoPlayerController.networkUrl(Uri.parse(url));
      if (!mounted) return;
      setState(() => _player = player);
      await player.initialize();
      if (!mounted) return;
      await player.play();
      setState(() {});
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    _player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final player = _player;
    final ready = player != null && player.value.isInitialized;
    return Theme(
      data: ThemeData.dark(),
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          title: Text(widget.file.name, overflow: TextOverflow.ellipsis),
          actions: [
            IconButton(
              tooltip: l.openFile,
              icon: const Icon(Icons.open_in_new),
              onPressed: () async {
                final url = await ref.read(
                  fileUrlProvider(widget.file.path).future,
                );
                if (context.mounted) await openLink(context, url);
              },
            ),
          ],
        ),
        body: Center(
          child: _failed
              ? Text(l.videoFailed, style: const TextStyle(color: Colors.white))
              : !ready
              ? const CircularProgressIndicator()
              : _Playback(player: player),
        ),
      ),
    );
  }
}

class _Playback extends StatelessWidget {
  const _Playback({required this.player});

  final VideoPlayerController player;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: player,
      builder: (context, value, _) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: GestureDetector(
              onTap: () => value.isPlaying ? player.pause() : player.play(),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  AspectRatio(
                    aspectRatio: value.aspectRatio,
                    child: VideoPlayer(player),
                  ),
                  if (!value.isPlaying)
                    const Icon(
                      Icons.play_circle_fill,
                      color: Colors.white70,
                      size: 72,
                    ),
                ],
              ),
            ),
          ),
          Directionality(
            textDirection: TextDirection.ltr,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Row(
                children: [
                  Text(
                    _clock(value.position),
                    style: const TextStyle(color: Colors.white70),
                  ),
                  Expanded(
                    child: VideoProgressIndicator(
                      player,
                      allowScrubbing: true,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                    ),
                  ),
                  Text(
                    _clock(value.duration),
                    style: const TextStyle(color: Colors.white70),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _clock(Duration d) {
  final m = d.inMinutes;
  final s = (d.inSeconds % 60).toString().padLeft(2, '0');
  return '$m:$s';
}
