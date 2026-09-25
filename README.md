# tModLoader Server (light)

Schlanker Docker-Container für einen tModLoader-Server. Er basiert auf
[JACOBSMILE/tmodloader1.4](https://github.com/JACOBSMILE/tmodloader1.4) und
übernimmt einige Fixes aus [Crosis47/tmodloader](https://github.com/Crosis47/tmodloader).
Es gibt keine Weboberfläche und keine Backups: Alles wird über Umgebungsvariablen gesteuert.

Das Repo besteht aus drei Skripten und dem `Dockerfile`:

| Datei           | Zweck                                                        |
|-----------------|--------------------------------------------------------------|
| `Dockerfile`    | Basis `steamcmd/steamcmd:ubuntu-24`, alle Standardwerte der Variablen |
| `entrypoint.sh` | Rechte abgeben, tModLoader installieren/aktualisieren, Config schreiben, Mods laden, ggf. Welt erstellen, Server starten |
| `inject.sh`     | Konsolenbefehle an den laufenden Server senden                |
| `healthcheck.sh`| Docker-Healthcheck: Prozess läuft und Port ist offen          |

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
| `TMOD_MODS`               | leer       | Workshop-IDs und/oder `collection:<ID>` mit Komma getrennt, z. B. `2824688072,collection:2830000000`. Die Mods werden bei jedem Start heruntergeladen, aktualisiert und aktiviert. Verschachtelte Collections funktionieren; ist Steam nicht erreichbar, wird die zuletzt geladene Liste verwendet. Bleibt die Variable leer, gilt die vorhandene `enabled.json`. |
| `TMOD_AUTOSAVE_INTERVAL`  | `10`       | Minuten zwischen Speicherungen, `0` = aus |
| `TMOD_SHUTDOWN_MESSAGE`   | …          | Chat-Nachricht beim Stoppen |
| `TMOD_USECONFIGFILE`      | `No`       | `Yes` = eingebundene `customconfig.txt` statt der Variablen nutzen |
| `TMOD_PASS`               | `docker`   | Serverpasswort, `N/A` = kein Passwort |
| `TMOD_WORLDNAME`, `TMOD_WORLDSIZE`, `TMOD_WORLDSEED`, `TMOD_DIFFICULTY` | | Werden nur beim Erstellen einer neuen Welt verwendet |
| `TMOD_WORLDEVIL`          | `random`   | `random`, `corruption` oder `crimson` für neue Welten. Die Config-Datei kann das nicht, deshalb beantwortet der Container einmalig das Erstellungsmenü des Servers. |
| `TMOD_MOTD`, `TMOD_MAXPLAYERS`, `TMOD_PORT`, `TMOD_LANGUAGE`, `TMOD_SECURE`, `TMOD_NPCSTREAM`, `TMOD_UPNP`, `TMOD_PRIORITY` | | Entsprechende Einträge in der `serverconfig.txt` |
| `TMOD_JOURNEY_*`          | `0`        | Rechte im Reise-Modus (0 = gesperrt, 1 = Host, 2 = alle) |

Wer die Variablen ändert, erzeugt den Container neu: `docker compose up -d`.

## Sicherheit und Healthcheck

- Der Server läuft als unprivilegierter Benutzer `tml` (UID/GID 1000). Der Container startet als root, korrigiert nur die Besitzrechte von `/data` und gibt die Rechte dann ab.
- Der Docker-Healthcheck prüft, ob der Serverprozess läuft und der Port offen ist. Dabei wird keine Verbindung aufgebaut, die einen Spielerplatz belegen würde. Den Status zeigt `docker ps` an.

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
- Basis ist `steamcmd/steamcmd:ubuntu-24` (Ubuntu 24.04 mit fertigem SteamCMD) statt `ubuntu:latest` plus separat heruntergeladenem SteamCMD.
- Das Passwort taucht nicht mehr in den tModLoader-Logs auf.
- Konsolenbefehle laufen über eine Pipe statt über tmux. Beim Stoppen wartet der Container, bis die Welt gespeichert ist.
- Mod-Downloads werden bis zu dreimal versucht.
- Workshop-Collections, Auswahl Corruption/Crimson, Betrieb ohne root und Healthcheck, jeweils nach dem Vorbild von Crosis47/tmodloader.
