# runner-messung

Öffentliche Messreihe von [maerkische.works](https://maerkische.works): Wie schnell ist GitHubs Standard-Runner für öffentliche Repos (4 vCPU, 16 GB)?

Der Workflow `messung` führt alle 2 Stunden dieselben Aufgaben aus wie unsere Vergleichsläufe: Docker-Abbild laden, Rechnen auf einem Kern, Redis mit allen Kernen bauen, Linux-Kernel flach klonen, 2 GB schreiben und lesen. Jede Messzeile im Log beginnt mit `SB `.

Hier steht nur das Messskript. Es enthält keine Geheimnisse und tastet keine fremden Netze ab.
