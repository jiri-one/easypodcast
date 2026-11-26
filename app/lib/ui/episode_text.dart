import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../core/downloads.dart';
import '../core/models.dart';
import '../l10n/app_localizations.dart';
import 'eink_widgets.dart';

const metadataSeparator = ' · ';

Duration? episodeDuration(Episode episode, EpisodeState state) {
  final measured = state.durationMs;
  if (measured != null && measured > 0) return Duration(milliseconds: measured);
  final feed = episode.durationS;
  return feed == null || feed <= 0 ? null : Duration(seconds: feed);
}

String positionText(Duration position) {
  final minutes = position.inMinutes.remainder(60);
  final seconds = position.inSeconds.remainder(60).toString().padLeft(2, '0');
  if (position.inHours == 0) return '$minutes:$seconds';
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
  if (duration == null) {
    return position == Duration.zero
        ? strings.stateInProgress
        : strings.elapsed(strings.minutes(position.inMinutes));
  }
  final remaining = minuteLength(strings, duration - position);
  if (!showTotal) return strings.remaining(remaining);
  final totalMinutes = durationMinutes(duration);
  final total = strings.localeName == 'cs'
      ? '$totalMinutes'
      : strings.minutes(totalMinutes);
  return strings.remainingOfTotal(remaining, total);
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
  return strings.olderDay(
    DateFormat.E(strings.localeName).format(day),
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

String? downloadStateText(
  AppLocalizations strings,
  DownloadStatus status, {
  required bool waitingForWifi,
}) => switch (status) {
  DownloadStatus.none => null,
  DownloadStatus.queued =>
    waitingForWifi
        ? strings.stateWaitingForWifi
        : strings.stateWaitingForDownload,
  DownloadStatus.running => strings.stateDownloading,
  DownloadStatus.done => strings.stateDownloaded,
  DownloadStatus.failed => null,
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
