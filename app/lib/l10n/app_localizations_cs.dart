// ignore_for_file: deprecated_member_use

// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Czech (`cs`).
class AppLocalizationsCs extends AppLocalizations {
  AppLocalizationsCs([String locale = 'cs']) : super(locale);

  @override
  String get appTitle => 'EasyPodcast';

  @override
  String get inProgress => 'Rozposlouchané';

  @override
  String get queue => 'Fronta';

  @override
  String get newEpisodes => 'Nové díly';

  @override
  String get podcasts => 'Podcasty';

  @override
  String get downloads => 'Stažené';

  @override
  String get settings => 'Nastavení';

  @override
  String get changeList => 'Přepnout seznam';

  @override
  String get player => 'Přehrávač';

  @override
  String get seekPlayback => 'Pozice přehrávání';

  @override
  String get seekUnavailable => 'Pozici teď nejde změnit.';

  @override
  String nextInQueue(String title) {
    return 'Další ve frontě: $title';
  }

  @override
  String get play => 'Přehrát';

  @override
  String get pause => 'Pauza';

  @override
  String get stop => 'Zastavit';

  @override
  String get checkingPosition => 'Zjišťuji pozici…';

  @override
  String get loadingPlayback => 'Načítám…';

  @override
  String get playbackFailed => 'Díl se nepodařilo přehrát. Zkus to znovu.';

  @override
  String get playbackOffline => 'Bez spojení jde přehrát jen stažený díl.';

  @override
  String get playbackLoadFailed => 'Díl se nepodařilo načíst.';

  @override
  String get playbackStreamFailed => 'Přehrávání se přerušilo.';

  @override
  String get playbackSeekFailed => 'Pozici se nepodařilo změnit.';

  @override
  String get playbackFocusUnavailable => 'Zvuk teď používá jiná aplikace.';

  @override
  String get noPlayback => 'Zatím nic nehraje.';

  @override
  String get stateNew => 'nový';

  @override
  String get statePlaying => 'hraje';

  @override
  String get stateInProgress => 'rozposlouchaný';

  @override
  String get statePlayed => 'přehraný';

  @override
  String get stateDismissed => 'vyřazený';

  @override
  String get stateDownloaded => 'staženo';

  @override
  String get stateInQueue => 've frontě';

  @override
  String stateDownloading(int percent) {
    return 'stahuji $percent %';
  }

  @override
  String get stateWaitingForWifi => 'Čeká na Wi-Fi';

  @override
  String get stateWaitingForDownload => 'čeká na stažení';

  @override
  String get stateDownloadFailed => 'Stažení se nezdařilo.';

  @override
  String get offline => 'Bez spojení. Pozice se odešlou po připojení.';

  @override
  String get syncError =>
      'Synchronizace se nezdařila. Aplikace to zkusí znovu sama.';

  @override
  String get syncLoading => 'Načítám…';

  @override
  String get inProgressEmpty => 'Nemáš žádné rozposlouchané díly.';

  @override
  String get queueEmpty => 'Fronta je prázdná.';

  @override
  String get newEmpty => 'Nemáš žádné nové díly.';

  @override
  String get olderEpisodesInPodcasts => 'Starší díly najdeš u podcastů';

  @override
  String get podcastsEmpty => 'Zatím nemáš žádné odběry.';

  @override
  String get downloadsEmpty => 'V telefonu zatím nemáš žádné stažené díly.';

  @override
  String get podcastEmpty => 'Tento podcast zatím nemá žádné díly.';

  @override
  String get search => 'Hledat';

  @override
  String get searchHint => 'Název nebo popis';

  @override
  String get episodes => 'Díly';

  @override
  String get searchThisPodcast => 'Hledat v podcastu';

  @override
  String get clearSearch => 'Zrušit hledání';

  @override
  String get noMatchingEpisodes => 'Žádné díly neodpovídají hledání.';

  @override
  String get episodeMissing => 'Tento díl už není k dispozici.';

  @override
  String get podcastMissing => 'Tento podcast už není k dispozici.';

  @override
  String get selectEpisode => 'Vyber díl v seznamu.';

  @override
  String get episodeActions => 'Akce dílu';

  @override
  String get addToQueue => 'Přidat do fronty';

  @override
  String get removeFromQueue => 'Odebrat z fronty';

  @override
  String get queueDragHint => 'Podrž díl a přetáhni ho.';

  @override
  String get queueSaving => 'Ukládám frontu…';

  @override
  String get moveQueueUp => 'Posunout výš';

  @override
  String get moveQueueDown => 'Posunout níž';

  @override
  String get moveQueueFirst => 'Posunout na začátek';

  @override
  String get download => 'Stáhnout';

  @override
  String downloadProgress(int percent) {
    return 'Stahuji… $percent %';
  }

  @override
  String get waitingForWifi => 'Čeká na Wi-Fi';

  @override
  String get waitingForDownload => 'Čeká na stažení';

  @override
  String get deleteFile => 'Smazat soubor';

  @override
  String get cancelDownload => 'Zrušit stahování';

  @override
  String get cancelDownloadTitle => 'Zrušit stahování?';

  @override
  String get retryDownload => 'Zkusit stáhnout znovu';

  @override
  String get markPlayed => 'Označit jako přehrané';

  @override
  String get markNew => 'Vrátit mezi nové';

  @override
  String get dismiss => 'Vyřadit';

  @override
  String get dismissTitle => 'Vyřadit díl?';

  @override
  String get dismissFile => 'Stažený soubor se smaže.';

  @override
  String get dismissOlder => 'Vyřadit i starší';

  @override
  String get dismissOlderOffline =>
      'Hromadné vyřazení potřebuje spojení se serverem.';

  @override
  String get dismissOlderKept =>
      'Rozposlouchané, přehrané a díly ve frontě zůstanou.';

  @override
  String get dismissOlderDownloads => 'Stažené soubory těchto dílů se smažou.';

  @override
  String get cancel => 'Zrušit';

  @override
  String get close => 'Zavřít';

  @override
  String get actionFailed => 'Změnu se nepodařilo dokončit. Zkus to znovu.';

  @override
  String get descriptionFailed => 'Popis se nepodařilo načíst.';

  @override
  String get retry => 'Zkusit znovu';

  @override
  String get linkFailed => 'Odkaz se nepodařilo otevřít.';

  @override
  String get speed => 'Rychlost';

  @override
  String get speedHelp => 'Platí pro všechny podcasty.';

  @override
  String get sleep => 'Spánek';

  @override
  String get sleepOff => 'Vypnuto';

  @override
  String get sleepOffHelp => 'Vyber, kdy se má přehrávání zastavit.';

  @override
  String get sleepEndOfEpisode => 'Do konce dílu';

  @override
  String get sleepEndValue => 'do konce dílu';

  @override
  String get sleepEndHelp => 'Přehrávání se zastaví po dohrání dílu.';

  @override
  String get refresh => 'Obnovit';

  @override
  String get refreshing => 'Obnovuji…';

  @override
  String get refreshRequested => 'Obnovení vyžádáno';

  @override
  String get refreshFailed => 'Feedy se nepodařilo obnovit. Zkus to znovu.';

  @override
  String get today => 'Dnes';

  @override
  String get yesterday => 'Včera';

  @override
  String get noDate => 'Bez data';

  @override
  String get addPodcast => 'Přidat podcast';

  @override
  String get subscribeTitle => 'Přidat podcast?';

  @override
  String get addingPodcast => 'Přidávám…';

  @override
  String get directorySearch => 'Najít podcast';

  @override
  String get searching => 'Hledám…';

  @override
  String get directoryTooShort => 'Napiš aspoň dva znaky.';

  @override
  String get directoryEmpty => 'Žádný podcast neodpovídá hledání.';

  @override
  String get directoryOffline =>
      'Bez spojení se serverem. Hledat jde jen online.';

  @override
  String get directoryOff =>
      'Server hledání v adresáři nenabízí. Vlož adresu feedu níže.';

  @override
  String get directoryFailed =>
      'Hledání se nepodařilo. Zkus to znovu nebo vlož adresu feedu níže.';

  @override
  String get subscribedMark => 'Odebíráš';

  @override
  String get feedAddress => 'Adresa feedu';

  @override
  String get addPodcastHelp =>
      'Vlož adresu RSS feedu. Server načte podcast a přidá ho do odběrů.';

  @override
  String get invalidFeedUrl =>
      'Zadej celou adresu feedu začínající http:// nebo https://.';

  @override
  String get invalidFeed =>
      'Server na této adrese nenašel použitelný feed. Zkontroluj adresu.';

  @override
  String get subscribeFailed => 'Podcast se nepodařilo přidat. Zkus to znovu.';

  @override
  String get feedUnavailable => 'Feed nejde stáhnout.';

  @override
  String get feedStatus => 'Stav feedů';

  @override
  String get aboutPodcast => 'O podcastu';

  @override
  String get showInNewEpisodes => 'Zobrazovat v Nových dílech';

  @override
  String get unsubscribe => 'Zrušit odběr';

  @override
  String get unsubscribeTitle => 'Zrušit odběr?';

  @override
  String get resubscribe => 'Odebírat znovu';

  @override
  String get unsubscribing => 'Ruším odběr…';

  @override
  String get unsubscribeHelp =>
      'Server přestane načítat nové díly. Dosavadní díly i jejich stav zůstanou.';

  @override
  String get notSubscribed => 'Odběr je zrušený.';

  @override
  String get feedNeverLoaded => 'Feed se zatím nenačetl.';

  @override
  String get server => 'Server';

  @override
  String get serverAddress => 'Adresa serveru';

  @override
  String get serverConnected => 'Spojeno';

  @override
  String get sendNow => 'Odeslat teď';

  @override
  String get serverChangeHelp =>
      'Jinou adresu serveru můžeš zadat po odhlášení.';

  @override
  String serverLastSync(String time) {
    return 'Poslední synchronizace $time';
  }

  @override
  String serverClockSkew(int minutes) {
    return 'Hodiny zařízení se liší od serveru o $minutes min.';
  }

  @override
  String pendingChanges(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count změn čeká na odeslání',
      few: '$count změny čekají na odeslání',
      one: '1 změna čeká na odeslání',
    );
    return '$_temp0';
  }

  @override
  String get deviceName => 'Název zařízení';

  @override
  String get defaultAndroidDevice => 'Telefon Android';

  @override
  String get defaultLinuxDevice => 'Počítač s Linuxem';

  @override
  String get defaultDevice => 'Moje zařízení';

  @override
  String get logout => 'Odhlásit se';

  @override
  String get loggingOut => 'Odhlašuji…';

  @override
  String get continueQueue => 'Pokračovat frontou';

  @override
  String get continueQueueOn => 'Po dohrání hraje další díl.';

  @override
  String get continueQueueOff => 'Po dohrání se přehrávání zastaví.';

  @override
  String get showSpeedAndSleep => 'Zobrazit rychlost a časovač spánku';

  @override
  String get skipBack => 'Skok zpět';

  @override
  String get skipForward => 'Skok vpřed';

  @override
  String get alphabeticalPodcasts => 'Řadit podcasty abecedně';

  @override
  String get downloadWifi => 'Stahovat jen přes Wi-Fi';

  @override
  String get keepQueueDownloaded =>
      'Držet první dva díly fronty stažené (jen Wi-Fi)';

  @override
  String get deletePlayedDownloads => 'Po přehrání smazat soubor';

  @override
  String get opml => 'Import a export OPML';

  @override
  String get opmlHelp =>
      'Vlož obsah souboru OPML, nebo zkopíruj své odběry jako OPML.';

  @override
  String get opmlContent => 'Obsah OPML';

  @override
  String get opmlImport => 'Importovat';

  @override
  String get opmlImporting => 'Importuji…';

  @override
  String get opmlExport => 'Kopírovat OPML';

  @override
  String get opmlExporting => 'Kopíruji…';

  @override
  String get opmlCopied => 'Odběry jsou zkopírované do schránky.';

  @override
  String get opmlInvalid => 'Zkontroluj, že jsi vložil celý dokument OPML.';

  @override
  String get opmlFailed =>
      'S dokumentem OPML se nepodařilo pracovat. Zkus to znovu.';

  @override
  String get signIn => 'Přihlásit se';

  @override
  String get signInTitle => 'Přihlášení';

  @override
  String get signingIn => 'Přihlašuji…';

  @override
  String get loginHelp =>
      'Přihlas se k serveru, aby se mezi zařízeními sdílely odběry, fronta a pozice poslechu.';

  @override
  String get deviceNameHelp => 'Tento název uvidíš na serveru.';

  @override
  String get username => 'Jméno';

  @override
  String get password => 'Heslo';

  @override
  String get loginMissing => 'Vyplň jméno, heslo a název zařízení.';

  @override
  String get invalidServerUrl =>
      'Zadej celou adresu serveru začínající http:// nebo https://.';

  @override
  String get loginRejected =>
      'Jméno nebo heslo nesouhlasí. Zkontroluj je a zkus to znovu.';

  @override
  String get loginRateLimit =>
      'Přihlášení bylo zkoušeno příliš často. Počkej chvíli a zkus to znovu.';

  @override
  String get loginOffline =>
      'Se serverem se nepodařilo spojit. Zkontroluj adresu a připojení.';

  @override
  String get loginFailed => 'Přihlášení se nezdařilo. Zkus to znovu.';

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
    return 'Rychlost $value';
  }

  @override
  String remaining(String length) {
    return 'zbývá $length';
  }

  @override
  String remainingOfTotal(String left, String total) {
    return 'zbývá $left z $total';
  }

  @override
  String elapsed(String length) {
    return 'přehráno $length';
  }

  @override
  String playFrom(String position) {
    return 'Přehrát od $position';
  }

  @override
  String published(String date) {
    return 'Vyšlo $date';
  }

  @override
  String shortDate(int day, int month) {
    return '$day. $month.';
  }

  @override
  String olderDay(String weekday, String date) {
    return '$weekday $date';
  }

  @override
  String playedCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count přehraných',
      few: '$count přehrané',
      one: '1 přehraný',
    );
    return '$_temp0';
  }

  @override
  String dismissPosition(String position) {
    return 'Pozice $position se zapomene.';
  }

  @override
  String dismissPositionAndFile(String position) {
    return 'Pozice $position se zapomene a stažený soubor se smaže.';
  }

  @override
  String dismissCountTitle(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Vyřadit $count dílů?',
      few: 'Vyřadit $count díly?',
      one: 'Vyřadit jeden díl?',
    );
    return '$_temp0';
  }

  @override
  String dismissCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Vyřadit $count dílů',
      few: 'Vyřadit $count díly',
      one: 'Vyřadit díl',
    );
    return '$_temp0';
  }

  @override
  String dismissOlderCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Tento a $count starších nových dílů.',
      few: 'Tento a $count starší nové díly.',
      one: 'Tento a jeden starší nový díl.',
    );
    return '$_temp0';
  }

  @override
  String sleepUntil(String time) {
    return 'do $time';
  }

  @override
  String sleepUntilHelp(String time) {
    return 'Přehrávání se zastaví v $time.';
  }

  @override
  String loadedAt(String time) {
    return 'načteno $time';
  }

  @override
  String feedLastLoaded(String date, String time) {
    return 'Naposledy načteno $date v $time.';
  }

  @override
  String loadedOn(String date) {
    return 'načteno $date';
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
    return 'Staženo $used';
  }

  @override
  String get storageUnknown => 'Velikost stažených souborů není dostupná.';

  @override
  String opmlSummary(int added, int existing, int failed) {
    return 'Přidáno $added, už existovalo $existing, nepodařilo se $failed.';
  }

  @override
  String version(String value) {
    return 'Verze $value';
  }
}
