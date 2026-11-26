import '../core/models.dart';

final _whitespace = RegExp(r'\p{White_Space}+', unicode: true);
final _combiningMark = RegExp(r'\p{Mn}', unicode: true);

List<String> podcastSearchWords(String query) => [
  for (final word in _fold(query).split(_whitespace))
    if (word.isNotEmpty) word,
];

bool podcastTitleMatches(String title, List<String> words) =>
    words.every(_fold(title).contains);

List<Episode> matchPodcastEpisodes(
  List<Episode> episodes,
  List<String> words,
  Set<int> descriptionMatches,
) {
  if (words.isEmpty) return episodes;
  final titles = <Episode>[];
  final descriptions = <Episode>[];
  for (final episode in episodes) {
    final title = _fold(episode.title);
    if (words.every(title.contains)) {
      titles.add(episode);
    } else if (descriptionMatches.contains(episode.id)) {
      descriptions.add(episode);
    }
  }
  return [...titles, ...descriptions];
}

List<Episode> matchLibraryEpisodes(
  Iterable<Episode> episodes,
  List<String> words,
  Set<int> descriptionMatches,
  Map<String, String> foldedTitles,
) {
  if (words.isEmpty) return const [];
  final titles = <Episode>[];
  final descriptions = <Episode>[];
  for (final episode in episodes) {
    if (words.every(
      (foldedTitles[episode.title] ??= _fold(episode.title)).contains,
    )) {
      titles.add(episode);
    } else if (descriptionMatches.contains(episode.id)) {
      descriptions.add(episode);
    }
  }
  // Description matches arrive later; adding them below keeps the rows
  // already drawn on e-ink in place.
  return [
    ...(titles..sort(_comparePublication)),
    ...(descriptions..sort(_comparePublication)),
  ].take(100).toList();
}

int _comparePublication(Episode a, Episode b) {
  final byDate = (b.publishedAt ?? oldestTime).compareTo(
    a.publishedAt ?? oldestTime,
  );
  return byDate == 0 ? b.id.compareTo(a.id) : byDate;
}

String _fold(String value) {
  final lower = value.toLowerCase();
  final runes = RuneIterator(lower);
  StringBuffer? buffer;
  var start = 0;
  while (runes.moveNext()) {
    final rune = runes.current;
    if (rune <= 0x7f) continue;
    final replacement =
        _baseOf[rune] ??
        (_combiningMark.hasMatch(String.fromCharCode(rune)) ? '' : null);
    if (replacement == null) continue;
    (buffer ??= StringBuffer())
      ..write(lower.substring(start, runes.rawIndex))
      ..write(replacement);
    start = runes.rawIndex + runes.currentSize;
  }
  return buffer == null
      ? lower
      : (buffer..write(lower.substring(start))).toString();
}

final _baseOf = {
  for (final [base, variants]
      in _canonicalAccents
          .trim()
          .split(_whitespace)
          .map((group) => group.split(':')))
    for (final rune in variants.runes) rune: base,
};

// The server strips combining marks after canonical decomposition.
const _canonicalAccents = '''
<:≮ =:≠ >:≯ a:àáâãäåāăąǎǟǡǻȁȃȧḁạảấầẩẫậắằẳẵặ b:ḃḅḇ c:çćĉċčḉ d:ďḋḍḏḑḓ
e:èéêëēĕėęěȅȇȩḕḗḙḛḝẹẻẽếềểễệ f:ḟ g:ĝğġģǧǵḡ h:ĥȟḣḥḧḩḫẖ i:ìíîïĩīĭįǐȉȋḭḯỉị j:ĵǰ
k:ķǩḱḳḵ l:ĺļľḷḹḻḽ m:ḿṁṃ n:ñńņňǹṅṇṉṋ o:òóôõöōŏőơǒǫǭȍȏȫȭȯȱṍṏṑṓọỏốồổỗộớờởỡợ
p:ṕṗ r:ŕŗřȑȓṙṛṝṟ s:śŝşšșṡṣṥṧṩ t:ţťțṫṭṯṱẗ u:ùúûüũūŭůűųưǔǖǘǚǜȕȗṳṵṷṹṻụủứừửữự
v:ṽṿ w:ŵẁẃẅẇẉẘ x:ẋẍ y:ýÿŷȳẏẙỳỵỷỹ z:źżžẑẓẕ ¨:΅῁῭΅ æ:ǣǽ ø:ǿ ſ:ẛ ʒ:ǯ
α:άἀἁἂἃἄἅἆἇὰάᾀᾁᾂᾃᾄᾅᾆᾇᾰᾱᾲᾳᾴᾶᾷ ε:έἐἑἒἓἔἕὲέ η:ήἠἡἢἣἤἥἦἧὴήᾐᾑᾒᾓᾔᾕᾖᾗῂῃῄῆῇ
ι:ΐίϊἰἱἲἳἴἵἶἷὶίῐῑῒΐῖῗ ο:όὀὁὂὃὄὅὸό ρ:ῤῥ υ:ΰϋύὐὑὒὓὔὕὖὗὺύῠῡῢΰῦῧ
ω:ώὠὡὢὣὤὥὦὧὼώᾠᾡᾢᾣᾤᾥᾦᾧῲῳῴῶῷ ϒ:ϓϔ а:ӑӓ г:ѓ е:ѐёӗ ж:ӂӝ з:ӟ и:йѝӣӥ к:ќ о:ӧ
у:ўӯӱӳ ч:ӵ ы:ӹ э:ӭ і:ї ѵ:ѷ ә:ӛ ө:ӫ א:אַאָאּ ב:בּבֿ ג:גּ ד:דּ ה:הּ ו:וּוֹ ז:זּ ט:טּ י:יִיּ
ך:ךּ כ:כּכֿ ל:לּ מ:מּ נ:נּ ס:סּ ף:ףּ פ:פּפֿ צ:צּ ק:קּ ר:רּ ש:שׁשׂשּׁשּׂשּ ת:תּ ײ:ײַ ا:آأإ و:ؤ ي:ئ
ہ:ۂ ے:ۓ ە:ۀ क:क़ ख:ख़ ग:ग़ ज:ज़ ड:ड़ ढ:ढ़ न:ऩ फ:फ़ य:य़ र:ऱ ळ:ऴ ড:ড় ঢ:ঢ় য:য় ਖ:ਖ਼ ਗ:ਗ਼
ਜ:ਜ਼ ਫ:ਫ਼ ਲ:ਲ਼ ਸ:ਸ਼ ଡ:ଡ଼ ଢ:ଢ଼ େ:ୈ ೂ:ೊ ೂೕ:ೋ ೕ:ೀೇ ೖ:ೈ ෙ:ේ ො:ෝ ཀ:ཀྵ ག:གྷ ཌ:ཌྷ ད:དྷ བ:བྷ
ཛ:ཛྷ ဥ:ဦ ᬵ:ᬻᬽᭃ ᾿:῍῎῏ ῾:῝῞῟ ←:↚ →:↛ ↔:↮ ⇐:⇍ ⇒:⇏ ⇔:⇎ ∃:∄ ∈:∉ ∋:∌ ∣:∤ ∥:∦ ∼:≁
≃:≄ ≅:≇ ≈:≉ ≍:≭ ≡:≢ ≤:≰ ≥:≱ ≲:≴ ≳:≵ ≶:≸ ≷:≹ ≺:⊀ ≻:⊁ ≼:⋠ ≽:⋡ ⊂:⊄ ⊃:⊅ ⊆:⊈ ⊇:⊉
⊑:⋢ ⊒:⋣ ⊢:⊬ ⊨:⊭ ⊩:⊮ ⊫:⊯ ⊲:⋪ ⊳:⋫ ⊴:⋬ ⊵:⋭ ⫝:⫝̸ う:ゔ か:が き:ぎ く:ぐ け:げ こ:ご さ:ざ し:じ
す:ず せ:ぜ そ:ぞ た:だ ち:ぢ つ:づ て:で と:ど は:ばぱ ひ:びぴ ふ:ぶぷ へ:べぺ ほ:ぼぽ ゝ:ゞ ウ:ヴ カ:ガ キ:ギ
ク:グ ケ:ゲ コ:ゴ サ:ザ シ:ジ ス:ズ セ:ゼ ソ:ゾ タ:ダ チ:ヂ ツ:ヅ テ:デ ト:ド ハ:バパ ヒ:ビピ フ:ブプ ヘ:ベペ
ホ:ボポ ワ:ヷ ヰ:ヸ ヱ:ヹ ヲ:ヺ ヽ:ヾ 𐗒:𐗉 𐗚:𐗤 𑂙:𑂚 𑂛:𑂜 𑂥:𑂫 𑎄:𑎅 𑒹:𑒻
''';
