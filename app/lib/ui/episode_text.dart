import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../core/downloads.dart';
import '../l10n/app_localizations.dart';
import 'eink_widgets.dart';

const metadataSeparator = ' · ';

String positionText(Duration position, {bool padMinutes = false}) {
  final minutes = position.inMinutes.remainder(60);
  final seconds = position.inSeconds.remainder(60).toString().padLeft(2, '0');
  if (position.inHours == 0) {
    final minuteText = padMinutes
        ? minutes.toString().padLeft(2, '0')
        : minutes;
    return '$minuteText:$seconds';
  }
  return '${position.inHours}:${minutes.toString().padLeft(2, '0')}:$seconds';
}

int durationMinutes(Duration duration) =>
    duration.isNegative ? 0 : (duration.inMilliseconds + 59999) ~/ 60000;

String minuteLength(AppLocalizations strings, Duration duration) {
  final minutes = durationMinutes(duration);
  if (minutes < 60) return strings.minutes(minutes);
  final hours = minutes ~/ 60;
  final rest = minutes % 60;
  return rest == 0 ? strings.hours(hours) : strings.hoursMinutes(hours, rest);
}

String playbackTime(
  AppLocalizations strings,
  Duration position,
  Duration? duration, {
  bool showTotal = false,
}) {
  if (duration == null || position > duration) {
    return position == Duration.zero
        ? strings.stateInProgress
        : strings.elapsed(
            minuteLength(strings, Duration(minutes: position.inMinutes)),
          );
  }
  final remaining = minuteLength(strings, duration - position);
  if (!showTotal) return strings.remaining(remaining);
  return strings.remainingOfTotal(remaining, minuteLength(strings, duration));
}

String speedText(AppLocalizations strings, double speed) =>
    strings.speedValue(NumberFormat('0.0#', strings.localeName).format(speed));

String clockText(AppLocalizations strings, DateTime time) =>
    DateFormat('H:mm', strings.localeName).format(time.toLocal());

String dateText(AppLocalizations strings, DateTime time) {
  final date = time.toLocal();
  return strings.localeName == 'cs'
      ? strings.shortDate(date.day, date.month)
      : DateFormat.MMMd(strings.localeName).format(date);
}

String dayGroup(AppLocalizations strings, DateTime? time) {
  if (time == null) return strings.noDate;
  final now = DateTime.now();
  final day = DateUtils.dateOnly(time.toLocal());
  if (day == DateUtils.dateOnly(now)) return strings.today;
  if (day == DateTime(now.year, now.month, now.day - 1)) {
    return strings.yesterday;
  }
  final weekday = DateFormat.E(strings.localeName).format(day);
  return strings.olderDay(
    weekday[0].toUpperCase() + weekday.substring(1),
    dateText(strings, day),
  );
}

String bytesText(AppLocalizations strings, int bytes) {
  if (bytes == 0) return strings.megabytes('0');
  final number = NumberFormat('0.#', strings.localeName);
  if (bytes >= 1000000000) {
    return strings.gigabytes(number.format(bytes / 1000000000));
  }
  if (bytes >= 1000000) {
    return strings.megabytes(number.format(bytes / 1000000));
  }
  return strings.kilobytes(number.format(bytes / 1000));
}

String? downloadStateText(AppLocalizations strings, DownloadDisplay download) =>
    switch (download.status) {
      DownloadStatus.queued =>
        download.waitingForWifi
            ? strings.stateWaitingForWifi
            : strings.stateWaitingForDownload,
      DownloadStatus.running => strings.stateDownloading(download.percent),
      _ => null,
    };

Text metadataLine(String first, Iterable<String> rest, {bool bold = false}) =>
    Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: first,
            style: bold ? const TextStyle(fontWeight: FontWeight.w700) : null,
          ),
          for (final text in rest) TextSpan(text: '$metadataSeparator$text'),
        ],
      ),
      style: detailStyle,
    );
