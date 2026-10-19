# Vývojářské nástroje

## Alternativní editory

Omarchy ve výchozím nastavení obsahuje [Neovim](https://neovim.io/), ale pokud chcete něco o něco mainstreamovějšího a známějšího, můžete spustit nabídku Omarchy (`Super + Space`) a podívat se na možnosti v části _Instalovat > Editor_. Najdete tam VSCode, Cursor, Zed, Sublime Text, Helix, Vim a Emacs. Pokud nenajdete, co hledáte, podívejte se do _Instalovat > Balíček_ a zjistěte, jestli to není v některém balíčku pro Arch (a pokud ne, zkuste _Instalovat > AUR_, kde AUR zkontrolujete).

Původní editor `vi` je také k dispozici rovnou po instalaci. Soubor v terminálu upravíte příkazem `vi filename`.

Sladění motivu je nabízeno pro `VSCode`, `Cursor`, `VSCodium` a `Helix`.

Výchozí editor pro celý systém můžete nastavit v části `Setup > Defaults > Editor`.

## Prostředí

Omarchy podporuje nastavení celé řady vývojových prostředí prostřednictvím části _Instalovat > Vývoj_ v nabídce Omarchy (`Super + Space`). Najdete tu samozřejmě _Ruby on Rails_, ale také všechna tři hlavní běhová prostředí pro JavaScript (Node.js, Bun, Deno) a oblíbené frameworky PHP, jako jsou Laravel a Symfony. Aha, a nechybí Go, Rust, Python, Java, Elixir (s Phoenix), .NET, OCaml, Zig, Clojure a Scala. Je to velmi široký výběr!

Většinu těchto prostředí spravuje [Mise](https://mise.jdx.dev/). Je to nástroj, který vám umožní nainstalovat a spouštět více verzí programovacího jazyka na jednom počítači. Je to jako rbenv nebo rvm pro Ruby nebo virtualenv pro Python, ale funguje pro řadu různých prostředí.

Chcete-li si nainstalovat například Ruby, spustíte příkaz `mise use -g ruby`, který Ruby nainstaluje a nastaví jako globální výchozí. Nebo pokud má váš projekt soubor .ruby-version, můžete v kořenovém adresáři daného projektu jednoduše spustit příkaz `mise i`.

## Docker

[Docker](https://www.docker.com/) snad ani nepotřebuje představovat. Umožňuje spouštět izolované kontejnery a Omarchy nainstaluje vše, co je potřeba k jeho bezproblémovému běhu, včetně samotného Dockeru a [Docker Compose](https://docs.docker.com/compose/).

Ve výchozím nastavení váš uživatel *není* ve skupině `docker`. Členství v ní v podstatě poskytuje oprávnění root bez hesla: příkaz `docker run -v /:/host` umožní převzít kontrolu nad počítačem. Stačil by tak jediný škodlivý skript nebo závislost spuštěná pod vaším účtem. Proto v terminálu používáte `sudo` (`sudo docker ps`, `sudo docker compose up`). Grafické nástroje, například virtuální počítač s Windows, si potřebná oprávnění vyžádají samy. Pokud riziku rozumíte a chcete Docker používat bez sudo, povolte **Nastavení > Zabezpečení > Sudoless Docker** nebo spusťte `omarchy-setup-security-sudoless-docker`. Po varování vás přidá do skupiny `docker`; samotný příkaz `docker` i alias `d` pak budou fungovat bez `sudo`.

Běžné databáze pro místní vývoj v Dockeru můžete nastavit pomocí části _Instalovat > Vývoj > Docker DB_ v nabídce Omarchy.

## GitHub CLI

[GitHub CLI](https://cli.github.com/) umožňuje přihlášení k účtu GitHub a klonování soukromých repozitářů. Při prvním spuštění příkazu `gh` ho Mise automaticky nainstaluje. Přihlaste se příkazem `gh auth login` a pak můžete klonovat soukromé repozitáře pomocí `gh repo clone org/repo`.

Pomocí tohoto příkazu můžete provádět i řadu dalších operací na GitHubu. Stačí spustit příkaz `gh` a uvidíte vše, co je možné.

Stejným způsobem se při prvním spuštění nainstaluje i `ghui`, který slouží ke správě pull requestů v TUI. Pokud chcete z TUI ovládat samotný Git, [lazygit](https://github.com/jesseduffield/lazygit) je už předinstalovaný.