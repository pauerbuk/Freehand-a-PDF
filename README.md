# FreeHand a PDF

A small native Mac app that turns old **Macromedia/Aldus FreeHand** files into **PDF** or **Illustrator (.ai)**, without FreeHand and without LibreOffice.

FreeHand was discontinued long ago and current versions of Illustrator often refuse its files. If you have an archive of them, this may help you get your work back.

*[Italiano più sotto](#italiano)*

![App icon](docs/icon-preview.png)

## What it does

- **Converts** FreeHand files to PDF, or to `.ai` keeping layers, layer names and hidden layers.
- **Recognizes files by content**, because old Mac files often have no extension. If a file isn't FreeHand it tells you what it is (TIFF, PDF, EPS…) and makes a correctly named copy.
- **Searches a folder or a NAS** for FreeHand files, so you can pick the ones to convert.
- **Reports missing fonts** and keeps their original names, so Illustrator's *Find Font* can show which font to replace.

Your files are never overwritten: output goes next to the original, as `Name (2).pdf` if the name is taken.

## Download

Get the zip from the [latest release](https://github.com/pauerbuk/Freehand-a-PDF/releases/latest) and unzip it. It is one app for **Apple silicon and Intel**, for **macOS 12 or later**.

The app isn't notarized by Apple, because that requires a paid developer membership, so **macOS will refuse to open it the first time**. If you're happy to trust it, either:

- try to open it, then go to **System Settings → Privacy & Security** and click **Open Anyway**; or
- run this in Terminal, adjusting the path:

```bash
xattr -dr com.apple.quarantine "/Applications/FreeHand a PDF.app"
```

If you'd rather not, you can build it yourself from the source below.

It has only been tested on Apple silicon with macOS 26, where the Intel version was also run through Rosetta and gave identical results. It has **not been tried on a real Intel Mac or on older macOS versions**: reports are welcome.

## Build

You only need the Xcode command line tools (`xcode-select --install`). The script downloads the three libraries it needs, checks them, and compiles everything into `build/`: nothing is installed on your system.

```bash
git clone https://github.com/pauerbuk/Freehand-a-PDF.git
cd Freehand-a-PDF
./build.sh
open build
```

Drag `FreeHand a PDF.app` wherever you like. An app you build yourself opens without any warning. The build hasn't been tried on Intel Macs or older macOS versions. To target another macOS version, use `MIN_MACOS=11.0 ./build.sh`.

## Usage

Drop files or folders on the window or on the app icon, or click the window to choose them. Use **Cerca file FreeHand…** to search a folder. The interface is in Italian.

From Terminal:

```bash
"build/FreeHand a PDF.app/Contents/MacOS/FreeHand a PDF" --convert file1 file2
"build/FreeHand a PDF.app/Contents/MacOS/FreeHand a PDF" --convert --ai file1
"build/FreeHand a PDF.app/Contents/MacOS/FreeHand a PDF" --convert --livelli-nascosti file1
"build/FreeHand a PDF.app/Contents/MacOS/FreeHand a PDF" --search /path/to/folder
```

## Limitations

Please check the result of anything important: there is no FreeHand here to compare against, and testing was done on one person's archive.

- **Tested on** real FreeHand 8 and 11 files. Other versions were only opened in a large batch, without checking each result.
- **Very old files (`FHD2`, around 1990):** this reader was worked out from **a single file** and is experimental. Page size isn't decoded yet: it uses A4 if the drawing fits, otherwise a custom page.
- **Fonts** must be installed on your Mac, otherwise they are substituted with a warning. Line breaks and text position may differ slightly from the original.
- **PDF:** colors are RGB. Hidden layers can be included, but layers are flattened. Tile fills become light gray, shadows lose their blur and arrowheads use a generic shape.
- **`.ai`:** uses the old text-based Illustrator format, so Illustrator shows *[Converted]* and may ask to update the text. Colors are converted from RGB: blacks and grays go to K only, others are approximate, and spot colors are lost. Gradients become solid, image fills become gray; embedded images, arrowheads and transparency are dropped. Most of these show a warning.
- **Line joins and caps** are always mitered and butt.
- **Very large files** over about 260,000 objects will fail with an error.
- **Search** only looks at files with no extension or with a `.fh…` extension.

Sample files are welcome, especially from versions before FreeHand 8, as long as they contain no private or client material.

## How it works

Reading is done by [libfreehand](https://wiki.documentfoundation.org/DLP/Libraries/libfreehand) with a [small patch](patches/libfreehand-0.1.4.patch), downloaded and applied at build time. It also uses librevenge, with a [patch](patches/librevenge-0.0.6.patch) that removes its need for Boost, and lcms2. The libfreehand patch:

- reads files with more than about 130,000 objects, which the original fails on;
- scales stroke widths with their object, so shrunk artwork doesn't look bolder;
- treats inner shapes of compound paths as holes;
- passes clipped content as real drawing, plus layer names and visibility.

The drawing code, the `.ai` writer and the `FHD2` reader are in [`Sources/FHEngine.mm`](Sources/FHEngine.mm).

## License

[Mozilla Public License 2.0](LICENSE). The built app also contains libfreehand (MPL 2.0), librevenge (MPL 2.0 / LGPL 2.1) and lcms2 (MIT), and their license files are copied into the app.

This project isn't affiliated with or endorsed by Adobe. FreeHand and Illustrator are trademarks of Adobe; they're named here only to describe which files this tool works with.

---

## Italiano

Una piccola app per Mac che converte i vecchi file **FreeHand** in **PDF** o **Illustrator (.ai)**, senza bisogno di FreeHand né di LibreOffice.

**Cosa fa**

- Converte in PDF, oppure in `.ai` mantenendo livelli, nomi e livelli nascosti.
- Riconosce i file dal contenuto, anche senza estensione. Se un file non è FreeHand ti dice cos'è e ne crea una copia con il nome giusto.
- Cerca i file FreeHand in una cartella o su un NAS, così scegli quali convertire.
- Segnala i font mancanti e ne conserva il nome, così in Illustrator puoi vedere quale sostituire.

Non sovrascrive mai nulla: il file creato va accanto all'originale.

**Come scaricarla**

Scarica lo zip dall'[ultima versione](https://github.com/pauerbuk/Freehand-a-PDF/releases/latest) e aprilo. È un'unica app per **processori Apple e Intel**, per **macOS 12 o successivi**.

L'app non è autenticata da Apple, perché servirebbe un'iscrizione a pagamento, quindi **la prima volta macOS rifiuta di aprirla**. Se ti fidi, prova ad aprirla, poi vai in **Impostazioni di Sistema → Privacy e sicurezza** e clicca **Apri comunque**. In alternativa, nel Terminale:

```bash
xattr -dr com.apple.quarantine "/Applications/FreeHand a PDF.app"
```

**Come compilarla**

Se preferisci compilarla da te, si apre senza avvisi. Bastano gli strumenti da riga di comando di Xcode (`xcode-select --install`), poi:

```bash
git clone https://github.com/pauerbuk/Freehand-a-PDF.git
cd Freehand-a-PDF
./build.sh
open build
```

L'app è stata provata solo su processore Apple con macOS 26, dove anche la versione Intel, eseguita con Rosetta, dà risultati identici. Su un vero Mac Intel e sui macOS più vecchi non è ancora stata provata: le segnalazioni sono benvenute.

**Limiti**

Controlla sempre il risultato dei file importanti: i limiti sono elencati nella sezione *Limitations* qui sopra. In particolare, la lettura dei file molto vecchi (`FHD2`, circa 1990) nasce da un solo file ed è sperimentale.

Il progetto non è affiliato ad Adobe. FreeHand e Illustrator sono marchi di Adobe.
