# Pozadí

Každý motiv se dodává s vlastní sadou pozadí a další si můžete přidat do složky `~/.config/omarchy/backgrounds/[theme]`. Pokud chcete přidat další obrázek pozadí například k motivu nord, stačí umístit soubor do složky `~/.config/omarchy/backgrounds/nord`.

Nejsnazší cesta vede přes nabídku Omarchy _Instalovat > Vzhled > Pozadí_. Otevře složku s pozadími aktuálního motivu. Pomocí `Super + Shift + F` otevřete další okno správce souborů, najděte požadovaný obrázek a zkopírujte ho do této složky. Pak se objeví mezi pozadími, která přepínáte zkratkou `Super + Ctrl + Space`.

Pozadím mohou být vedle statických obrázků také videa. Vložte do stejné složky soubor `mp4`, `m4v`, `mov`, `webm`, `mkv` nebo `avi` a objeví se vedle obrázků. Videa přehrává jádro tapet OWE. Dekóduje video jednou pro všechny monitory a jeho zvuk přehrává přes výchozí zvukový výstup a přehrávání zastaví, kdykoli není vidět. Zamykací obrazovka přes OWE zobrazuje stejné dekódované video, ale bez zvuku. Videotapeta přitom stále spotřebovává mnohem více energie než statická tapeta.

Motivy mohou obsahovat krátký úvod ke statickému pozadí. Pro `backgrounds/road.webp` se odpovídající video nachází v `backgrounds/intros/road.mp4`. Přehraje se automaticky při spouštění a při přepnutí na motiv s vybraným pozadím, a poté se vrátí ke statickému obrázku. Úvodní videa se nezobrazují ve výběru pozadí a nikdy se neopakují ve smyčce.

Vypnutí volby _Akce > Vzhled > Animace_ vypne také úvodní videa pozadí. Omarchy to ve výchozím nastavení dělá ve virtuálním počítači. Příkaz `omarchy theme bg intro toggle` může úvodní videa zapínat a vypínat samostatně. Obnovení motivu ani volba jiného pozadí v rámci téhož motivu úvod nepřehraje.

Obrovskou sbírku krásných vybraných pozadí najdete na adrese https://github.com/dharmx/walls.

Videopozadí si na zamykací obrazovce zachovávají uložený statický obrázek, pokud je přehrávání pozastaveno nebo není k dispozici. Animované obrázky GIF se přehrávají na ploše a na zamykací obrazovce zobrazují statický snímek.
