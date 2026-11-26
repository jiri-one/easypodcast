// ignore_for_file: deprecated_member_use
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_cs.dart';
import 'app_localizations_en.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('cs'),
    Locale('en'),
  ];

  /// No description provided for @appTitle.
  ///
  /// In en, this message translates to:
  /// **'EasyPodcast'**
  String get appTitle;

  /// No description provided for @inProgress.
  ///
  /// In en, this message translates to:
  /// **'In progress'**
  String get inProgress;

  /// No description provided for @queue.
  ///
  /// In en, this message translates to:
  /// **'Queue'**
  String get queue;

  /// No description provided for @newEpisodes.
  ///
  /// In en, this message translates to:
  /// **'New episodes'**
  String get newEpisodes;

  /// No description provided for @podcasts.
  ///
  /// In en, this message translates to:
  /// **'Podcasts'**
  String get podcasts;

  /// No description provided for @downloads.
  ///
  /// In en, this message translates to:
  /// **'Downloads'**
  String get downloads;

  /// No description provided for @settings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settings;

  /// No description provided for @changeList.
  ///
  /// In en, this message translates to:
  /// **'Switch list'**
  String get changeList;

  /// No description provided for @player.
  ///
  /// In en, this message translates to:
  /// **'Player'**
  String get player;

  /// No description provided for @playerRedraw.
  ///
  /// In en, this message translates to:
  /// **'Player time refresh interval'**
  String get playerRedraw;

  /// No description provided for @listRedraw.
  ///
  /// In en, this message translates to:
  /// **'List playback progress refresh interval'**
  String get listRedraw;

  /// No description provided for @seekPlayback.
  ///
  /// In en, this message translates to:
  /// **'Playback position'**
  String get seekPlayback;

  /// No description provided for @seekUnavailable.
  ///
  /// In en, this message translates to:
  /// **'The playback position can’t be changed yet.'**
  String get seekUnavailable;

  /// No description provided for @nextInQueue.
  ///
  /// In en, this message translates to:
  /// **'Next in queue: {title}'**
  String nextInQueue(String title);

  /// No description provided for @play.
  ///
  /// In en, this message translates to:
  /// **'Play'**
  String get play;

  /// No description provided for @pause.
  ///
  /// In en, this message translates to:
  /// **'Pause'**
  String get pause;

  /// No description provided for @checkingPosition.
  ///
  /// In en, this message translates to:
  /// **'Checking position…'**
  String get checkingPosition;

  /// No description provided for @loadingPlayback.
  ///
  /// In en, this message translates to:
  /// **'Loading…'**
  String get loadingPlayback;

  /// No description provided for @playbackFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t play the episode. Try again.'**
  String get playbackFailed;

  /// No description provided for @playbackOffline.
  ///
  /// In en, this message translates to:
  /// **'Only downloaded episodes can play offline.'**
  String get playbackOffline;

  /// No description provided for @playbackLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn’t load the episode.'**
  String get playbackLoadFailed;

  /// No description provided for @playbackStreamFailed.
  ///
  /// In en, this message translates to:
  /// **'Playback was interrupted.'**
  String get playbackStreamFailed;

  /// No description provided for @playbackSeekFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn’t change the playback position.'**
  String get playbackSeekFailed;

  /// No description provided for @playbackFocusUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Another app is using audio.'**
  String get playbackFocusUnavailable;

  /// No description provided for @noPlayback.
  ///
  /// In en, this message translates to:
  /// **'Nothing is playing yet.'**
  String get noPlayback;

  /// No description provided for @stateNew.
  ///
  /// In en, this message translates to:
  /// **'new'**
  String get stateNew;

  /// No description provided for @statePlaying.
  ///
  /// In en, this message translates to:
  /// **'playing'**
  String get statePlaying;

  /// No description provided for @stateInProgress.
  ///
  /// In en, this message translates to:
  /// **'in progress'**
  String get stateInProgress;

  /// No description provided for @statePlayed.
  ///
  /// In en, this message translates to:
  /// **'played'**
  String get statePlayed;

  /// No description provided for @stateDismissed.
  ///
  /// In en, this message translates to:
  /// **'dismissed'**
  String get stateDismissed;

  /// No description provided for @stateDownloaded.
  ///
  /// In en, this message translates to:
  /// **'downloaded'**
  String get stateDownloaded;

  /// No description provided for @stateInQueue.
  ///
  /// In en, this message translates to:
  /// **'queued'**
  String get stateInQueue;

  /// No description provided for @stateDownloading.
  ///
  /// In en, this message translates to:
  /// **'downloading {percent}%'**
  String stateDownloading(int percent);

  /// No description provided for @stateWaitingForWifi.
  ///
  /// In en, this message translates to:
  /// **'Waiting for Wi-Fi'**
  String get stateWaitingForWifi;

  /// No description provided for @stateWaitingForDownload.
  ///
  /// In en, this message translates to:
  /// **'waiting to download'**
  String get stateWaitingForDownload;

  /// No description provided for @stateDownloadFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t download the episode.'**
  String get stateDownloadFailed;

  /// No description provided for @offline.
  ///
  /// In en, this message translates to:
  /// **'Offline. Positions will sync when the server is reachable.'**
  String get offline;

  /// No description provided for @syncError.
  ///
  /// In en, this message translates to:
  /// **'Sync failed. The app will try again.'**
  String get syncError;

  /// No description provided for @syncLoading.
  ///
  /// In en, this message translates to:
  /// **'Loading…'**
  String get syncLoading;

  /// No description provided for @inProgressEmpty.
  ///
  /// In en, this message translates to:
  /// **'You have no episodes in progress.'**
  String get inProgressEmpty;

  /// No description provided for @queueEmpty.
  ///
  /// In en, this message translates to:
  /// **'The queue is empty.'**
  String get queueEmpty;

  /// No description provided for @newEmpty.
  ///
  /// In en, this message translates to:
  /// **'You have no new episodes.'**
  String get newEmpty;

  /// No description provided for @olderEpisodesInPodcasts.
  ///
  /// In en, this message translates to:
  /// **'Find older episodes under Podcasts'**
  String get olderEpisodesInPodcasts;

  /// No description provided for @podcastsEmpty.
  ///
  /// In en, this message translates to:
  /// **'You haven\'t subscribed to any podcasts yet.'**
  String get podcastsEmpty;

  /// No description provided for @downloadsEmpty.
  ///
  /// In en, this message translates to:
  /// **'There are no downloads on this phone yet.'**
  String get downloadsEmpty;

  /// No description provided for @podcastEmpty.
  ///
  /// In en, this message translates to:
  /// **'This podcast has no episodes yet.'**
  String get podcastEmpty;

  /// No description provided for @episodeMissing.
  ///
  /// In en, this message translates to:
  /// **'This episode is no longer available.'**
  String get episodeMissing;

  /// No description provided for @podcastMissing.
  ///
  /// In en, this message translates to:
  /// **'This podcast is no longer available.'**
  String get podcastMissing;

  /// No description provided for @selectEpisode.
  ///
  /// In en, this message translates to:
  /// **'Select an episode from the list.'**
  String get selectEpisode;

  /// No description provided for @episodeActions.
  ///
  /// In en, this message translates to:
  /// **'Episode actions'**
  String get episodeActions;

  /// No description provided for @addToQueue.
  ///
  /// In en, this message translates to:
  /// **'Add to queue'**
  String get addToQueue;

  /// No description provided for @removeFromQueue.
  ///
  /// In en, this message translates to:
  /// **'Remove from queue'**
  String get removeFromQueue;

  /// No description provided for @queueDragHint.
  ///
  /// In en, this message translates to:
  /// **'Hold an episode and drag it.'**
  String get queueDragHint;

  /// No description provided for @queueSaving.
  ///
  /// In en, this message translates to:
  /// **'Saving queue…'**
  String get queueSaving;

  /// No description provided for @moveQueueUp.
  ///
  /// In en, this message translates to:
  /// **'Move up'**
  String get moveQueueUp;

  /// No description provided for @moveQueueDown.
  ///
  /// In en, this message translates to:
  /// **'Move down'**
  String get moveQueueDown;

  /// No description provided for @moveQueueFirst.
  ///
  /// In en, this message translates to:
  /// **'Move to top'**
  String get moveQueueFirst;

  /// No description provided for @download.
  ///
  /// In en, this message translates to:
  /// **'Download'**
  String get download;

  /// No description provided for @downloadProgress.
  ///
  /// In en, this message translates to:
  /// **'Downloading… {percent}%'**
  String downloadProgress(int percent);

  /// No description provided for @waitingForWifi.
  ///
  /// In en, this message translates to:
  /// **'Waiting for Wi-Fi'**
  String get waitingForWifi;

  /// No description provided for @waitingForDownload.
  ///
  /// In en, this message translates to:
  /// **'Waiting to download'**
  String get waitingForDownload;

  /// No description provided for @deleteFile.
  ///
  /// In en, this message translates to:
  /// **'Delete file'**
  String get deleteFile;

  /// No description provided for @cancelDownload.
  ///
  /// In en, this message translates to:
  /// **'Cancel download'**
  String get cancelDownload;

  /// No description provided for @cancelDownloadTitle.
  ///
  /// In en, this message translates to:
  /// **'Cancel download?'**
  String get cancelDownloadTitle;

  /// No description provided for @retryDownload.
  ///
  /// In en, this message translates to:
  /// **'Retry download'**
  String get retryDownload;

  /// No description provided for @markPlayed.
  ///
  /// In en, this message translates to:
  /// **'Mark as played'**
  String get markPlayed;

  /// No description provided for @markNew.
  ///
  /// In en, this message translates to:
  /// **'Mark as new'**
  String get markNew;

  /// No description provided for @dismiss.
  ///
  /// In en, this message translates to:
  /// **'Dismiss'**
  String get dismiss;

  /// No description provided for @dismissTitle.
  ///
  /// In en, this message translates to:
  /// **'Dismiss episode?'**
  String get dismissTitle;

  /// No description provided for @dismissFile.
  ///
  /// In en, this message translates to:
  /// **'The downloaded file will be deleted.'**
  String get dismissFile;

  /// No description provided for @dismissOlder.
  ///
  /// In en, this message translates to:
  /// **'Dismiss older too'**
  String get dismissOlder;

  /// No description provided for @dismissOlderOffline.
  ///
  /// In en, this message translates to:
  /// **'Dismissing older episodes requires a connection to the server.'**
  String get dismissOlderOffline;

  /// No description provided for @dismissOlderKept.
  ///
  /// In en, this message translates to:
  /// **'Episodes in progress, played episodes, and queued episodes will be kept.'**
  String get dismissOlderKept;

  /// No description provided for @dismissOlderDownloads.
  ///
  /// In en, this message translates to:
  /// **'Downloads of these episodes will be deleted.'**
  String get dismissOlderDownloads;

  /// No description provided for @cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// No description provided for @close.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get close;

  /// No description provided for @actionFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t finish the change. Try again.'**
  String get actionFailed;

  /// No description provided for @descriptionFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t load the description.'**
  String get descriptionFailed;

  /// No description provided for @retry.
  ///
  /// In en, this message translates to:
  /// **'Try again'**
  String get retry;

  /// No description provided for @linkFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t open the link.'**
  String get linkFailed;

  /// No description provided for @speed.
  ///
  /// In en, this message translates to:
  /// **'Speed'**
  String get speed;

  /// No description provided for @speedHelp.
  ///
  /// In en, this message translates to:
  /// **'Applies to all podcasts.'**
  String get speedHelp;

  /// No description provided for @sleep.
  ///
  /// In en, this message translates to:
  /// **'Sleep timer'**
  String get sleep;

  /// No description provided for @sleepOff.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get sleepOff;

  /// No description provided for @sleepOffHelp.
  ///
  /// In en, this message translates to:
  /// **'Choose when playback should stop.'**
  String get sleepOffHelp;

  /// No description provided for @sleepEndOfEpisode.
  ///
  /// In en, this message translates to:
  /// **'End of episode'**
  String get sleepEndOfEpisode;

  /// No description provided for @sleepEndValue.
  ///
  /// In en, this message translates to:
  /// **'until episode ends'**
  String get sleepEndValue;

  /// No description provided for @sleepEndHelp.
  ///
  /// In en, this message translates to:
  /// **'Playback will stop at the end of the episode.'**
  String get sleepEndHelp;

  /// No description provided for @refresh.
  ///
  /// In en, this message translates to:
  /// **'Refresh'**
  String get refresh;

  /// No description provided for @refreshing.
  ///
  /// In en, this message translates to:
  /// **'Refreshing…'**
  String get refreshing;

  /// No description provided for @refreshRequested.
  ///
  /// In en, this message translates to:
  /// **'Refresh requested'**
  String get refreshRequested;

  /// No description provided for @refreshFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t refresh the feeds. Try again.'**
  String get refreshFailed;

  /// No description provided for @today.
  ///
  /// In en, this message translates to:
  /// **'Today'**
  String get today;

  /// No description provided for @yesterday.
  ///
  /// In en, this message translates to:
  /// **'Yesterday'**
  String get yesterday;

  /// No description provided for @noDate.
  ///
  /// In en, this message translates to:
  /// **'No date'**
  String get noDate;

  /// No description provided for @addPodcast.
  ///
  /// In en, this message translates to:
  /// **'Add podcast'**
  String get addPodcast;

  /// No description provided for @addingPodcast.
  ///
  /// In en, this message translates to:
  /// **'Adding…'**
  String get addingPodcast;

  /// No description provided for @feedAddress.
  ///
  /// In en, this message translates to:
  /// **'Feed address'**
  String get feedAddress;

  /// No description provided for @addPodcastHelp.
  ///
  /// In en, this message translates to:
  /// **'Paste the RSS feed address. The server will fetch the podcast and subscribe to it.'**
  String get addPodcastHelp;

  /// No description provided for @invalidFeedUrl.
  ///
  /// In en, this message translates to:
  /// **'Enter the full feed address starting with http:// or https://.'**
  String get invalidFeedUrl;

  /// No description provided for @invalidFeed.
  ///
  /// In en, this message translates to:
  /// **'The server couldn\'t find a usable feed at that address. Check the address.'**
  String get invalidFeed;

  /// No description provided for @subscribeFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t add the podcast. Try again.'**
  String get subscribeFailed;

  /// No description provided for @feedUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t fetch the feed.'**
  String get feedUnavailable;

  /// No description provided for @feedStatus.
  ///
  /// In en, this message translates to:
  /// **'Feed status'**
  String get feedStatus;

  /// No description provided for @aboutPodcast.
  ///
  /// In en, this message translates to:
  /// **'About podcast'**
  String get aboutPodcast;

  /// No description provided for @unsubscribe.
  ///
  /// In en, this message translates to:
  /// **'Unsubscribe'**
  String get unsubscribe;

  /// No description provided for @unsubscribeTitle.
  ///
  /// In en, this message translates to:
  /// **'Unsubscribe?'**
  String get unsubscribeTitle;

  /// No description provided for @resubscribe.
  ///
  /// In en, this message translates to:
  /// **'Subscribe again'**
  String get resubscribe;

  /// No description provided for @unsubscribing.
  ///
  /// In en, this message translates to:
  /// **'Unsubscribing…'**
  String get unsubscribing;

  /// No description provided for @unsubscribeHelp.
  ///
  /// In en, this message translates to:
  /// **'The server will stop fetching new episodes. Existing episodes and their listening status will be kept.'**
  String get unsubscribeHelp;

  /// No description provided for @notSubscribed.
  ///
  /// In en, this message translates to:
  /// **'This podcast is unsubscribed.'**
  String get notSubscribed;

  /// No description provided for @feedNeverLoaded.
  ///
  /// In en, this message translates to:
  /// **'The feed hasn\'t been fetched yet.'**
  String get feedNeverLoaded;

  /// No description provided for @server.
  ///
  /// In en, this message translates to:
  /// **'Server'**
  String get server;

  /// No description provided for @serverAddress.
  ///
  /// In en, this message translates to:
  /// **'Server address'**
  String get serverAddress;

  /// No description provided for @serverConnected.
  ///
  /// In en, this message translates to:
  /// **'Connected'**
  String get serverConnected;

  /// No description provided for @sendNow.
  ///
  /// In en, this message translates to:
  /// **'Send now'**
  String get sendNow;

  /// No description provided for @serverChangeHelp.
  ///
  /// In en, this message translates to:
  /// **'To use a different server address, sign out and enter it when you sign in.'**
  String get serverChangeHelp;

  /// No description provided for @serverLastSync.
  ///
  /// In en, this message translates to:
  /// **'Last synced {time}'**
  String serverLastSync(String time);

  /// No description provided for @serverClockSkew.
  ///
  /// In en, this message translates to:
  /// **'The device clock differs from the server by {minutes} min.'**
  String serverClockSkew(int minutes);

  /// No description provided for @pendingChanges.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 change waiting to send} other{{count} changes waiting to send}}'**
  String pendingChanges(int count);

  /// No description provided for @deviceName.
  ///
  /// In en, this message translates to:
  /// **'Device name'**
  String get deviceName;

  /// No description provided for @defaultAndroidDevice.
  ///
  /// In en, this message translates to:
  /// **'Android phone'**
  String get defaultAndroidDevice;

  /// No description provided for @defaultLinuxDevice.
  ///
  /// In en, this message translates to:
  /// **'Linux computer'**
  String get defaultLinuxDevice;

  /// No description provided for @defaultDevice.
  ///
  /// In en, this message translates to:
  /// **'My device'**
  String get defaultDevice;

  /// No description provided for @logout.
  ///
  /// In en, this message translates to:
  /// **'Sign out'**
  String get logout;

  /// No description provided for @loggingOut.
  ///
  /// In en, this message translates to:
  /// **'Signing out…'**
  String get loggingOut;

  /// No description provided for @continueQueue.
  ///
  /// In en, this message translates to:
  /// **'Continue with queue'**
  String get continueQueue;

  /// No description provided for @continueQueueOn.
  ///
  /// In en, this message translates to:
  /// **'The next episode plays when this one ends.'**
  String get continueQueueOn;

  /// No description provided for @continueQueueOff.
  ///
  /// In en, this message translates to:
  /// **'Playback stops when the episode ends.'**
  String get continueQueueOff;

  /// No description provided for @skipBack.
  ///
  /// In en, this message translates to:
  /// **'Skip back'**
  String get skipBack;

  /// No description provided for @skipForward.
  ///
  /// In en, this message translates to:
  /// **'Skip forward'**
  String get skipForward;

  /// No description provided for @alphabeticalPodcasts.
  ///
  /// In en, this message translates to:
  /// **'Sort podcasts alphabetically'**
  String get alphabeticalPodcasts;

  /// No description provided for @downloadWifi.
  ///
  /// In en, this message translates to:
  /// **'Download on Wi-Fi only'**
  String get downloadWifi;

  /// No description provided for @keepQueueDownloaded.
  ///
  /// In en, this message translates to:
  /// **'Keep the first two queued episodes downloaded (Wi-Fi only)'**
  String get keepQueueDownloaded;

  /// No description provided for @deletePlayedDownloads.
  ///
  /// In en, this message translates to:
  /// **'Delete files after playback'**
  String get deletePlayedDownloads;

  /// No description provided for @opml.
  ///
  /// In en, this message translates to:
  /// **'Import and export OPML'**
  String get opml;

  /// No description provided for @opmlHelp.
  ///
  /// In en, this message translates to:
  /// **'Paste the contents of an OPML file, or copy your subscriptions as OPML.'**
  String get opmlHelp;

  /// No description provided for @opmlContent.
  ///
  /// In en, this message translates to:
  /// **'OPML contents'**
  String get opmlContent;

  /// No description provided for @opmlImport.
  ///
  /// In en, this message translates to:
  /// **'Import'**
  String get opmlImport;

  /// No description provided for @opmlImporting.
  ///
  /// In en, this message translates to:
  /// **'Importing…'**
  String get opmlImporting;

  /// No description provided for @opmlExport.
  ///
  /// In en, this message translates to:
  /// **'Copy OPML'**
  String get opmlExport;

  /// No description provided for @opmlExporting.
  ///
  /// In en, this message translates to:
  /// **'Copying…'**
  String get opmlExporting;

  /// No description provided for @opmlCopied.
  ///
  /// In en, this message translates to:
  /// **'Subscriptions were copied to the clipboard.'**
  String get opmlCopied;

  /// No description provided for @opmlInvalid.
  ///
  /// In en, this message translates to:
  /// **'Check that you pasted the whole OPML document.'**
  String get opmlInvalid;

  /// No description provided for @opmlFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t process the OPML document. Try again.'**
  String get opmlFailed;

  /// No description provided for @signIn.
  ///
  /// In en, this message translates to:
  /// **'Sign in'**
  String get signIn;

  /// No description provided for @signInTitle.
  ///
  /// In en, this message translates to:
  /// **'Sign in to EasyPodcast'**
  String get signInTitle;

  /// No description provided for @signingIn.
  ///
  /// In en, this message translates to:
  /// **'Signing in…'**
  String get signingIn;

  /// No description provided for @loginHelp.
  ///
  /// In en, this message translates to:
  /// **'Sign in to your server to share subscriptions, your queue, and listening positions across devices.'**
  String get loginHelp;

  /// No description provided for @deviceNameHelp.
  ///
  /// In en, this message translates to:
  /// **'This name identifies the device on the server.'**
  String get deviceNameHelp;

  /// No description provided for @username.
  ///
  /// In en, this message translates to:
  /// **'Username'**
  String get username;

  /// No description provided for @password.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get password;

  /// No description provided for @loginMissing.
  ///
  /// In en, this message translates to:
  /// **'Enter your username, password, and device name.'**
  String get loginMissing;

  /// No description provided for @invalidServerUrl.
  ///
  /// In en, this message translates to:
  /// **'Enter the full server address starting with http:// or https://.'**
  String get invalidServerUrl;

  /// No description provided for @loginRejected.
  ///
  /// In en, this message translates to:
  /// **'The username or password is incorrect. Check both and try again.'**
  String get loginRejected;

  /// No description provided for @loginRateLimit.
  ///
  /// In en, this message translates to:
  /// **'There have been too many sign-in attempts. Wait a moment and try again.'**
  String get loginRateLimit;

  /// No description provided for @loginOffline.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t reach the server. Check the address and your connection.'**
  String get loginOffline;

  /// No description provided for @loginFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t sign in. Try again.'**
  String get loginFailed;

  /// No description provided for @numberedTitle.
  ///
  /// In en, this message translates to:
  /// **'{number}. {title}'**
  String numberedTitle(int number, String title);

  /// No description provided for @minutes.
  ///
  /// In en, this message translates to:
  /// **'{count} min'**
  String minutes(int count);

  /// No description provided for @hoursMinutes.
  ///
  /// In en, this message translates to:
  /// **'{hours} h {minutes} min'**
  String hoursMinutes(int hours, int minutes);

  /// No description provided for @hours.
  ///
  /// In en, this message translates to:
  /// **'{count} h'**
  String hours(int count);

  /// No description provided for @seconds.
  ///
  /// In en, this message translates to:
  /// **'{count} s'**
  String seconds(int count);

  /// No description provided for @skipBackValue.
  ///
  /// In en, this message translates to:
  /// **'−{count} s'**
  String skipBackValue(int count);

  /// No description provided for @skipForwardValue.
  ///
  /// In en, this message translates to:
  /// **'+{count} s'**
  String skipForwardValue(int count);

  /// No description provided for @speedValue.
  ///
  /// In en, this message translates to:
  /// **'{value}×'**
  String speedValue(String value);

  /// No description provided for @desktopSpeed.
  ///
  /// In en, this message translates to:
  /// **'Speed {value}'**
  String desktopSpeed(String value);

  /// No description provided for @remaining.
  ///
  /// In en, this message translates to:
  /// **'{length} left'**
  String remaining(String length);

  /// No description provided for @remainingOfTotal.
  ///
  /// In en, this message translates to:
  /// **'{left} left of {total}'**
  String remainingOfTotal(String left, String total);

  /// No description provided for @elapsed.
  ///
  /// In en, this message translates to:
  /// **'{length} played'**
  String elapsed(String length);

  /// No description provided for @playFrom.
  ///
  /// In en, this message translates to:
  /// **'Play from {position}'**
  String playFrom(String position);

  /// No description provided for @published.
  ///
  /// In en, this message translates to:
  /// **'Published {date}'**
  String published(String date);

  /// No description provided for @shortDate.
  ///
  /// In en, this message translates to:
  /// **'{month}/{day}'**
  String shortDate(int day, int month);

  /// No description provided for @olderDay.
  ///
  /// In en, this message translates to:
  /// **'{weekday}, {date}'**
  String olderDay(String weekday, String date);

  /// No description provided for @playedCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 played} other{{count} played}}'**
  String playedCount(int count);

  /// No description provided for @dismissPosition.
  ///
  /// In en, this message translates to:
  /// **'The position at {position} will be lost.'**
  String dismissPosition(String position);

  /// No description provided for @dismissPositionAndFile.
  ///
  /// In en, this message translates to:
  /// **'The position at {position} will be lost and the downloaded file will be deleted.'**
  String dismissPositionAndFile(String position);

  /// No description provided for @dismissCountTitle.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Dismiss one episode?} other{Dismiss {count} episodes?}}'**
  String dismissCountTitle(int count);

  /// No description provided for @dismissCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Dismiss episode} other{Dismiss {count} episodes}}'**
  String dismissCount(int count);

  /// No description provided for @dismissOlderCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{This episode and one older new episode.} other{This episode and {count} older new episodes.}}'**
  String dismissOlderCount(int count);

  /// No description provided for @sleepUntil.
  ///
  /// In en, this message translates to:
  /// **'until {time}'**
  String sleepUntil(String time);

  /// No description provided for @sleepUntilHelp.
  ///
  /// In en, this message translates to:
  /// **'Playback will stop at {time}.'**
  String sleepUntilHelp(String time);

  /// No description provided for @loadedAt.
  ///
  /// In en, this message translates to:
  /// **'fetched at {time}'**
  String loadedAt(String time);

  /// No description provided for @feedLastLoaded.
  ///
  /// In en, this message translates to:
  /// **'Last fetched on {date} at {time}.'**
  String feedLastLoaded(String date, String time);

  /// No description provided for @loadedOn.
  ///
  /// In en, this message translates to:
  /// **'fetched on {date}'**
  String loadedOn(String date);

  /// No description provided for @kilobytes.
  ///
  /// In en, this message translates to:
  /// **'{value} kB'**
  String kilobytes(String value);

  /// No description provided for @megabytes.
  ///
  /// In en, this message translates to:
  /// **'{value} MB'**
  String megabytes(String value);

  /// No description provided for @gigabytes.
  ///
  /// In en, this message translates to:
  /// **'{value} GB'**
  String gigabytes(String value);

  /// No description provided for @storageUsed.
  ///
  /// In en, this message translates to:
  /// **'{used} used'**
  String storageUsed(String used);

  /// No description provided for @storageUsedAndFree.
  ///
  /// In en, this message translates to:
  /// **'{used} used, {free} free'**
  String storageUsedAndFree(String used, String free);

  /// No description provided for @storageUnknown.
  ///
  /// In en, this message translates to:
  /// **'The size of downloaded files is unavailable.'**
  String get storageUnknown;

  /// No description provided for @opmlSummary.
  ///
  /// In en, this message translates to:
  /// **'Added {added}, already present {existing}, failed {failed}.'**
  String opmlSummary(int added, int existing, int failed);

  /// No description provided for @version.
  ///
  /// In en, this message translates to:
  /// **'Version {value}'**
  String version(String value);
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['cs', 'en'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'cs':
      return AppLocalizationsCs();
    case 'en':
      return AppLocalizationsEn();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
