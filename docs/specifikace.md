# EasyPodcast: koncept specifikace

Koncept z 26. 11. 2026. Vychází ze zkušeností s goPodderem, AntennaPodem, Kasts,
Audiobookshelfem a PinePods a z rešerše alternativ z 25. 11. Technické rozhraní pro vývoj popisuje
`docs/architecture.md`. Místa, o kterých je ještě potřeba rozhodnout, odkazují na otevřené otázky
na konci (O5 a O7 až O21). Otázky O1 až O4 a O6 jsou rozhodnuté.

Úpravy z 26. 11.: podle prvních poznámek jednodušší synchronizace s jediným časem ze zařízení,
rozposlouchané díly odděleně od fronty a vyřazení dílu („už nechci poslouchat“). Po revizi
upřesněná pravidla synchronizace a fronty, délka dílu z přehrávače ve stavu dílu, hromadné
vyřazení jen nových dílů, opakovatelný import z PinePods, scénář 11 a rozhodnuté otázky O1 až O4
a O6.

## 1. Cíl

EasyPodcast je malý vlastní systém na poslech podcastů pro jednoho posluchače: server v Go na M1S
a klient ve Flutteru pro Android a Linux. Nahradí PinePods i goPodder. Umí méně než ony, ale co
umí, funguje spolehlivě.

Hotovo je, když:

- poslech lze předávat mezi HiBreakem, Palmou, autem a PC bez ztráty pozice a bez skoků zpět;
- všechno se dobře čte a ovládá na e-inku;
- dva týdny každodenního poslechu proběhnou bez PinePods.

## 2. Proč ne hotové řešení

- **goPodder s AntennaPodem a Kasts:** předávání rozbíjely chyby v aplikacích. AntennaPod #5444
  (načtený přehrávač si nechá starou pozici), #7080 (pozice −1 vrátí díl na začátek) a zahazování
  pozic pro díly, které telefon ještě nezná. Kasts označí díl za přehraný, když feed neuvádí
  délku. K listopadu 2026 není opravená žádná z těch chyb.
- **Audiobookshelf:** přehraje jen díly stažené na server a jeho autor odmítl přidat streamování.
- **PinePods:** přeplácané rozhraní, na e-inku špatně čitelné. Verze 0.9.2 drží nejvzdálenější
  pozici, takže přetočení zpět se nepřenese. Jediný autor přidává inbox, štítky a AI.
- **Rešerše z 25. 11.** nic lepšího nenašla (`.ai/research/reports/Alternativy k PinePods.md`
  v m1s-hosting).

## 3. Zařízení a prostředí

| Zařízení | Systém | Použití |
|---|---|---|
| HiBreak | Android 14, e-ink, šířka asi 250 logických bodů | hlavní, každý den |
| Boox Palma | Android 11, e-ink, jen Wi-Fi | občas, stejné díly jako HiBreak |
| Auto | Android Auto z telefonu (O5) | procházení, přehrávání, skoky |
| Sluchátka | Galaxy Buds 2 | pauza, pokračování, „další“, „předchozí“ |
| PC | Manjaro, niri (Wayland), písmo z GTK (Liberation Sans 18, bez vyhlazování) | občas |
| Server | Odroid M1S (ARM64): rootless Podman a Quadlet, sdílený PostgreSQL, Caddy, Cloudflare Tunnel, Gatus, noční záloha | – |

Aplikace se do telefonů instalují mimo Google Play, takže Android Auto vyžaduje vývojářskou volbu
„Neznámé zdroje“.

## 4. Co systém umí

### 4.1 Odběry a díly

- Nový podcast se přidá vložením adresy feedu (hledání v adresáři: O14).
- Import a export OPML. Import z PinePods: odběry, fronta, pozice a přehrané díly i s časy. Import
  lze spouštět opakovaně až do přechodu z PinePods. U každého dílu platí novější stav. Frontu
  import převezme, jen pokud je fronta v EasyPodcastu prázdná. Díly, které už ve feedu nejsou,
  import založí, aby zůstala historie i počty přehraných dílů.
- Feedy čte jen server, aplikace ne. Server je stahuje každou hodinu, podmíněně přes `ETag`
  a `Last-Modified`, po chybách s delší prodlevou. Potažením seznamu dolů nebo ikonou ⟳
  v záhlaví se stáhnou hned.
- Zrušení odběru jen zastaví stahování feedu. Díly i jejich stav zůstanou a nové přidání stejné
  adresy odběr obnoví.
- Seznam podcastů je řazený podle počtu přehraných dílů, po přepnutí abecedně.
- Detail podcastu ukazuje díly od nejnovějšího a u každého stav: nový, rozposlouchaný se
  zbývajícím časem, přehraný, vyřazený, stažený. Popis dílu je prostý text s klikacími odkazy.
- Hledat jde v jednom podcastu nebo přes nabídku „Hledat“ ve všech odběrech. Hledání ve všech
  odběrech ukáže podcasty podle názvu a až 100 odpovídajících dílů od nejnovějšího. Názvy fungují
  i bez připojení, výsledky z popisů dílů doplní server.
- **Rozposlouchané:** díly, které nejsou přehrané ani vyřazené a mají pozici aspoň jednu minutu,
  naposledy poslouchané nahoře. Samostatný seznam, nezávislý na frontě. Díl s menší pozicí zůstává
  mezi novými, takže omylem puštěný díl seznam nezaplevelí. Všechna zařízení to odvozují stejně,
  jen ze stavu dílu.
- **Fronta:** ručně seřazené díly, které se mají poslouchat. Přehrané a vyřazené díly v ní nejsou
  vidět a nepřehrávají se.
- **Vyřadit díl** („už nechci poslouchat“, název akce: O21): díl zmizí z rozposlouchaných, z fronty
  i z nových dílů a pozice se vynuluje. Každé zařízení smaže stažený soubor dílu, jakmile se
  o vyřazení dozví. Mezi přehrané se nepočítá, takže neovlivní ani řazení podcastů podle počtu
  přehraných dílů. V detailu podcastu zůstane označený jako vyřazený (O21). Když se díl pustí
  znovu, vyřazení se zruší a díl začne hrát od začátku. Vyřadit lze i dosud nepuštěný díl,
  přehraný ne.
- Hromadná akce „vyřadit tento a starší díly“ v detailu podcastu vyřadí vybraný díl a všechny
  starší díly, ale jen ty ve stavu „nový“: rozposlouchaných, přehraných a dílů ve frontě se
  nedotkne. Díly neoznačí jako přehrané, takže neovlivní počty přehraných dílů.
- Ruční akce „označit jako přehrané“ (třeba po poslechu jinde) a „vrátit mezi nové“ (od začátku).
- Nové díly napříč odběry (O7). Ve výchozím stavu se zobrazují díly ze všech odběrů a volbou
  „Zobrazovat v Nových dílech“ na stránce „O podcastu“ lze jednotlivý podcast ze seznamu skrýt.
  Změna se po připojení synchronizuje přes server mezi zařízeními.

### 4.2 Přehrávání

- Díly se přehrávají přímo z adresy vydavatele, server je nestahuje ani nepřeposílá. Povolené jsou
  i adresy `http://`, protože některé feedy https nemají.
- Stažení do telefonu pro poslech bez sítě (O12).
- Ovládání: přehrát a pauza, skok zpět a vpřed (O9). Rychlost a časovač spánku (O8) jsou
  ve výchozím stavu skryté; ukáže je jeden přepínač v Nastavení.
- Oznámení a zamykací obrazovka s ovládáním (posuvník: O10).
- Sluchátka a Bluetooth: pauza, pokračování, „další“ a „předchozí“ (O9).
- Android Auto: Rozposlouchané, Fronta, Stažené a Podcasty s díly, skoky zpět a vpřed. Funguje
  i se zavřenou aplikací.
- Díl se označí jako přehraný, až když přehrávač ohlásí jeho skutečný konec (O13), a začne hrát
  další díl z fronty. Pauza těsně před koncem díl nechá rozposlouchaný, takže závěr se nikdy
  neusekne. Automatické pokračování je zapnuté a v nastavení ho lze vypnout. Spánek „do konce
  dílu“ zastaví přehrávání dřív, než začne další díl.
- Délka dílu se bere z přehrávače, ne z feedu. Feedy ji často neuvádějí nebo uvádějí špatně,
  třeba kvůli dynamicky vkládaným reklamám. Zařízení posílá změřenou délku se stavem dílu, takže
  zbývající čas ukážou i ostatní zařízení.

### 4.3 PC

- Stejná aplikace pro Linux: přehrávání, rozposlouchané, fronta, podcasty s díly, označení
  přehraných a vyřazení. Stahování pro poslech bez sítě tu není potřeba, takže odpadá
  i obrazovka Stažené.
- Písmo a velikost podle GTK, mediální klávesy přes MPRIS.
- Aplikace po spuštění zůstane přihlášená (desktopová verze PinePods se vracela na přihlašovací
  obrazovku, #934).
- Webová verze: O16.

## 5. Co systém dělat nebude

- video a YouTube, přepisy, AI;
- doporučování a objevování, komentáře, hodnocení, sdílení;
- štítky, inbox, chytré playlisty, statistiky kromě počtu přehraných dílů;
- upozornění na nové díly;
- stahování, převod a přeposílání dílů na serveru;
- více uživatelů (O17);
- iOS, Windows a macOS;
- gPodder API (O18);
- rozšíření Podcasting 2.0 (kapitoly: O8).

## 6. Synchronizace

Co nejjednodušší pravidla. Každé míří na konkrétní selhání z listopadu.

1. **Stav dílu** drží server: pozici, stav (žádný, přehráno nebo vyřazeno), délku změřenou
   přehrávačem a čas změny podle hodin zařízení. Klíčem je ID dílu, které přidělil server. Seznam
   dílů vede server; aplikace díly nepáruje podle vlastního čtení feedu. Když aplikace dostane stav
   nebo místo ve frontě pro díl, který ještě nemá, uloží si je a díl si stáhne ze serveru; nikdy je
   nezahodí. AntennaPod takové pozice zahazoval.
2. **Zařízení posílá stav dílu** při každé jeho změně: při každé pauze včetně automatické (vytažení
   sluchátek, hovor, převzetí zvuku jinou aplikací), při skoku a posunu, na konci dílu, při vyřazení
   a ručním označení a během přehrávání pravidelně (O19). Stav nese čas, kdy změna na zařízení
   nastala, a tento čas se nemění, ani když se stav odešle později. Co nelze odeslat (zařízení je
   bez sítě, server neodpovídá nebo hlásí chybu), si zařízení pamatuje, u každého dílu jen poslední
   stav, a zkouší to znovu: s rostoucí prodlevou, dokud proces aplikace běží, i na pozadí, a navíc
   při každém spuštění aplikace, návratu do popředí, přechodu na pozadí a zavření. U PinePods se
   automatická pauza neuložila (#1050) a Palma 22. 11. odeslala večerní pozici až ráno.
3. **Server stav přijme, jen když je novější** než ten uložený. Rozhoduje čas změny ze zařízení,
   ne pořadí doručení, takže pozdě odeslaný poslech bez sítě nepřepíše novější poslech z jiného
   zařízení. Přetočení zpět je obyčejný novější stav a projde všude (PinePods 0.9.2 ho
   nepřenese). Hodiny zařízení se seřizují ze sítě, víc není potřeba.
4. **Před spuštěním přehrávání** a před pokračováním nebo posunem dílu, který je déle než 30 s
   pozastavený, se zařízení zeptá serveru na stav dílu, počká na odpověď nejvýš 2 s a novější stav
   převezme (AntennaPod #5444). Platí to bez ohledu na to, odkud pokyn přišel: z aplikace, oznámení,
   zamykací obrazovky, sluchátek, Bluetooth nebo Android Auto. Když je díl mezitím jinde přehraný
   nebo vyřazený, automatické pokračování fronty ho přeskočí a ruční spuštění ho přehraje od
   začátku. Bez odpovědi do 2 s hraje zařízení z vlastní pozice (známé omezení).
5. **Zařízení, které právě hraje,** nepřevezme pozici hraného dílu od ostatních zařízení.
6. **Celý stav najednou:** zařízení si stáhne stav všech dílů a frontu při spuštění, po návratu do
   popředí, po odeslání změn, které čekaly bez sítě, a dokud je aplikace otevřená, pravidelně. Ze
   seznamů dílů stáhne jen ty, které se změnily. Předtím vždy odešle, co čeká. Novější stavy dílů i
   frontu převezme i s časem ze serveru a zpátky je neposílá. Pro jednoho posluchače jsou to
   kilobajty, takže odpadá zjišťování „co se změnilo od minula“, na kterém gPodder servery ztrácely
   pozdní změny.
7. **Žádná magická čísla:** pozice je vždy ≥ 0, přehráno a vyřazeno jsou samostatné stavy a nic
   se neodvozuje z délky ve feedu (AntennaPod #7080, Kasts). Po konci dílu, vyřazení nebo ručním
   označení už přehrávač pozici toho dílu neposílá, dokud se díl znovu nespustí, takže tyto stavy
   nepřepíše žádná pozdější pozice.
8. **Fronta** se posílá celá, s časem změny ze zařízení, a platí novější verze. Mění ji jen ruční
   úprava (přidání, odebrání, přesun) a před ní si zařízení stáhne aktuální frontu ze serveru, pokud
   to stihne do 2 s. Konec dílu ani vyřazení frontu nemění: přehrané a vyřazené díly fronta jen
   skryje a z uložené fronty zmizí při příští ruční úpravě. Přidání přehraného nebo vyřazeného dílu
   do fronty ho vrátí mezi nové.
9. **Odběry** se mění jen online, přímo na serveru. Přidání podcastu totiž vyžaduje stažení
   feedu.

## 7. Server

- Go, jedna binárka. Image pro arm64 se sestavuje v GitHub Actions a ukládá do ghcr.io; na M1S
  server běží jako kontejner v Quadletu.
- Vlastní databáze a role ve sdíleném PostgreSQL. Role vidí jen svou databázi (PinePods potřeboval
  přístup k databázi `postgres`, #1119). Databáze je v noční záloze od prvního dne.
- Feedy čte knihovna gofeed. Díl se páruje podle GUID, bez GUID podle adresy souboru. Když se
  změní jen adresa souboru, server ji přepíše. Díly, které z feedu zmizí, server nemaže.
- U každého feedu je v aplikaci vidět čas posledního úspěšného stažení a poslední chyba.
- Kód pro import z PinePods lze převzít z Pocket Podcasts (MIT).
- `/health` pro Gatus.
- Adresa: `easypodcast.jiri.one` (O2). Přístup z domácí sítě: O20.

Datový model (náčrt):

| Tabulka | Obsah |
|---|---|
| `podcasts` | adresa feedu, název, odebírá se (ano, ne), `ETag`, `Last-Modified`, stav feedu |
| `episodes` | podcast, GUID, adresa souboru, název, datum, délka z feedu, popis, zmizel z feedu |
| `episode_state` | díl, pozice, stav (žádný, přehráno, vyřazeno), délka z přehrávače, čas změny ze zařízení |
| `queue` | díly v pořadí, čas změny ze zařízení |
| `devices` | název, otisk tokenu, poslední spojení |

API (náčrt, JSON):

| Volání | Účel |
|---|---|
| `POST /api/login` | jméno, heslo a název zařízení → token zařízení |
| `POST /api/logout` | zrušit token tohoto zařízení |
| `GET /api/state` | stav všech dílů a fronta |
| `POST /api/state` | dávka stavů dílů, případně fronta |
| `GET /api/episodes/{id}/state` | rychlý dotaz před spuštěním (pravidlo 4) |
| `GET /api/podcasts` | odběry a stav feedů |
| `GET /api/podcasts/{id}/episodes` | díly podcastu, s `ETag` |
| `GET /api/episodes/{id}` | díl s popisem, až když se otevře |
| `POST /api/podcasts`, `DELETE /api/podcasts/{id}` | přidat a zrušit odběr (díly i stav zůstanou) |
| `POST /api/refresh` | stáhnout feedy hned |
| `GET` a `POST /api/opml` | export a import |
| `GET /health` | pro Gatus |

## 8. Klient

- Flutter, jeden kód pro Android a Linux. Minimálně Android 11 kvůli Palmě (O5).
- Knihovny: just_audio s audio_service (oznámení, sluchátka, Android Auto), na Linuxu media_kit
  a MPRIS, sqflite (SQLite) pro místní data a neodeslané stavy, background_downloader pro
  stahování.
- Místní kopie odběrů, dílů a stavu. Bez sítě funguje všechno kromě nových dílů, změn odběrů,
  popisů dílů a přehrávání nestažených dílů.
- Když nic nehraje, aplikace na pozadí jen dokončuje rozběhnutá stahování a odesílání čekajících
  změn, to druhé jen dokud běží její proces (pravidlo 2). Aplikace PinePods podle #794 spotřebovala
  64 % baterie.
- Oprávnění jen pro síť, oznámení a přehrávání na pozadí (aplikace PodFetch chce i mikrofon).
- Jazyk: čeština a angličtina (O4).

### 8.1 E-ink

- Jen černá a bílá. Šedá nanejvýš pro vedlejší text, s kontrastem aspoň 7 : 1.
- Žádné animace, přechody obrazovek ani vlnky po dotyku.
- Nevybrané položky dolní lišty tmavé (PinePods je má světle šedé), ikony černé, karty a pole
  s obrysem místo stínu.
- Žádné barvy z obrázků ani barevné přechody. Obrázky: O11.
- Velké dotykové plochy, text u ikon, kde ikona sama nestačí.
- Rozvržení už od šířky 250 logických bodů (HiBreak).
- Čas přehrávání se obnovuje jen občas (O15), aby se displej zbytečně nepřekresloval.

### 8.2 Obrazovky (návrh)

1. **Rozposlouchané:** naposledy poslouchané nahoře.
2. **Fronta.**
3. **Podcasty**, odtud detail podcastu s díly.
4. **Nové díly** (O7).
5. **Stažené.**
6. **Přehrávač:** otevře se z malého přehrávače nad dolní lištou.
7. **Nastavení:** server a přihlášení, skoky, přepínač rychlosti a časovače spánku (rychlost jen
   když je zapnutý), pokračování fronty, stahování, stav feedů.

Dolní lišta: Rozposlouchané, Fronta, Podcasty a Stažené. Do šířky HiBreaku se vejdou čtyři
položky s krátkými popisky, pátá už těžko (O7).

### 8.3 Distribuce a licence

- APK podepsané vlastním klíčem a instalace přes adb, jako dnes testovací build PinePods E-Ink.
  Později vlastní F-Droid repozitář, aby aktualizace hlídal Droid-ify.
- Veřejný repozitář `github.com/jiri-one/easypodcast`, licence GPL-3.0 jako u ostatních aplikací
  (O3).
- Převzatý kód: Anytime Podcast Player (BSD-3), Pocket Podcasts (MIT) a díky GPL i PinePods
  (GPL-3.0), vždy s uvedením autora.

## 9. Bezpečnost a soukromí

- Jeden uživatel. Heslo se nastavuje příkazem na serveru a zadává ho člověk, nic se negeneruje.
- Aplikace pošle heslo jen při přihlášení, potom používá token zařízení. Tokeny lze vypsat
  a rušit jednotlivě příkazem na serveru, třeba po ztrátě telefonu. Odhlášení v aplikaci zruší
  token toho zařízení.
- Omezený počet pokusů o přihlášení, žádná registrace.
- Hesla ani tokeny se nikdy nedostanou do logu.
- Žádná telemetrie. Navenek se server připojuje jen k adresám feedů (a k adresáři podcastů, O14).

## 10. Postup

| Etapa | Obsah | Hotovo, když |
|---|---|---|
| E0 | specifikace, název (O1), repozitář (O3), projekt v `~/dev` a v T3 | specifikace je schválená |
| E1 | server na `easypodcast.jiri.one`, import z PinePods, nasazení vedle PinePods, záloha, Gatus | server drží stejné odběry a stav jako PinePods |
| E2 | Android: přihlášení, rozposlouchané, podcasty, díly, vyřazení, streamování, stahování, oznámení, sluchátka, synchronizace | projdou scénáře 1, 3, 4 a 7 až 11 mezi HiBreakem a Palmou |
| E3 | Android: fronta, Android Auto, poslední import z PinePods | projdou scénáře 2 a 5 a dva týdny poslechu proběhnou bez PinePods |
| E4 | Linux (případně web) | projde scénář 6 a díl dohraný v autě (scénář 2) je přehraný i na PC |
| E5 | vypnout PinePods a goPodder, smazat testovací buildy PinePods E-Ink, doplnit README m1s-hosting | nic starého neběží |

Volitelně po E5: živé změny přes SSE, díky kterým otevřená aplikace hned uvidí, co se děje na
jiném zařízení.

## 11. Akceptační scénáře

| # | Scénář | Co má platit |
|---|---|---|
| 1 | pauza vytažením sluchátek nebo hovorem | server má pozici z okamžiku pauzy |
| 2 | dohrání dílu v autě | díl je přehraný i na Palmě, fronta pokračuje |
| 3 | přetočení zpět na HiBreaku | Palma pokračuje od přetočené pozice |
| 4 | Palma hraje bez sítě, potom pokračuje HiBreak, nakonec se Palma připojí | zůstane novější pozice z HiBreaku |
| 5 | Android Auto: procházení, skoky, start se zavřenou aplikací | ovládání funguje, pozice dorazí na server |
| 6 | PC po poslechu v telefonu | PC pokračuje od pozice z telefonu |
| 7 | systém ukončí aplikaci během přehrávání | ztratí se nejvýš poslech za jeden interval z O19 |
| 8 | pozice pro nový díl, který druhé zařízení ještě nemá | druhé zařízení dostane díl i pozici |
| 9 | díl vyřazený na HiBreaku | na Palmě zmizí z rozposlouchaných, smaže se stažený soubor a mezi přehrané se nepočítá |
| 10 | restart M1S během poslechu | žádný stav se neztratí |
| 11 | Palma hraje bez sítě, po pauze se připojí k Wi-Fi a aplikaci na ní nikdo neotevře, potom pokračuje HiBreak | pokud proces aplikace na Palmě ještě běží, HiBreak pokračuje od pozice z Palmy; jinak jen tehdy, když se aplikace na Palmě otevře dřív, než HiBreak začne hrát (oddíl 12) |

## 12. Známá omezení

- Dynamicky vkládané reklamy: stejný díl může mít na dvou zařízeních jinak dlouhé reklamy, takže
  stejný čas nemusí znamenat stejné místo. Týká se všech přehrávačů.
- Android Auto u aplikací mimo Google Play vyžaduje vývojářskou volbu.
- Pořadí stavů určují hodiny zařízení. Ty se seřizují ze sítě a jsou přesné na sekundy. Zařízení
  s ručně špatně nastaveným časem by pořadí pokazilo.
- Zařízení, které začne hrát bez spojení se serverem nebo bez jeho odpovědi do 2 s, hraje
  z pozice, kterou zná. Jeho poslech je novější, takže přepíše i pozici z jiného zařízení,
  která je v dílu dál.
- Neodeslaný stav se odešle, jen pokud proces aplikace ještě běží, nebo až při jejím dalším
  spuštění; odesílání tato verze nesvěřuje systémové úloze na pozadí (WorkManager). Po pauze zůstává
  oznámení přehrávače, takže proces obvykle běží dál. Když ho systém ukončí, dorazí změna až po
  dalším otevření aplikace. Jiné zařízení, které mezitím začne hrát, pokračuje ze starší pozice a
  jeho novější poslech pak platí (scénář 11).
- Když se fronta upraví na zařízení, které nemá její aktuální verzi (třeba na Palmě bez sítě),
  platí po připojení celá jen novější z obou verzí a úpravy v té druhé se ztratí.

## 13. Otevřené otázky

- **O1 Název** (rozhodnuto): EasyPodcast, jedno jméno pro repozitář, službu, adresu i aplikaci.
- **O2 Adresa** (rozhodnuto): `easypodcast.jiri.one`. goPodder si `podcast.jiri.one` ponechá,
  dokud se nevypne.
- **O3 Repozitář a licence** (rozhodnuto): veřejný repozitář `github.com/jiri-one/easypodcast`
  s licencí GPL-3.0 jako ostatní aplikace, takže lze převzít i kód z PinePods.
- **O4 Jazyk rozhraní** (rozhodnuto): čeština a angličtina, jako EasyDict a EasyTimer.
- **O5 Zařízení:** počítat i s Leaf2 (pak možná starší Android)? Je telefon v autě HiBreak?
- **O6 Fronta** (rozhodnuto): používá se a po dohrání dílu se automaticky přehraje další díl z ní.
  Automatické pokračování je ve výchozím nastavení zapnuté.
- **O7 Nové díly:** samostatná obrazovka napříč odběry, nebo stačí detail podcastu?
- **O8 Přehrávání:** jedna rychlost pro všechny podcasty, nebo pro každý zvlášť? Časovač spánku?
  Přeskakování ticha? Kapitoly?
- **O9 Skoky:** návrh 15 s zpět a 30 s vpřed. Co mají dělat tlačítka „další“ a „předchozí“ na
  sluchátkách a v autě (návrh: skok vpřed a zpět)?
- **O10 Posuvník v oznámení a na zamykací obrazovce:** vypnout? Nechtěný dotyk na něm nejspíš
  10. 11. posunul díl o 4 minuty zpět.
- **O11 Obrázky podcastů:** malé a šedé, nebo vůbec žádné?
- **O12 Stahování do telefonu:** jen ručně, nebo automaticky (třeba díly ve frontě, jen na
  Wi-Fi)? Mazat stažené po dohrání?
- **O13 Přehráno (rozhodnuto):** až když přehrávač ohlásí skutečný konec. Původní návrh s 30 s
  před koncem usekával závěr dílu. Nové spuštění přehraného dílu zruší označení a díl hraje od
  začátku, po minutě poslechu je tedy znovu mezi rozposlouchanými.
- **O14 Hledání podcastů:** v adresáři Apple (bez klíče), nebo stačí vložit adresu feedu?
- **O15 Čas na e-inku:** jak často ho během přehrávání obnovovat?
- **O16 Web:** stačí aplikace pro Linux, nebo i verze do prohlížeče (ze stejného kódu)?
- **O17 Uživatelé:** opravdu jen jeden?
- **O18 gPodder API:** podporovat ho, aby se AntennaPod dal použít jako záložní klient? Návrh: ne.
- **O19 Interval:** jak často posílat pozici během přehrávání? Návrh: 30 s; častější odesílání
  je přesnější, ale spotřebuje víc baterie.
- **O20 Domácí síť:** vždy přes Cloudflare, nebo i přímo na M1S s vlastní CA, jako u Lissenu?
- **O21 Vyřazení:** jak se má akce jmenovat (Vyřadit, Nechci, Reset)? Mají vyřazené díly
  v detailu podcastu zůstat vidět, nebo zmizet úplně?
