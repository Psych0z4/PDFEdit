# PDFEdit

Mobilny edytor PDF (Flutter, iOS + Android) z **prawdziwą edycją istniejącego tekstu** —
podmianą treści w content streamie dokumentu, a nie zamalowywaniem starego tekstu
białym prostokątem.

## Dlaczego PDFium

Wymaganie było twarde: edycja istniejącego tekstu na obu platformach, bez płatnego SDK.

| SDK | Edycja istniejącego tekstu | iOS | Android | Licencja |
|---|---|---|---|---|
| Apryse (PDFTron) | pełna, z reflow | tak | tak | komercyjna, od ~$1500/rok |
| Nutrient (PSPDFKit) | Content Editor **tylko Android** we Flutterze | nie | tak | komercyjna |
| ComPDFKit | tak | tak | tak | komercyjna |
| Syncfusion Flutter PDF | **brak** — otwarty feature request | tak | tak | Community License |
| MuPDF | ograniczona, brak mostka Flutter | tak | tak | **AGPL v3** |
| **PDFium** (`pdfrx` / `pdfium_flutter`) | **tak, na poziomie obiektu tekstowego** | tak | tak | **BSD-3 + MIT** |

PDFium to jedyne darmowe rozwiązanie, które faktycznie modyfikuje content stream
na obu platformach. Kluczowa funkcja to `FPDFText_SetText`, która podmienia treść
istniejącego obiektu tekstowego, używając **jego własnego fontu** — pozycja, rozmiar,
kolor i macierz transformacji zostają zachowane.

Zero opłat, zero kluczy licencyjnych, zero walidacji online. Żaden dokument nie
opuszcza urządzenia.

## Co działa

- Import PDF z pamięci urządzenia (kopia strumieniowa do prywatnego katalogu — oryginał nietykany)
- Viewer: przewijanie, zoom, strony
- **Edycja istniejącego tekstu**: tapnięcie → podświetlenie obiektu → edycja → zapis
- **Reflow** przy wydłużeniu tekstu (szczegóły niżej)
- Dodawanie tekstu, usuwanie obiektów (realne `FPDFPage_RemoveObject`)
- Undo / Redo oparte o stos rewizji plikowych
- Save as / Share
- Wykrywanie skanów (brak warstwy tekstowej) z komunikatem o OCR
- **Odzyskiwanie polskich znaków**: dokładna detekcja brakujących glifów i naprawa
  przez przeładowanie fontu dokumentu jako CID — bez zmiany kroju

## Reflow

PDF nie ma silnika layoutu — po zmianie treści nic nie przelicza się samo.
Warstwa `domain/reflow/` implementuje trzy strategie, wybierane automatycznie
na podstawie tego, co uda się rozpoznać na stronie:

| Strategia | Kiedy | Co robi |
|---|---|---|
| `CellWrapStrategy` | rozpoznano komórkę tabeli | łamie tekst w obrębie komórki, centruje w pionie |
| `ParagraphFlowStrategy` | rozpoznano kolumnę tekstu | łamie tekst, przesuwa treść poniżej w dół, opływa obrazki |
| `FitInPlaceStrategy` | nic nie rozpoznano | proporcjonalnie zmniejsza tekst |

Granice komórek czytane są z **segmentów ścieżek**, a nie z bboxów obiektów —
większość generatorów PDF rysuje całą siatkę tabeli jako jeden obiekt, którego
bbox to cała tabela.

Szerokość dostępna dla tekstu liczona jest **osobno dla każdego wiersza**, dzięki
czemu tekst opływa obrazek: wiersze na jego wysokości są węższe, a te poniżej
wracają do pełnej szerokości kolumny.

## Znane ograniczenia

To nie są niedoróbki do naprawienia „później" — to konsekwencje formatu PDF
i publicznego API PDFium.

- **Granularność = obiekt tekstowy, nie słowo.** PDF nie zna pojęcia słowa ani
  akapitu. Jeden obiekt to fragment content streamu: czasem cała linia, czasem
  kilka liter. Edytujemy cały taki fragment.
- **Kodowanie fontu ogranicza dostępne znaki.** Prosty font PDF adresuje glify
  przez 256 kodów, więc „ł" czy „ą" nie mają tam adresu nawet wtedy, gdy glify
  są w pliku fontu. Aplikacja wykrywa to dokładnie (renderując znak
  i porównując z wzorcem `.notdef`) i potrafi naprawić, przeładowując font
  **z tego samego dokumentu** jako font CID — krój zostaje bez zmian.
  Koszt: font zostaje osadzony w pliku, co przy foncie wcześniej
  nieosadzonym potrafi dodać kilkaset kilobajtów.
- **Brak re-justowania sąsiednich wierszy.** Łamiemy edytowany fragment i robimy
  mu miejsce, ale nie przelewamy tekstu między wierszami akapitu. Celowo:
  sklejanie wierszy zniszczyłoby układy, które tylko wyglądają jak akapit —
  adresy, listy, pozycje faktury.
- **Wiersz tabeli się nie powiększa.** Segmenty istniejących ścieżek są w PDFium
  tylko do odczytu (nie ma `FPDFPathSegment_SetPoint`). Powiększanie wiersza
  wymaga odbudowy ścieżki od zera — zweryfikowane jako wykonalne, jeszcze
  niezaimplementowane.
- **Opływanie prostokątne**, tylko przeszkody z prawej strony.
- **Strony obrócone**: edycja wyłączona z widocznym oznaczeniem, zamiast
  wstawiania zmian w złym miejscu.
- **Dodawany tekst** używa standardowego fontu Helvetica (WinAnsi), który nie
  zawiera polskich znaków diakrytycznych.
- **PDF → DOCX wymaga backendu.** Nie istnieje sensowna lokalna ścieżka na mobile.
  `ConversionService` ma gotową abstrakcję i jawnie zgłasza, czego jeszcze nie ma.

## Architektura

```
lib/
├── core/                      Result, AppFailure, logger (nigdy nie loguje treści dokumentu)
├── app/                       DI (get_it), theme, entry point
├── features/
│   ├── home/                  ekran startowy
│   ├── documents/             import
│   ├── pdf_editor/
│   │   ├── domain/            PdfEngine (abstrakcja), modele, strategie reflow
│   │   ├── application/       EditorController, EditHistory
│   │   ├── infrastructure/    PdfiumPdfEngine, most FFI, geometria strony
│   │   └── presentation/      ekran edytora, mapowanie współrzędnych, widgety
│   ├── conversions/           ConversionService + implementacje
│   └── settings/
└── shared/services/           pliki, picker, udostępnianie
```

Cała aplikacja rozmawia wyłącznie z interfejsem
[`PdfEngine`](lib/features/pdf_editor/domain/pdf_engine.dart). Poza katalogiem
`infrastructure/` nie ma ani jednego importu `pdfium_*` — wymiana silnika to
dopisanie jednej klasy.

**PDFium nie jest thread-safe.** Wszystkie wywołania natywne przechodzą przez
`PdfrxEntryFunctions.compute`, czyli ten sam isolate workera, którego pdfrx używa
do renderowania. Równoległe wywołania z dwóch isolate prowadzą do crashy
i uszkodzenia danych.

Undo/redo nie korzysta z PDFium (nie ma tam stosu undo). Każda zatwierdzona zmiana
zapisuje nowy plik rewizji, a undo/redo to przesuwanie kursora po tej liście.

## Uruchomienie

```bash
flutter pub get
flutter run                      # z podłączonym telefonem
flutter build apk --release --split-per-abi
```

Wymagania: Flutter 3.47+ (Dart 3.13+), iOS 15+.
Build na Windows desktop wymaga włączonego **Trybu dewelopera** — pdfrx używa
dowiązań symbolicznych.

## Weryfikacja

Katalog `tool/` zawiera skrypty, którymi sprawdzano wykonalność na żywym PDFium
przed napisaniem kodu aplikacji. Uruchamiane przez `dart run tool/<nazwa>.dart`:

| Skrypt | Co weryfikuje |
|---|---|
| `spike.dart` | że `FPDFText_SetText` trwale podmienia tekst i że `GetBounds` przelicza się po zmianie |
| `spike_row.dart` | powiększanie wiersza tabeli — przez transformacje i przez odbudowę ścieżki |
| `spike_cell_wrap.dart` | łamanie tekstu w komórce, na kodzie produkcyjnym |
| `spike_layout.dart` | tabela, akapit i opływanie obrazka, na kodzie produkcyjnym |
| `spike_glyph_coverage.dart` | regresja detekcji znaków wobec znanej zawartości WinAnsi |
| `spike_glyph_probe.dart` | detekcja na kodzie produkcyjnym + brak modyfikacji pliku |
| `spike_font_reencode.dart` | że przeładowanie fontu jako CID odzyskuje polskie znaki |
| `spike_polish_roundtrip.dart` | pełny scenariusz: wpisanie polskiego tekstu i odczyt z pliku |
| `spike_fallback_font.dart` | osadzenie zewnętrznego fontu (ścieżka odrzucona — zmienia krój) |

`spike_cell_wrap.dart` i `spike_layout.dart` wywołują prawdziwe funkcje z
`pdfium_bridge.dart` — te same, których używa aplikacja.

## Prywatność

Dokumenty użytkownika są prywatne. Praca odbywa się wyłącznie w katalogu aplikacji,
oryginał nie jest nadpisywany bez świadomej akcji użytkownika, a logger ma twardy
zakaz logowania treści dokumentu. W MVP żaden dokument nie opuszcza urządzenia.
