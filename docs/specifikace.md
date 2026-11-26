# Podcastová aplikace: koncept specifikace

Koncept k úpravě z 26. 11. 2026. Vychází ze zkušeností s goPodderem, AntennaPodem, Kasts,
Audiobookshelfem a PinePods a z rešerše alternativ z 25. 11. Všechno je návrh. Místa, která je
potřeba rozhodnout, odkazují na otevřené otázky na konci (O1 až O21).

Úpravy podle prvních poznámek (26. 11.): jednodušší synchronizace s jediným časem z telefonu,
rozposlouchané díly odděleně od fronty a vyřazení dílu („už nechci poslouchat“).

## 1. Cíl

Malý vlastní systém na poslech podcastů pro jednoho posluchače: server v Go na M1S a klient ve
Flutteru pro Android a Linux. Nahradí PinePods i goPodder. Umí méně než oni, ale co umí, funguje
spolehlivě.

Hotovo je, když:

- poslech jde předávat mezi HiBreakem, Palmou, autem a PC bez ztráty pozice a bez skoků zpět;
- všechno se dobře čte a ovládá na e-inku;
- dva týdny každodenního poslechu proběhnou bez PinePods.

## 2. Proč ne hotové řešení

- **goPodder s AntennaPodem a Kasts:** předávání rozbíjely chyby v aplikacích. AntennaPod #5444
  (načtený přehrávač si nechá starou pozici), #7080 (pozice −1 vrátí díl na začátek) a zahazování
  pozic pro díly, které telefon ještě nezná. Kasts označí díl za přehraný, když feed neuvádí
  délku. K listopadu 2026 není opravená žádná z těch chyb.
- **Audiobookshelf:** přehraje jen díly stažené na server a autor streamování odmítl.
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
| Sluchátka | Galaxy Buds 2 | pauza, pokračování, další, předchozí |
| PC | Manjaro, niri (Wayland), písmo z GTK (Liberation Sans 18, bez vyhlazování) | občas |
| Server | Odroid M1S (ARM64): rootless Podman a Quadlet, sdílený PostgreSQL, Caddy, Cloudflare Tunnel, Gatus, noční záloha | – |

Aplikace se do telefonů instalují mimo Google Play, takže Android Auto vyžaduje vývojářskou volbu
„Neznámé zdroje“.

## 4. Co systém umí

### 4.1 Odběry a díly

- Nový podcast se přidá vložením adresy feedu (hledání v adresáři: O14).
- Import a export OPML. Jednorázový import z PinePods: odběry, pozice i s časy, přehrané díly,
  fronta a počty přehrání.
- Feedy čte jen server, aplikace ne. Server je stahuje každou hodinu, podmíněně přes `ETag`
  a `Last-Modified` a po chybách s prodlevou. Tlačítkem Obnovit je stáhne hned.
- Po odhlášení odběru zůstane stav dílů uložený pro případ návratu.
- Seznam podcastů je řazený podle počtu přehraných dílů, na přepnutí abecedně.
- Detail podcastu ukazuje díly od nejnovějšího a u každého stav: nový, rozposlouchaný se
  zbývajícím časem, přehraný, vyřazený, stažený. Popis dílu je prostý text s klikacími odkazy.
- **Rozposlouchané:** díly, které mají pozici a nejsou přehrané ani vyřazené, naposledy
  poslouchané nahoře. Samostatný seznam, nezávislý na frontě. Díl se sem dostane až po minutě
  poslechu, takže omylem puštěný díl seznam nezaplevelí.
- **Fronta** (O6): ručně seřazené díly, které se mají poslouchat.
- **Vyřadit díl** („už nechci poslouchat“, název akce: O21): díl zmizí z rozposlouchaných, z fronty
  i z nových dílů, stažený soubor se smaže a pozice se vynuluje. Mezi přehrané se nepočítá, takže
  neovlivní ani řazení podle poslechu. V detailu podcastu zůstane označený jako vyřazený. Když se
  pustí znovu, vyřazení se zruší a hraje od začátku. Vyřadit jde i dosud nepuštěný díl.
- Hromadná akce „vyřadit starší díly“. Jako přehrané se označují jen díly opravdu doposlouchané.
- Ruční „označit jako přehrané“ (třeba po poslechu jinde) a „vrátit mezi nové“.
- Nové díly napříč odběry (O7).

### 4.2 Přehrávání

- Díly hrají přímo z adresy vydavatele, server je nestahuje ani nepřeposílá. Povolené jsou
  i adresy `http://`, protože některé feedy https nemají.
- Stažení do telefonu pro poslech bez sítě (O12).
- Ovládání: přehrát a pauza, skok zpět a vpřed (O9), rychlost a časovač spánku (O8).
- Notifikace a zamykací obrazovka s ovládáním (posuvník: O10).
- Sluchátka a Bluetooth: pauza, pokračování, další a předchozí (O9).
- Android Auto: Rozposlouchané, Fronta, Stažené a Podcasty s díly, skoky zpět a vpřed. Funguje
  i se zavřenou aplikací.
- Na konci se díl označí jako přehraný (O13) a hraje další z fronty (O6).
- Délka dílu se bere z přehrávače, ne z feedu. Feedy ji často neuvádějí nebo uvádějí špatně,
  třeba kvůli dynamicky vkládaným reklamám.

### 4.3 PC

- Stejná aplikace pro Linux: přehrávání, přehled, rozposlouchané, fronta, označení přehraných
  a vyřazení. Stahování pro poslech bez sítě tu netřeba.
- Písmo a velikost podle GTK, mediální klávesy přes MPRIS.
- Po spuštění zůstane přihlášená (desktop PinePods se vracel na přihlášení, #934).
- Webová verze: O16.

## 5. Co systém dělat nebude

- video a YouTube, přepisy, AI;
- doporučování a objevování, komentáře, hodnocení, sdílení;
- štítky, inbox, chytré playlisty, statistiky kromě počtu přehrání;
- upozornění na nové díly;
- stahování, převod a přeposílání dílů na serveru;
- více uživatelů (O17);
- iOS, Windows a macOS;
- gPodder API (O18);
- rozšíření Podcasting 2.0 (kapitoly: O8).

## 6. Synchronizace

Co nejjednodušší pravidla. Každé míří na konkrétní selhání z listopadu.

1. **Stav dílu** drží server: pozici, stav (žádný, přehráno, nebo vyřazeno) a čas, kdy ho telefon
   nastavil, podle hodin telefonu. Klíčem je díl s ID ze serveru. Seznam dílů vede server
   a aplikace je nepáruje podle vlastního čtení feedu, takže nikdy nedostane pozici pro díl,
   který nezná. AntennaPod takové pozice zahazoval.
2. **Telefon posílá stav dílu** při každé pauze včetně automatické (vytažení sluchátek, hovor,
   ztráta zvukového fokusu), při skoku a posunu, na konci dílu, při vyřazení, při zavření aplikace
   a během přehrávání pravidelně (O19). Bez sítě si u každého dílu pamatuje poslední neodeslaný
   stav a po připojení ho pošle. U PinePods se pauza, kterou nespustil člověk, neuložila (#1050)
   a Palma 22. 11. odeslala večerní pozici až ráno.
3. **Server stav přijme, jen když je novější** než ten uložený. Rozhoduje čas z telefonu, ne
   pořadí doručení, takže pozdě odeslaný poslech bez sítě nepřepíše novější poslech z jiného
   zařízení. Přetočení zpět je obyčejný novější stav a projde všude (PinePods 0.9.2 ho
   nepřenese). Hodiny telefonů se seřizují ze sítě, víc není potřeba.
4. **Před spuštěním přehrávání** se telefon zeptá serveru na stav dílu, s limitem asi 2 s,
   a novější stav převezme. Totéž udělá po návratu aplikace do popředí (AntennaPod #5444).
5. **Zařízení, které právě hraje,** si pozici podle ostatních nemění.
6. **Celý stav najednou:** při synchronizaci si telefon stáhne stav všech dílů a frontu, seznamy
   dílů jen změněné (podle `ETag`). Pro jednoho posluchače jsou to kilobajty, takže odpadá
   zjišťování „co se změnilo od minula“, na kterém gPodder servery ztrácely pozdní změny.
7. **Žádná magická čísla:** pozice je vždy ≥ 0, přehráno a vyřazeno jsou samostatné stavy a nic
   se neodvozuje z délky ve feedu (AntennaPod #7080, Kasts).
8. **Fronta** se posílá celá, také s časem z telefonu, a platí novější.
9. **Odběry** se mění jen online, přímo na serveru. Přidání podcastu stejně potřebuje stáhnout
   feed.
10. **Živé změny** přijdou později přes SSE: otevřená aplikace pak hned uvidí, co se děje jinde.

## 7. Server

- Go, jedna binárka. Image pro arm64 staví GitHub Actions do ghcr.io a na M1S běží jako kontejner
  v Quadletu.
- Vlastní databáze a role ve sdíleném PostgreSQL. Role vidí jen svou databázi (PinePods potřeboval
  přístup k databázi `postgres`, #1119). Databáze je v noční záloze od prvního dne.
- Feedy čte knihovna gofeed. Díl se páruje podle GUID, bez GUID podle adresy souboru. Když se
  změní jen adresa souboru, server ji přepíše.
- U každého feedu je v aplikaci vidět poslední úspěch a poslední chyba.
- Importér z PinePods jde převzít z Pocket Podcasts (MIT).
- `/health` pro Gatus.
- Adresa: O2. Přístup z domácí sítě: O20.

Datový model (náčrt):

| Tabulka | Obsah |
|---|---|
| `podcasts` | adresa feedu, název, `ETag`, `Last-Modified`, stav feedu |
| `episodes` | podcast, GUID, adresa souboru, název, datum, délka z feedu, popis |
| `episode_state` | díl, pozice, stav (přehráno, vyřazeno), čas z telefonu |
| `queue` | díly v pořadí, čas z telefonu |
| `devices` | název, otisk tokenu, poslední spojení |

API (náčrt, JSON):

| Volání | Účel |
|---|---|
| `POST /api/login` | jméno a heslo → token zařízení |
| `GET /api/state` | stav všech dílů a fronta |
| `POST /api/state` | dávka stavů dílů, případně fronta |
| `GET /api/episodes/{id}/state` | rychlý dotaz před spuštěním (pravidlo 4) |
| `GET /api/podcasts` | odběry a stav feedů |
| `GET /api/podcasts/{id}/episodes` | díly podcastu, s `ETag` |
| `GET /api/episodes/{id}/description` | popis dílu, až když se otevře |
| `POST /api/podcasts`, `DELETE /api/podcasts/{id}` | přidat a odebrat odběr |
| `POST /api/refresh` | stáhnout feedy hned |
| `GET` a `POST /api/opml` | export a import |
| `GET /health` | pro Gatus |

## 8. Klient

- Flutter, jeden kód pro Android a Linux. Minimálně Android 11 kvůli Palmě (O5).
- Knihovny (návrh): just_audio s audio_service (notifikace, sluchátka, Android Auto), na Linuxu
  media_kit a MPRIS, drift (SQLite) pro místní data a neodeslané stavy, background_downloader pro
  stahování.
- Místní kopie odběrů, dílů a stavu. Bez sítě funguje všechno kromě nových dílů a přidání
  podcastu.
- Když nic nehraje, aplikace na pozadí nepracuje (aplikace PinePods podle #794 spotřebovala 64 %
  baterie).
- Oprávnění jen pro síť, notifikace a přehrávání na pozadí (aplikace PodFetch chce i mikrofon).
- Jazyk: O4.

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
3. **Podcasty**, z nich detail podcastu s díly.
4. **Nové díly** (O7).
5. **Stažené.**
6. **Přehrávač:** otevře se z malého přehrávače nad dolní lištou.
7. **Nastavení:** server a přihlášení, skoky, rychlost, stahování, stav feedů.

Dolní lišta: Rozposlouchané, Fronta, Podcasty a Stažené. Na šířku HiBreaku se čtyři položky
s krátkými popisky vejdou, pátá už těžko (O7).

### 8.3 Distribuce a licence

- APK podepsané vlastním klíčem a instalace přes adb, jako dnes testovací build PinePods E-Ink.
  Později vlastní F-Droid repozitář, aby aktualizace hlídal Droid-ify.
- Převzatý kód: Anytime Podcast Player (BSD-3) a Pocket Podcasts (MIT) s uvedením autora.
  PinePods (GPL-3.0) jen tehdy, když bude i naše licence GPL (O3).

## 9. Bezpečnost a soukromí

- Jeden uživatel. Heslo se nastavuje příkazem na serveru a zadává ho člověk, nic se negeneruje.
- Aplikace pošle heslo jen při přihlášení, potom používá token zařízení. Tokeny jdou rušit
  jednotlivě, třeba po ztrátě telefonu.
- Omezený počet pokusů o přihlášení, žádná registrace.
- Hesla ani tokeny se nikdy nedostanou do logu.
- Žádná telemetrie. Ven server mluví jen s feedy (a s adresářem podcastů, O14).

## 10. Postup

| Etapa | Obsah | Hotovo, když |
|---|---|---|
| E0 | specifikace, název, repozitář, projekt v `~/dev` a v T3 | specifikace je schválená |
| E1 | server, import z PinePods, nasazení vedle PinePods, záloha, Gatus | server drží stejné odběry a stav jako PinePods |
| E2 | Android: přihlášení, rozposlouchané, podcasty, díly, vyřazení, streamování, notifikace, sluchátka, synchronizace | projdou scénáře 1, 3, 4 a 7 až 10 mezi HiBreakem a Palmou |
| E3 | Android: stahování, fronta, Android Auto | projdou scénáře 2 a 5 a dva týdny poslechu bez PinePods |
| E4 | Linux (případně web) | projde scénář 6 |
| E5 | vypnout PinePods a goPodder, převzít adresu, smazat testovací buildy PinePods E-Ink, doplnit README m1s-hosting | nic starého neběží |

## 11. Akceptační scénáře

| # | Scénář | Co má platit |
|---|---|---|
| 1 | pauza vytažením sluchátek nebo hovorem | server má pozici z okamžiku pauzy |
| 2 | dohrání dílu v autě | díl je přehraný i na Palmě a PC, fronta pokračuje |
| 3 | přetočení zpět na HiBreaku | Palma pokračuje od přetočené pozice |
| 4 | Palma hraje bez sítě, potom pokračuje HiBreak, nakonec se Palma připojí | zůstane novější pozice z HiBreaku |
| 5 | Android Auto: procházení, skoky, start se zavřenou aplikací | ovládání funguje, pozice dorazí na server |
| 6 | PC po poslechu v telefonu | PC pokračuje od pozice z telefonu |
| 7 | systém zabije aplikaci během přehrávání | ztratí se nejvýš interval z O19 |
| 8 | pozice pro nový díl, který druhé zařízení ještě nemá | druhé zařízení dostane díl i pozici |
| 9 | díl vyřazený na HiBreaku | na Palmě zmizí z rozposlouchaných a mezi přehrané se nepočítá |
| 10 | restart M1S během poslechu | žádný stav se neztratí |

## 12. Známá omezení

- Dynamicky vkládané reklamy: stejný díl může mít na dvou zařízeních jinak dlouhé reklamy, takže
  stejný čas nemusí znamenat stejné místo. Týká se všech přehrávačů.
- Android Auto u aplikací mimo Google Play vyžaduje vývojářskou volbu.
- Pořadí stavů určují hodiny telefonů. Ty se seřizují ze sítě a sedí na sekundy. Zařízení
  s ručně špatně nastaveným časem by pořadí pokazilo.
- Když se fronta upraví na dvou zařízeních a mezi úpravami se ani jedno nespojí se serverem,
  platí jen novější z obou verzí.

## 13. Otevřené otázky

- **O1 Název:** jak se to bude jmenovat? Jedno jméno pro repozitář, službu, adresu i aplikaci.
- **O2 Adresa:** převzít `podcast.jiri.one` po vypnutí goPodderu, nebo novou?
- **O3 Repozitář a licence:** veřejný, nebo soukromý? MIT, nebo GPL-3.0 (pak jde převzít i kód
  z PinePods)?
- **O4 Jazyk rozhraní:** jen čeština, nebo i angličtina?
- **O5 Zařízení:** počítat i s Leaf2 (pak možná starší Android)? Je telefon v autě HiBreak?
- **O6 Fronta:** používá se. Má po dohrání automaticky hrát další díl z fronty?
- **O7 Nové díly:** samostatná obrazovka napříč odběry, nebo stačí detail podcastu?
- **O8 Přehrávání:** rychlost jedna pro všechno, nebo pro každý podcast? Časovač spánku?
  Přeskakování ticha? Kapitoly?
- **O9 Skoky:** návrh 15 s zpět a 30 s vpřed. Co mají dělat tlačítka další a předchozí na
  sluchátkách a v autě (návrh: skok vpřed a zpět)?
- **O10 Posuvník v notifikaci a na zamykací obrazovce:** vypnout? Nechtěný dotyk na něm nejspíš
  10. 11. posunul díl o 4 minuty zpět.
- **O11 Obrázky podcastů:** malé a šedé, nebo vůbec žádné?
- **O12 Stahování do telefonu:** jen ručně, nebo automaticky (třeba díly ve frontě, jen na
  Wi-Fi)? Mazat stažené po dohrání?
- **O13 Přehráno:** až na samém konci, nebo pár sekund před koncem? Má nové spuštění přehraného
  dílu vrátit díl mezi rozposlouchané?
- **O14 Hledání podcastů:** v adresáři Apple (bez klíče), nebo stačí vložit adresu feedu?
- **O15 Čas na e-inku:** jak často ho během přehrávání obnovovat?
- **O16 Web:** stačí aplikace pro Linux, nebo i verze do prohlížeče (ze stejného kódu)?
- **O17 Uživatelé:** opravdu jen jeden?
- **O18 gPodder API:** aby šel jako záložní klient použít AntennaPod? Návrh: ne.
- **O19 Interval:** jak často posílat pozici během přehrávání? Návrh 30 s; častěji je přesnější,
  ale bere víc baterie.
- **O20 Domácí síť:** vždy přes Cloudflare, nebo i přímo na M1S s vlastní CA, jako u Lissenu?
- **O21 Vyřazení:** jak se má akce jmenovat (Vyřadit, Nechci, Reset)? Mají vyřazené díly
  v detailu podcastu zůstat vidět, nebo zmizet úplně?
