# tModLoader Server (light)

Schlanker Docker-Container für einen tModLoader-Server. Er basiert auf
[JACOBSMILE/tmodloader1.4](https://github.com/JACOBSMILE/tmodloader1.4) und
übernimmt einige Fixes aus [Crosis47/tmodloader](https://github.com/Crosis47/tmodloader).
Es gibt keine Weboberfläche und keine Backups: Alles wird über Umgebungsvariablen gesteuert.

Das Repo besteht aus zwei Skripten und dem `Dockerfile`:

| Datei           | Zweck                                                        |
|-----------------|--------------------------------------------------------------|
| `Dockerfile`    | Ubuntu 24.04 + SteamCMD, alle Standardwerte der Variablen     |
| `entrypoint.sh` | tModLoader installieren/aktualisieren, Config schreiben, Mods laden, Server starten |
| `inject.sh`     | Konsolenbefehle an den laufenden Server senden                |

## Start

```bash
cp .env.example .env     # Werte anpassen
docker compose up -d --build
docker compose logs -f
```

Beim ersten Start werden tModLoader, die .NET-Laufzeit und alle Mods nach
`./data` heruntergeladen. Das kann ein paar Minuten dauern.

## Variablen

| Variable                  | Standard   | Bedeutung |
|---------------------------|------------|-----------|
| `TMOD_VERSION`            | `latest`   | `latest` oder ein Release-Tag wie `v2025.01.3.1` |
| `TMOD_AUTO_UPDATE`        | `1`        | Bei `latest` und jedem Start auf eine neuere Version prüfen |
| `TMOD_MODS`               | leer       | Workshop-IDs mit Komma getrennt. Die Mods werden bei jedem Start heruntergeladen, aktualisiert und aktiviert. Bleibt die Variable leer, gilt die vorhandene `enabled.json`. |
| `TMOD_AUTOSAVE_INTERVAL`  | `10`       | Minuten zwischen Speicherungen, `0` = aus |
| `TMOD_SHUTDOWN_MESSAGE`   | …          | Chat-Nachricht beim Stoppen |
| `TMOD_USECONFIGFILE`      | `No`       | `Yes` = eingebundene `customconfig.txt` statt der Variablen nutzen |
| `TMOD_PASS`               | `docker`   | Serverpasswort, `N/A` = kein Passwort |
| `TMOD_WORLDNAME`, `TMOD_WORLDSIZE`, `TMOD_WORLDSEED`, `TMOD_DIFFICULTY` | | Werden nur beim Erstellen einer neuen Welt verwendet |
| `TMOD_MOTD`, `TMOD_MAXPLAYERS`, `TMOD_PORT`, `TMOD_LANGUAGE`, `TMOD_SECURE`, `TMOD_NPCSTREAM`, `TMOD_UPNP`, `TMOD_PRIORITY` | | Entsprechende Einträge in der `serverconfig.txt` |
| `TMOD_JOURNEY_*`          | `0`        | Rechte im Reise-Modus (0 = gesperrt, 1 = Host, 2 = alle) |

Wer die Variablen ändert, erzeugt den Container neu: `docker compose up -d`.

## Konsole

```bash
docker exec tmodloader inject "say Hallo"
docker exec tmodloader inject save
```

## Daten

Alles liegt im Volume `/data`:

- `server/` – tModLoader-Installation inklusive .NET
- `tModLoader/Worlds/` – Welten
- `tModLoader/Mods/enabled.json` – aktivierte Mods
- `steamMods/` – Workshop-Cache

## Unterschiede zu JACOBSMILE/tmodloader1.4

- tModLoader wird zur Laufzeit nach `/data` installiert. Die Version legt `TMOD_VERSION` fest, ein Neubau des Images ist dafür nicht nötig.
- Statt `TMOD_AUTODOWNLOAD` und `TMOD_ENABLEDMODS` gibt es nur noch `TMOD_MODS`.
- Die `enabled.json` wird jetzt korrekt als JSON geschrieben. Vorher entstand am Ende ein Komma zu viel.
- Die `serverconfig.txt` wird bei jedem Start neu geschrieben, statt dass neue Zeilen angehängt werden. `TMOD_USECONFIGFILE=Yes` liest jetzt wirklich die `customconfig.txt`.
- Das Basis-Image ist fest auf `ubuntu:24.04` gesetzt statt `latest`.
- Das Passwort taucht nicht mehr in den tModLoader-Logs auf.
- Konsolenbefehle laufen über eine Pipe statt über tmux. Beim Stoppen wartet der Container, bis die Welt gespeichert ist.
- Mod-Downloads werden bis zu dreimal versucht.
