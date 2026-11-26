// ignore_for_file: deprecated_member_use

// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'EasyPodcast';

  @override
  String get inProgress => 'In progress';

  @override
  String get queue => 'Queue';

  @override
  String get newEpisodes => 'New episodes';

  @override
  String get podcasts => 'Podcasts';

  @override
  String get downloads => 'Downloads';

  @override
  String get settings => 'Settings';

  @override
  String get changeList => 'Switch list';

  @override
  String get player => 'Player';

  @override
  String get seekPlayback => 'Playback position';

  @override
  String get seekUnavailable => 'The playback position can’t be changed yet.';

  @override
  String nextInQueue(String title) {
    return 'Next in queue: $title';
  }

  @override
  String get play => 'Play';

  @override
  String get pause => 'Pause';

  @override
  String get stop => 'Stop';

  @override
  String get checkingPosition => 'Checking position…';

  @override
  String get loadingPlayback => 'Loading…';

  @override
  String get playbackFailed => 'Couldn\'t play the episode. Try again.';

  @override
  String get playbackOffline => 'Only downloaded episodes can play offline.';

  @override
  String get playbackLoadFailed => 'Couldn’t load the episode.';

  @override
  String get playbackStreamFailed => 'Playback was interrupted.';

  @override
  String get playbackSeekFailed => 'Couldn’t change the playback position.';

  @override
  String get playbackFocusUnavailable => 'Another app is using audio.';

  @override
  String get noPlayback => 'Nothing is playing yet.';

  @override
  String get stateNew => 'new';

  @override
  String get statePlaying => 'playing';

  @override
  String get stateInProgress => 'in progress';

  @override
  String get statePlayed => 'played';

  @override
  String get stateDismissed => 'dismissed';

  @override
  String get stateDownloaded => 'downloaded';

  @override
  String get stateInQueue => 'queued';

  @override
  String stateDownloading(int percent) {
    return 'downloading $percent%';
  }

  @override
  String get stateWaitingForWifi => 'Waiting for Wi-Fi';

  @override
  String get stateWaitingForDownload => 'waiting to download';

  @override
  String get stateDownloadFailed => 'Couldn\'t download the episode.';

  @override
  String get offline =>
      'Offline. Positions will sync when the server is reachable.';

  @override
  String get syncError => 'Sync failed. The app will try again.';

  @override
  String get syncLoading => 'Loading…';

  @override
  String get inProgressEmpty => 'You have no episodes in progress.';

  @override
  String get queueEmpty => 'The queue is empty.';

  @override
  String get newEmpty => 'You have no new episodes.';

  @override
  String get olderEpisodesInPodcasts => 'Find older episodes under Podcasts';

  @override
  String get podcastsEmpty => 'You haven\'t subscribed to any podcasts yet.';

  @override
  String get downloadsEmpty => 'There are no downloads on this phone yet.';

  @override
  String get podcastEmpty => 'This podcast has no episodes yet.';

  @override
  String get searchThisPodcast => 'Search this podcast';

  @override
  String get clearSearch => 'Clear search';

  @override
  String get noMatchingEpisodes => 'No episodes match your search.';

  @override
  String get episodeMissing => 'This episode is no longer available.';

  @override
  String get podcastMissing => 'This podcast is no longer available.';

  @override
  String get selectEpisode => 'Select an episode from the list.';

  @override
  String get episodeActions => 'Episode actions';

  @override
  String get addToQueue => 'Add to queue';

  @override
  String get removeFromQueue => 'Remove from queue';

  @override
  String get queueDragHint => 'Hold an episode and drag it.';

  @override
  String get queueSaving => 'Saving queue…';

  @override
  String get moveQueueUp => 'Move up';

  @override
  String get moveQueueDown => 'Move down';

  @override
  String get moveQueueFirst => 'Move to top';

  @override
  String get download => 'Download';

  @override
  String downloadProgress(int percent) {
    return 'Downloading… $percent%';
  }

  @override
  String get waitingForWifi => 'Waiting for Wi-Fi';

  @override
  String get waitingForDownload => 'Waiting to download';

  @override
  String get deleteFile => 'Delete file';

  @override
  String get cancelDownload => 'Cancel download';

  @override
  String get cancelDownloadTitle => 'Cancel download?';

  @override
  String get retryDownload => 'Retry download';

  @override
  String get markPlayed => 'Mark as played';

  @override
  String get markNew => 'Mark as new';

  @override
  String get dismiss => 'Dismiss';

  @override
  String get dismissTitle => 'Dismiss episode?';

  @override
  String get dismissFile => 'The downloaded file will be deleted.';

  @override
  String get dismissOlder => 'Dismiss older too';

  @override
  String get dismissOlderOffline =>
      'Dismissing older episodes requires a connection to the server.';

  @override
  String get dismissOlderKept =>
      'Episodes in progress, played episodes, and queued episodes will be kept.';

  @override
  String get dismissOlderDownloads =>
      'Downloads of these episodes will be deleted.';

  @override
  String get cancel => 'Cancel';

  @override
  String get close => 'Close';

  @override
  String get actionFailed => 'Couldn\'t finish the change. Try again.';

  @override
  String get descriptionFailed => 'Couldn\'t load the description.';

  @override
  String get retry => 'Try again';

  @override
  String get linkFailed => 'Couldn\'t open the link.';

  @override
  String get speed => 'Speed';

  @override
  String get speedHelp => 'Applies to all podcasts.';

  @override
  String get sleep => 'Sleep timer';

  @override
  String get sleepOff => 'Off';

  @override
  String get sleepOffHelp => 'Choose when playback should stop.';

  @override
  String get sleepEndOfEpisode => 'End of episode';

  @override
  String get sleepEndValue => 'until episode ends';

  @override
  String get sleepEndHelp => 'Playback will stop at the end of the episode.';

  @override
  String get refresh => 'Refresh';

  @override
  String get refreshing => 'Refreshing…';

  @override
  String get refreshRequested => 'Refresh requested';

  @override
  String get refreshFailed => 'Couldn\'t refresh the feeds. Try again.';

  @override
  String get today => 'Today';

  @override
  String get yesterday => 'Yesterday';

  @override
  String get noDate => 'No date';

  @override
  String get addPodcast => 'Add podcast';

  @override
  String get addingPodcast => 'Adding…';

  @override
  String get feedAddress => 'Feed address';

  @override
  String get addPodcastHelp =>
      'Paste the RSS feed address. The server will fetch the podcast and subscribe to it.';

  @override
  String get invalidFeedUrl =>
      'Enter the full feed address starting with http:// or https://.';

  @override
  String get invalidFeed =>
      'The server couldn\'t find a usable feed at that address. Check the address.';

  @override
  String get subscribeFailed => 'Couldn\'t add the podcast. Try again.';

  @override
  String get feedUnavailable => 'Couldn\'t fetch the feed.';

  @override
  String get feedStatus => 'Feed status';

  @override
  String get aboutPodcast => 'About podcast';

  @override
  String get unsubscribe => 'Unsubscribe';

  @override
  String get unsubscribeTitle => 'Unsubscribe?';

  @override
  String get resubscribe => 'Subscribe again';

  @override
  String get unsubscribing => 'Unsubscribing…';

  @override
  String get unsubscribeHelp =>
      'The server will stop fetching new episodes. Existing episodes and their listening status will be kept.';

  @override
  String get notSubscribed => 'This podcast is unsubscribed.';

  @override
  String get feedNeverLoaded => 'The feed hasn\'t been fetched yet.';

  @override
  String get server => 'Server';

  @override
  String get serverAddress => 'Server address';

  @override
  String get serverConnected => 'Connected';

  @override
  String get sendNow => 'Send now';

  @override
  String get serverChangeHelp =>
      'To use a different server address, sign out and enter it when you sign in.';

  @override
  String serverLastSync(String time) {
    return 'Last synced $time';
  }

  @override
  String serverClockSkew(int minutes) {
    return 'The device clock differs from the server by $minutes min.';
  }

  @override
  String pendingChanges(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count changes waiting to send',
      one: '1 change waiting to send',
    );
    return '$_temp0';
  }

  @override
  String get deviceName => 'Device name';

  @override
  String get defaultAndroidDevice => 'Android phone';

  @override
  String get defaultLinuxDevice => 'Linux computer';

  @override
  String get defaultDevice => 'My device';

  @override
  String get logout => 'Sign out';

  @override
  String get loggingOut => 'Signing out…';

  @override
  String get continueQueue => 'Continue with queue';

  @override
  String get continueQueueOn => 'The next episode plays when this one ends.';

  @override
  String get continueQueueOff => 'Playback stops when the episode ends.';

  @override
  String get skipBack => 'Skip back';

  @override
  String get skipForward => 'Skip forward';

  @override
  String get alphabeticalPodcasts => 'Sort podcasts alphabetically';

  @override
  String get downloadWifi => 'Download on Wi-Fi only';

  @override
  String get keepQueueDownloaded =>
      'Keep the first two queued episodes downloaded (Wi-Fi only)';

  @override
  String get deletePlayedDownloads => 'Delete files after playback';

  @override
  String get opml => 'Import and export OPML';

  @override
  String get opmlHelp =>
      'Paste the contents of an OPML file, or copy your subscriptions as OPML.';

  @override
  String get opmlContent => 'OPML contents';

  @override
  String get opmlImport => 'Import';

  @override
  String get opmlImporting => 'Importing…';

  @override
  String get opmlExport => 'Copy OPML';

  @override
  String get opmlExporting => 'Copying…';

  @override
  String get opmlCopied => 'Subscriptions were copied to the clipboard.';

  @override
  String get opmlInvalid => 'Check that you pasted the whole OPML document.';

  @override
  String get opmlFailed => 'Couldn\'t process the OPML document. Try again.';

  @override
  String get signIn => 'Sign in';

  @override
  String get signInTitle => 'Sign in to EasyPodcast';

  @override
  String get signingIn => 'Signing in…';

  @override
  String get loginHelp =>
      'Sign in to your server to share subscriptions, your queue, and listening positions across devices.';

  @override
  String get deviceNameHelp => 'This name identifies the device on the server.';

  @override
  String get username => 'Username';

  @override
  String get password => 'Password';

  @override
  String get loginMissing => 'Enter your username, password, and device name.';

  @override
  String get invalidServerUrl =>
      'Enter the full server address starting with http:// or https://.';

  @override
  String get loginRejected =>
      'The username or password is incorrect. Check both and try again.';

  @override
  String get loginRateLimit =>
      'There have been too many sign-in attempts. Wait a moment and try again.';

  @override
  String get loginOffline =>
      'Couldn\'t reach the server. Check the address and your connection.';

  @override
  String get loginFailed => 'Couldn\'t sign in. Try again.';

  @override
  String numberedTitle(int number, String title) {
    return '$number. $title';
  }

  @override
  String minutes(int count) {
    return '$count min';
  }

  @override
  String hoursMinutes(int hours, int minutes) {
    return '$hours h $minutes min';
  }

  @override
  String hours(int count) {
    return '$count h';
  }

  @override
  String seconds(int count) {
    return '$count s';
  }

  @override
  String skipBackValue(int count) {
    return '−$count s';
  }

  @override
  String skipForwardValue(int count) {
    return '+$count s';
  }

  @override
  String speedValue(String value) {
    return '$value×';
  }

  @override
  String desktopSpeed(String value) {
    return 'Speed $value';
  }

  @override
  String remaining(String length) {
    return '$length left';
  }

  @override
  String remainingOfTotal(String left, String total) {
    return '$left left of $total';
  }

  @override
  String elapsed(String length) {
    return '$length played';
  }

  @override
  String playFrom(String position) {
    return 'Play from $position';
  }

  @override
  String published(String date) {
    return 'Published $date';
  }

  @override
  String shortDate(int day, int month) {
    return '$month/$day';
  }

  @override
  String olderDay(String weekday, String date) {
    return '$weekday, $date';
  }

  @override
  String playedCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count played',
      one: '1 played',
    );
    return '$_temp0';
  }

  @override
  String dismissPosition(String position) {
    return 'The position at $position will be lost.';
  }

  @override
  String dismissPositionAndFile(String position) {
    return 'The position at $position will be lost and the downloaded file will be deleted.';
  }

  @override
  String dismissCountTitle(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Dismiss $count episodes?',
      one: 'Dismiss one episode?',
    );
    return '$_temp0';
  }

  @override
  String dismissCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Dismiss $count episodes',
      one: 'Dismiss episode',
    );
    return '$_temp0';
  }

  @override
  String dismissOlderCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'This episode and $count older new episodes.',
      one: 'This episode and one older new episode.',
    );
    return '$_temp0';
  }

  @override
  String sleepUntil(String time) {
    return 'until $time';
  }

  @override
  String sleepUntilHelp(String time) {
    return 'Playback will stop at $time.';
  }

  @override
  String loadedAt(String time) {
    return 'fetched at $time';
  }

  @override
  String feedLastLoaded(String date, String time) {
    return 'Last fetched on $date at $time.';
  }

  @override
  String loadedOn(String date) {
    return 'fetched on $date';
  }

  @override
  String kilobytes(String value) {
    return '$value kB';
  }

  @override
  String megabytes(String value) {
    return '$value MB';
  }

  @override
  String gigabytes(String value) {
    return '$value GB';
  }

  @override
  String storageUsed(String used) {
    return '$used used';
  }

  @override
  String get storageUnknown => 'The size of downloaded files is unavailable.';

  @override
  String opmlSummary(int added, int existing, int failed) {
    return 'Added $added, already present $existing, failed $failed.';
  }

  @override
  String version(String value) {
    return 'Version $value';
  }
}
