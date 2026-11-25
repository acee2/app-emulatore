# Arcadia — emulatore multi-console per iPhone

App iOS (SwiftUI + motore libretro in Objective-C/OpenGL ES) per giocare a:

| Console | Core | Note |
|---|---|---|
| PlayStation (PS1) | PCSX ReARMed | funziona anche senza BIOS e senza JIT |
| PlayStation 2 | Play! | **richiede JIT** (StikDebug) |
| PSP | PPSSPP | senza JIT usa l'interprete IR: molti giochi ok |
| Nintendo 64 | Mupen64Plus-Next | meglio con JIT |
| SNES, NES, Game Boy/Color, GBA, Mega Drive/Master System | Snes9x, FCEUmm, Gambatte, mGBA, Genesis Plus GX | perfetti senza JIT |

La PS4 non è emulabile su iPhone: i file `.pkg` vengono rifiutati con un messaggio.

## Come ottenere l'IPA

1. Crea un repository GitHub (anche privato), per esempio `arcadia`.
2. Carica **tutto il contenuto** di questa cartella nella radice del repository, compresa la cartella `.github/workflows`. Se il caricamento dal browser salta la cartella `.github`, crea il file a mano con *Add file › Create new file*, nome `.github/workflows/build-ipa.yml`, e incolla il contenuto.
3. Vai su **Actions** e avvia **Build IPA** (*Run workflow*). Il workflow parte anche a ogni push su `main`. La compilazione richiede circa 10–20 minuti.
4. Al termine, l'IPA è in **Releases**, con il nome `Arcadia build N`: aprila dall'iPhone e scarica `Arcadia.ipa`. Si trova anche negli artifact della run.
5. Installala con SideStore (+ › seleziona `Arcadia.ipa`).

Il workflow:
- genera il progetto Xcode con XcodeGen;
- scarica i core libretro iOS dal buildbot ufficiale e i file di sistema di PPSSPP;
- compila senza firma e crea l'IPA.

La firma la fa SideStore.

Se la compilazione fallisce, scarica l'artifact **build-log** e mandamelo.

## Uso

- **+** in alto a destra: importa giochi dall'app File. Puoi selezionare più file insieme, per esempio un `.cue` con i suoi `.bin`.
- **Formati:** ISO, CHD, CSO, BIN/CUE, PBP, M3U, CCD, ZIP, 7z e ROM (nes, sfc, gba, gb/gbc, n64/z64, md…). Il formato RAR non è supportato.
- **File ambigui:** se un `.iso` o un `.chd` può essere di più console, l'app ti chiede di quale si tratta.
- **Menu del gioco** (tieni premuto sulla copertina): copertina dalla galleria, rinomina, cambia console, elimina.
- **Durante il gioco:**
  - il pulsante ≡ in alto apre il menu: riprendi, 5 slot di salvataggio, carica stato (automatico, backup, slot), riavvia, velocità 1–4×, mostra o nascondi i comandi, salva ed esci;
  - con un controller collegato, L3 + R3 aprono il menu.
- **Salvataggio automatico:** avviene all'uscita e quando l'app va in background, e sovrascrive quello precedente. La versione prima viene tenuta come backup.
- **Impostazioni:**
  - comandi: croce o stick, stick analogici, comparsa e scomparsa automatica, opacità, dimensione, vibrazione;
  - controller: nascondi i comandi quando ne colleghi uno;
  - velocità, BIOS e stato del JIT.
- **Dove sono i file:** File › Sul mio iPhone › Arcadia. Ci trovi le cartelle `Giochi`, `Salvataggi`, `Stati` e `BIOS`.

## JIT (StikDebug)

iOS non permette il JIT alle app installate con SideStore. StikDebug lo attiva collegando un "debugger" all'app al momento dell'avvio. Serve per PS2 e migliora le prestazioni di N64, PSP e PS1. Lo stato del JIT si vede in Impostazioni › Prestazioni.

## Struttura

```
project.yml                     progetto XcodeGen
Arcadia/Emulation/              frontend libretro (ARCEmulator.m): core, video GL, audio, input
Arcadia/Game/                   schermata di gioco, controlli touch, controller, menu pausa
Arcadia/Library/                libreria, importazione
Arcadia/Storage/                importazione file/archivi, salvataggi
Arcadia/Settings/               impostazioni e BIOS
scripts/                        download core/asset, creazione IPA
.github/workflows/build-ipa.yml build su GitHub Actions
```

Usa solo giochi e BIOS ricavati da copie che possiedi.
