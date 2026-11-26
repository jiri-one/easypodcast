import '../../core/models.dart';

typedef DemoContent = ({
  Map<int, Podcast> podcasts,
  Map<int, Episode> episodes,
  Map<int, EpisodeState> states,
  QueueState queue,
});

DemoContent createDemoContent() {
  final now = nowUtc();
  final local = now.toLocal();
  final today = DateTime(local.year, local.month, local.day);
  final podcasts = <int, Podcast>{};
  final episodes = <int, Episode>{};
  for (final (index, show) in _shows.indexed) {
    final id = index + 1;
    final count = 22 + 2 * index;
    final url = 'https://podcast.example/$id';
    podcasts[id] = Podcast(
      id: id,
      feedUrl: '$url/feed.xml',
      title: show.title,
      author: show.author,
      description: show.description,
      episodeCount: count,
      episodesVersion: '1',
      lastSuccessAt: now.subtract(
        id == 7 ? const Duration(days: 2) : Duration(minutes: 10 + index),
      ),
      lastError: id == 7 ? 'Server feedu neodpovídá.' : null,
    );
    for (var number = 1; number <= count; number++) {
      final episodeId = id * 100 + number;
      final topic = show.topics[(number - 1) % show.topics.length];
      episodes[episodeId] = Episode(
        id: episodeId,
        podcastId: id,
        guid: 'demo-$episodeId',
        title: number <= show.topics.length ? topic : '$topic · $number. díl',
        publishedAt: today
            .subtract(Duration(days: (number - 1) * 3 + (id - 1) ~/ 2))
            .toUtc(),
        durationS: switch (episodeId) {
          101 => 55 * 60,
          204 => 60 * 60,
          _ => 14 * 60 + (episodeId * 97) % (61 * 60),
        },
        enclosureLength: switch (episodeId) {
          101 => 58000000,
          204 => 61000000,
          _ => null,
        },
        enclosureUrl: '$url/$number.mp3',
        enclosureType: 'audio/mpeg',
      );
    }
  }

  final states = <int, EpisodeState>{};
  void seedState(int id, EpisodeStatus status, int minutes, int hoursAgo) {
    states[id] = EpisodeState(
      episodeId: id,
      positionMs: Duration(minutes: minutes).inMilliseconds,
      durationMs: episodes[id]!.durationS! * 1000,
      status: status,
      updatedAt: now.subtract(Duration(hours: hoursAgo)),
    );
  }

  seedState(101, EpisodeStatus.none, 32, 1);
  seedState(204, EpisodeStatus.none, 41, 6);
  seedState(704, EpisodeStatus.none, 6, 24);
  seedState(303, EpisodeStatus.dismissed, 0, 2);
  for (final podcastId in podcasts.keys) {
    for (var number = 7; number < 8 + podcastId; number++) {
      seedState(podcastId * 100 + number, EpisodeStatus.played, 0, 25 + number);
    }
  }

  return (
    podcasts: podcasts,
    episodes: episodes,
    states: states,
    queue: QueueState(
      episodeIds: const [203, 401, 602],
      updatedAt: now.subtract(const Duration(hours: 4)),
    ),
  );
}

const _shows = [
  (
    title: 'Za poslední výhybkou',
    author: 'Studio Nástupiště',
    description: 'Příběhy z vedlejších tratí, výtopen a zapomenutých zastávek.',
    topics: [
      'Poslední vlak do skal',
      'Jak se na nočním nádraží střídají výpravčí',
      'Výtopna, kde se zastavil čas',
      'Koleje pod hladinou',
      'Zvonění na přejezdu',
      'Drezínou na konec trati',
    ],
  ),
  (
    title: 'Když město ztichne',
    author: 'Redakce Od soumraku',
    description: 'Vycházky za lidmi, kteří mají směnu, když město spí.',
    topics: [
      'Pekaři vstávají ve dvě',
      'Město očima nočních hlídaček',
      'Poslední tramvaj z vozovny',
      'Světlo v prázdném kině',
      'Vůně raného tržiště',
      'Kdo opravuje věžní hodiny',
    ],
  ),
  (
    title: 'Atlas malých vod',
    author: 'Spolek U pramene',
    description: 'O mokřadech, potocích a lidech, kteří jim uvolňují místo.',
    topics: [
      'Potok, který se vrátil do údolí',
      'Rybník mezi třemi poli',
      'Tůň pro čolky',
      'Po stopách slepého ramene',
      'Kolik vody schová louka',
      'U studánky bez jména',
    ],
  ),
  (
    title: 'Ruce od hlíny',
    author: 'Dílna Pod prsty',
    description: 'Návštěvy u řemeslníků, od prvního náčrtu po hotovou věc.',
    topics: [
      'Jak vzniká hrnek do obou dlaní',
      'Pece, které nespěchají',
      'Dřevo ze staré stodoly',
      'U stolu s knihařkou',
      'Brusný kámen po dědovi',
      'Poslední steh',
    ],
  ),
  (
    title: 'Schody do podkroví',
    author: 'Studio Mezi domy',
    description: 'Domy a čtvrti vyprávějí, když se v nich na chvíli zastavíš.',
    topics: [
      'Co prozradí zvonky u dveří',
      'Dům s pěti dvorky',
      'Půda plná kulis',
      'Když se obchod mění v knihovnu',
      'Cihly ze zrušené továrny',
      'Nový život staré vodárny',
    ],
  ),
  (
    title: 'O kus oblohy dál',
    author: 'Klub Noční čočka',
    description: 'Pozorování noční oblohy z balkonu, louky i hvězdárny.',
    topics: [
      'První noc s vypůjčeným dalekohledem',
      'Proč se Měsíc u obzoru zdá tak velký',
      'Záblesk nad severním lesem',
      'Mapa nebe po čtyřech stech letech',
      'Ráno, kdy zmizely hvězdy',
      'Nad střechami bez světel',
    ],
  ),
  (
    title: 'Drobné vynálezy',
    author: 'Kroužek Na ponku',
    description: 'Jak a proč vznikají obyčejné věci, které máme pořád po ruce.',
    topics: [
      'Víčko, které se neztratí',
      'Proč klíč cvakne právě jednou',
      'Ostré tužky bez nože',
      'Papírový metr v kapse',
      'Skládací židle na letní scénu',
      'Kuchyňská váha bez baterie',
    ],
  ),
  (
    title: 'Cestou k sedlu',
    author: 'Studio Hřeben',
    description: 'Pomalé cesty po horách a rozhovory na místech k odpočinku.',
    topics: [
      'Na hřeben ještě za tmy',
      'Bouda, kde umí číst vítr',
      'Kudy jít, když značka zmizí ve sněhu',
      'Čaj v přístřešku nad kamenolomem',
      'Stezka podél kamenných zídek',
      'Návrat v prvním sněhu',
    ],
  ),
];
