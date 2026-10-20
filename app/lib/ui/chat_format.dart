import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/chat_models.dart';
import '../data/voice.dart';
import '../l10n/app_localizations.dart';
import 'widgets.dart';

/// Western digits everywhere, matching the counts elsewhere in the app.
String westernDigits(String text) => text.replaceAllMapped(
  RegExp('[٠-٩]'),
  (m) => '${m[0]!.codeUnitAt(0) - 0x0660}',
);

String _locale(BuildContext context) =>
    Localizations.localeOf(context).languageCode;

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// 10:45 ص
String clockTime(BuildContext context, DateTime time) => westernDigits(
  DateFormat('h:mm a', _locale(context)).format(time.toLocal()),
);

/// For the chat list: the time today, "yesterday", a weekday, or a date.
/// Lower-cases and folds Arabic letter variants and marks, like the
/// server's search, so a name typed either way matches.
String normalizeSearch(String text) {
  const from = 'أإآٱىةؤئیک';
  const to = 'اااايهءءيك';
  final out = StringBuffer();
  for (final rune in text.toLowerCase().runes) {
    final c = String.fromCharCode(rune);
    // Tatweel and the harakat.
    if (rune == 0x0640 || (rune >= 0x064B && rune <= 0x0670)) continue;
    final i = from.indexOf(c);
    out.write(i < 0 ? c : to[i]);
  }
  return out.toString().trim();
}

String listTime(BuildContext context, DateTime time) {
  final local = time.toLocal();
  final now = DateTime.now();
  if (_sameDay(local, now)) return clockTime(context, local);
  if (_sameDay(local, now.subtract(const Duration(days: 1)))) {
    return context.l10n.yesterday;
  }
  final locale = _locale(context);
  if (now.difference(local).inDays < 7) {
    return DateFormat('EEEE', locale).format(local);
  }
  return westernDigits(DateFormat('d/M/yyyy', locale).format(local));
}

/// For the line between days in a chat.
String dayLabel(BuildContext context, DateTime time) {
  final local = time.toLocal();
  final now = DateTime.now();
  if (_sameDay(local, now)) return context.l10n.today;
  if (_sameDay(local, now.subtract(const Duration(days: 1)))) {
    return context.l10n.yesterday;
  }
  final pattern = local.year == now.year ? 'EEEE d MMMM' : 'd MMMM yyyy';
  return westernDigits(DateFormat(pattern, _locale(context)).format(local));
}

/// A day and time in full, for lists of files: الثلاثاء 20 أكتوبر، 10:30 ص
String fullTime(BuildContext context, DateTime time) {
  final local = time.toLocal();
  final pattern = local.year == DateTime.now().year
      ? 'EEEE d MMMM'
      : 'EEEE d MMMM yyyy';
  final day = DateFormat(pattern, _locale(context)).format(local);
  final comma = _locale(context) == 'ar' ? '،' : ',';
  return westernDigits('$day$comma ${clockTime(context, local)}');
}

/// 13 أكتوبر
String dayMonth(BuildContext context, DateTime time) =>
    westernDigits(DateFormat('d MMMM', _locale(context)).format(time));

/// أكتوبر 2026
String monthLabel(BuildContext context, DateTime time) => westernDigits(
  DateFormat('MMMM yyyy', _locale(context)).format(time.toLocal()),
);

String fileSize(AppLocalizations l, int bytes) {
  if (bytes >= 1024 * 1024) {
    final mb = bytes / (1024 * 1024);
    return l.sizeMb(mb >= 10 ? mb.toStringAsFixed(0) : mb.toStringAsFixed(1));
  }
  return l.sizeKb(((bytes / 1024).ceil()).toString());
}

/// How a file is named in previews: voice messages by what they are.
String fileLabel(AppLocalizations l, String name) {
  final length = voiceLength(name);
  if (length == null) return name;
  final s = (length.inSeconds % 60).toString().padLeft(2, '0');
  return '${l.voiceMessage} (${length.inMinutes}:$s)';
}

/// What a chat-list row says about its last message.
String preview(AppLocalizations l, Conversation c, String? me) {
  if (c.lastAt == null) return l.noMessagesYet;
  final String text;
  if (c.lastDeleted) {
    text = l.previewDeleted;
  } else if (c.lastBody != null && c.lastBody!.isNotEmpty) {
    text = c.lastBody!;
  } else {
    text = fileLabel(l, c.lastFileName ?? '');
  }
  if (c.lastSenderId == me) return l.previewFrom(l.you, text);
  if (c.isProject) {
    return l.previewFrom(firstName(c.lastSenderName ?? ''), text);
  }
  return text;
}

String firstName(String name) {
  final parts = name.trim().split(RegExp(r'\s+'));
  return parts.isEmpty ? name : parts.first;
}

/// A colored square with the file's type, as in the design.
class FileBadge extends StatelessWidget {
  const FileBadge({super.key, required this.name, this.size = 40});

  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final dot = name.lastIndexOf('.');
    final ext = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
    final (label, color) = switch (ext) {
      'pdf' => ('PDF', const Color(0xFFB4441C)),
      'xls' || 'xlsx' || 'csv' => ('XLS', const Color(0xFF1D6B42)),
      'doc' || 'docx' => ('DOC', const Color(0xFF2F5BD3)),
      'ppt' || 'pptx' => ('PPT', const Color(0xFFC2660A)),
      'jpg' ||
      'jpeg' ||
      'png' ||
      'gif' ||
      'webp' ||
      'heic' => ('IMG', const Color(0xFF0F6E6A)),
      'zip' || 'rar' => ('ZIP', const Color(0xFF5B6876)),
      'dwg' || 'dxf' => ('DWG', const Color(0xFF7247B8)),
      _ => (
        ext.isEmpty || ext.length > 4 ? 'FILE' : ext.toUpperCase(),
        const Color(0xFF5B6876),
      ),
    };
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(size * 0.2),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: Colors.white,
          fontSize: size * 0.27,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// Opens a stored file in the phone's viewer or browser.
Future<void> openLink(BuildContext context, String url) async {
  final l = context.l10n;
  final messenger = ScaffoldMessenger.of(context);
  final ok =
      url.isNotEmpty &&
      await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      ).catchError((Object _) => false);
  if (!ok) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(l.cantOpenFile)));
  }
}

final _link = RegExp(r'https?://[^\s<>"]+', caseSensitive: false);

/// The web links in [text], without trailing punctuation.
List<String> linksIn(String text) => [
  for (final m in _link.allMatches(text))
    m[0]!.replaceFirst(RegExp(r'[.,;:!?)\]،؛]+$'), ''),
];

/// The most characters one message holds (the database allows no more).
const maxMessageLength = 4000;

/// [text] in pieces of at most [max] characters, cut at a line break or a
/// space where there is one, so words stay whole.
List<String> splitLongText(String text, int max) {
  final runes = text.runes.toList();
  final parts = <String>[];
  var start = 0;
  while (start < runes.length) {
    var end = start + max;
    if (end >= runes.length) {
      end = runes.length;
    } else {
      // Look back over the last quarter of the piece for a good place.
      final floor = start + max * 3 ~/ 4;
      var cut = -1;
      for (var i = end; i > floor; i--) {
        if (runes[i - 1] == 0x0A) {
          cut = i;
          break;
        }
        if (cut == -1 && runes[i - 1] == 0x20) cut = i;
      }
      if (cut != -1) end = cut;
    }
    final part = String.fromCharCodes(runes, start, end).trim();
    if (part.isNotEmpty) parts.add(part);
    start = end;
  }
  return parts;
}
