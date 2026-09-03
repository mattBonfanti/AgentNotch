# AgentNotch

Una Dynamic Island per il notch del Mac che mostra cosa stanno facendo
**Claude Code**, **Codex** e **OpenCode** mentre tu fai altro.

Nativa (SwiftUI + AppKit), nessuna dipendenza, nessun server, nessuna rete:
legge solo i file che i tre agenti scrivono già sul tuo disco.

## Cosa mostra

**A riposo** — niente. Il notch resta un notch.

**Due modi di segnalare, si sceglie dal menu.**

*Linea attorno al notch* — una linea sottile ricalca il profilo del notch senza
occupare spazio. Con più agenti attivi si divide in **archi, uno per agente**,
ognuno del suo colore: arancio Claude Code, verde acqua Codex, indaco OpenCode.
Con un'occhiata sai non solo che qualcosa gira, ma chi.

*Isola compatta* — il notch si allarga di poco: a sinistra un pallino colorato
per agente, a destra il simbolo di cosa sta succedendo (terminale se esegue
comandi, mano alzata se ti aspetta, triangolo se è fallito). Occupa un po' di
barra dei menu ma si legge senza avvicinarsi.

In entrambi i modi, quando un agente ha bisogno di te il suo colore diventa
ambra (o rosso se è fallito) e comincia a **respirare** per 20 secondi, poi si
stabilizza: una pulsazione perpetua diventa tappezzeria e smetti di vederla, e
ti terrebbe acceso il display link finché la ignori.

Il riquadro del notch è esatto (il calcolo con le API pubbliche coincide al punto
con la `_notchFrame` privata di AppKit) e l'app segue i cambi di risoluzione, ma
**la curvatura degli angoli non è esposta da nessuna API**: è ricalcata a occhio
e regolabile a caldo, senza ricompilare.

```bash
defaults write local.agentnotch notchCornerRadius -float 8
```

```bash
defaults write local.agentnotch notchLineWidth -float 3
```

**Avviso** — quando un agente passa da *al lavoro* a *ti aspetta*, l'isola si
apre per qualche secondo con icona, nome dell'agente, stato e progetto, poi
torna all'indicatore a riposo. È la transizione compatta della Dynamic Island.

**Al passaggio del mouse sul notch** — l'isola si apre del tutto: fino a 4
sessioni con icona dell'attività, titolo, progetto, branch, tool in esecuzione,
durata, token e todo.

### Le icone

Il significato sta nel glifo, non nel testo: un'occhiata deve bastare.

| icona | mentre lavora | | icona | quando si ferma |
|---|---|---|---|---|
| terminale | comando shell | | mano alzata | ti aspetta |
| documento | sta leggendo | | triangolo | errore |
| matita | sta scrivendo file | | pausa | in pausa |
| lente | sta cercando | | spunta | finito |
| globo | web | | | |
| due persone | subagente | | | |
| tessera | strumento MCP | | | |
| scintille | sta ragionando | | | |

### Lo stile

Angoli continui (squircle) invece di archi circolari, morphing a molla,
retrostante sfocato reale (`NSVisualEffectView`), bordo speculare che degrada
dall'alto, e un fondo che è **nero pieno dove tocca il notch** — così si legge
come una continuazione dell'hardware — e diventa vetro man mano che scende sul
desktop.

Click su una riga → porta in primo piano l'app dell'agente.
⌥-click → apre la cartella del progetto nel Finder.

## Da dove arrivano i dati

| Agente | Fonte | Come |
|---|---|---|
| Claude Code | `~/.claude/sessions/<pid>.json` + `~/.claude/projects/**/*.jsonl` | il file per-PID dà i processi vivi, il transcript viene letto in append (solo le righe nuove a ogni giro) |
| Codex | `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` + `session_index.jsonl` | `task_started` / `token_count` / `item_completed`; include la **percentuale di rate limit** del piano |
| OpenCode | `~/.local/share/opencode/opencode.db` (SQLite) | tabelle `session`, `message`, `part`, `todo`, in sola lettura (`PRAGMA query_only`) |

Tutto in locale, sola lettura, un giro di polling al secondo.

### Come viene dedotto lo stato

- **al lavoro** — c'è un tool aperto, o un turno iniziato e non ancora chiuso, con attività recente
- **ti aspetta** — Claude ha chiuso con `end_turn`, Codex ha emesso il completamento del turno, OpenCode ha un messaggio assistant con `time.completed`
- **in attesa di conferma?** — euristica: un tool di Claude Code aperto da più di 35 secondi senza risposta è quasi sempre un prompt di permesso che ti aspetta a schermo. È un'inferenza, non un dato: Claude Code non scrive nel transcript quando mostra il prompt.
- **errore** — Codex/OpenCode segnalano il fallimento del turno

## Uso

```bash
./build.sh && open AgentNotch.app
```

L'app vive solo nella barra dei menu (nessuna icona nel Dock). Dal suo menu:
suono degli avvisi, avviso sul notch, mostra anche le sessioni ferme, avvio al
login, esci.

Per vedere cosa leggono i parser senza aprire il pannello:

```bash
./.build/release/AgentNotch --dump
```

`--diag` stampa invece la geometria del notch rilevata, e
`AGENTNOTCH_FORCE_MODE=alert|expanded|glow|compact` blocca il pannello in uno
stato per guardarlo con calma senza aspettare che capiti, e
`AGENTNOTCH_DEBUG=1` stampa su stderr modo, geometria del notch e rettangoli
calcolati a ogni secondo — serve quando quello che vedi non torna con quello che
l'app crede di disegnare. Su un Mac senza notch
(o su un monitor esterno) il pannello diventa una pill fluttuante centrata in
alto, con la stessa forma.

Per allargare la finestra di freschezza durante i test — di default una sessione
sparisce dopo 20 minuti di silenzio:

```bash
AGENTNOTCH_WINDOW_MIN=1440 ./.build/release/AgentNotch --dump
```

## Icone

`build.sh` cerca due immagini nella cartella del progetto e le usa in posti
diversi:

| file | dove finisce |
|---|---|
| `Icon` / `Icon.png` | icona del bundle (`.icns`, tutte le taglie da 16 a 1024) |
| `outline` / `outline.png` | icona della barra dei menu, come immagine template |

L'immagine della barra dei menu deve essere un'**immagine template**: nero più
canale alpha, così macOS la ricolora da sé — bianca sulla barra scura, nera su
quella chiara, invertita quando il menu è aperto. Il disegno in outline però
arriva spesso da un'esportazione con lo sfondo "a scacchi" **dipinto nei pixel**
e senza canale alpha: usato così com'è, nella barra si vedrebbe un rettangolo a
scacchiera.

Per questo `tools/make-status-icon.swift` normalizza qualunque sorgente: se
l'alpha c'è lo rispetta, se manca lo ricava dalla luminanza (più chiaro del 90%
è sfondo, il resto conserva i bordi antialiasati). Poi ingrossa un poco il
tratto prima di ridurre, perché a 19pt un filo sottile finisce sotto il pixel e
si legge grigio invece che pieno. Il fattore è l'ultimo argomento: 0.18 di
default, 0 per disattivarlo, di più per un disegno a filo molto sottile.

Il convertitore viene compilato una volta e messo in cache in `.build/`, e
l'icona si rigenera solo quando l'immagine sorgente cambia — interpretato con
`swift file.swift` lo stesso lavoro richiede 25 secondi invece di uno.

Se manca l'outline l'app ripiega sull'icona a colori ridotta, e se manca anche
quella su un simbolo di sistema: il binario nudo lanciato in sviluppo non ha
nemmeno una cartella `Resources`.

L'icona a colori ha lo sfondo trasparente: nel Finder apparirà come un logo che
fluttua, non come il quadrato arrotondato standard di macOS. È una scelta
estetica, non un errore.

## Struttura

```
Sources/AgentNotch/
  Models.swift            tipi condivisi, formattazione
  Config.swift            soglie e preferenze
  Tailer.swift            lettore JSONL incrementale + accesso JSON tollerante
  SQLiteLite.swift        lettore SQLite minimale, sola lettura
  ClaudeProvider.swift    ┐
  CodexProvider.swift     ├ un parser per agente → [AgentSession]
  OpenCodeProvider.swift  ┘
  SessionStore.swift      polling, ordinamento per urgenza, avvisi
  NotchShape.swift        silhouette ad angoli continui, vetro, colori
  NotchView.swift         SwiftUI: linea / isola compatta / avviso / espansa
  NotchController.swift   NSPanel, hover, click-through
  LoginItem.swift         avvio al login via LaunchAgent
  main.swift              delegate, menu, --dump / --diag
tools/
  make-status-icon.swift  da outline su fondo chiaro a immagine template
```

## Aggiungere un quarto agente

Scrivi un tipo con `func poll() -> [AgentSession]`, aggiungi il caso a
`AgentKind` (tag, colore, bundle id) e infilalo nella somma dentro
`SessionStore.tick()`. Il resto — ordinamento, avvisi, UI — funziona da solo.

## Limiti noti

- I parser dipendono dai formati su disco dei tre agenti: un aggiornamento che
  cambia il tracciato può far sparire un campo. `--dump` è il modo rapido per
  accorgersene.
- **La barra del contesto compare solo dove la finestra è dichiarata dall'agente**,
  cioè oggi solo per Codex (`model_context_window`). Claude Code e OpenCode non
  la scrivono da nessuna parte: assumerla produceva falsi allarmi — una sessione
  Claude reale stava a 226k contro un tetto assunto di 200k, quindi barra rossa
  su una sessione perfettamente sana. Per gli altri viene mostrato il numero di
  token e basta. Se conosci il limite vero di un modello, aggiungilo a
  `Config.knownWindows` e la barra ricompare.
- Il costo è reale solo per OpenCode, che lo salva nel database; Claude Code e
  Codex non lo scrivono nei file di sessione.
- L'app è firmata ad-hoc: gira sulla tua macchina, non è distribuibile così com'è.

## Nota sulle prestazioni

L'app sta sotto l'1% di CPU e ~24 MB, ma ci sono voluti tre tentativi e vale
scriverlo perché il prossimo che tocca la linea non li rifaccia:

- **Le sfocature costano per sempre.** `.blur()` è un filtro Core Animation che
  viene ri-applicato a ogni ricomposizione. Nove tracciati sfocati tenevano ~2%
  di CPU in modo permanente.
- **`.drawingGroup()` è stato peggio**: un buffer offscreen per arco, memoria da
  24 a 107 MB.
- **`withAnimation(.repeatForever)` non si annulla** riassegnando la proprietà
  che anima. L'unico modo affidabile per fermarla è distruggere la vista che la
  ospita — per questo la linea che respira è un tipo di vista separato e non un
  flag. Lasciarla girare teneva acceso il display link finché una sessione
  restava in attesa.

Se una modifica fa salire la CPU, `sample <pid>` dice quale thread la sta
consumando in pochi secondi.
