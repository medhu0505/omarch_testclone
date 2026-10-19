# Vytvoření vlastního motivu

Vlastní motivy můžete přidat do složky `~/.config/omarchy/themes`. Stačí zkopírovat jeden ze stávajících jako základ (podívejte se do složky `/usr/share/omarchy/themes`) a poté ho upravit podle svých představ. Pokud je váš motiv v této složce, objeví se v nabídce výběru motivu.

Hlavní soubor, který musíte upravit, je `colors.toml`. Definuje sadu barev, která se poté používá k vytváření konfigurací pro terminál (Foot/Alacritty/Ghostty/Kitty), btop, Chromium, Hyprland, Neovim, Helix, VSCode, Obsidian a celý shell Omarchy (horní lištu, nabídku, oznámení, OSD a zamykací obrazovku).

K vytvoření nového motivu můžete také využít přiloženou aplikaci Aether, která nabízí příjemné grafické rozhraní pro hraní si s barvami a vyhledávání pozadí. Stačí ji spustit z mřížky aplikací zkratkou `Super + Alt + Space`.

### Co může nainstalovaný motiv obsahovat

Motiv, který sami napíšete do složky `~/.config/omarchy/themes`, může obsahovat cokoli — je to váš počítač a váš soubor a Omarchy použije všechno.

Motiv, který nainstalujete z cizího repozitáře příkazem `omarchy theme install`, si ponechá vše, co je barva, a přijde o hrstku souborů, které by na vašem počítači spouštěly kód: jakýkoli soubor `.lua`, konfigurace terminálu (`alacritty.toml`, `foot.ini`, `ghostty.conf`, `kitty.conf`) a soubor `vscode.json`. Soubor `hyprland.lua` motivu je kód Lua, který váš kompozitor spustí při přihlášení, konfigurace terminálu určuje program, který váš terminál spustí, a soubor `vscode.json` určuje rozšíření VSCode, které se má nainstalovat. Instalace cizího motivu by měla změnit vzhled vaší plochy, nikdy to, co se na ní spouští.

Všechno ostatní nadále funguje přesně tak, jak autor motivu zamýšlel — soubory `btop.theme`, `chromium.theme`, `helix.toml`, `icons.theme`, `shell.toml`, pozadí i náhledy se zachovají. Pouze to, co bylo odebráno, se na vašem počítači opět vygeneruje ze souboru `colors.toml`.

Omarchy oba typy odliší podle toho, zda má motiv uvnitř vlastní repozitář git, což je to, co příkaz `omarchy theme install` po naklonování zanechá. Vlastní motiv si tak můžete upravit podle sebe. U staženého motivu Omarchy vynechá výše uvedené soubory, které mohou spouštět kód.

### Světlý režim

Pokud vytváříte motiv se světlým režimem, nastavte na začátku souboru `colors.toml` hodnotu `mode = "light"`. Poté se automaticky spáruje se světlým režimem pro všechny aplikace. (Starý způsob, kterým je umístění prázdného souboru s názvem `light.mode` do kořene vašeho motivu, stále funguje.)

### Barvy ikon

Pokud chcete ikony správce souborů barevně sladit se svým motivem, přidejte soubor `icons.theme` s názvem sady ikon, kterou chcete použít. Ve výchozím nastavení jsou možnosti tyto: `Yaru Yaru-blue Yaru-dark Yaru-magenta Yaru-olive Yaru-prussiangreen Yaru-purple Yaru-red Yaru-sage Yaru-wartybrown Yaru-yellow`.

### Obrázek pro odemknutí

Motivy dodávané s obrázky `unlock.png` a `preview-unlock.png` se zobrazí v části _Vzhled > Obrazovka odemykání_. Vaše `unlock.png` by nejlépe mělo být průhledné png. Náhledový obrázek můžete vytvořit příkazem `omarchy plymouth preview`.

### Motivy pro aplikace, které Omarchy nepokrývá

Pro aplikaci, kterou Omarchy přímo nepodporuje, můžete vytvořit vlastní šablonu. Do `~/.config/omarchy/themed/` vložte soubor pojmenovaný podle výsledné konfigurace s přidanou příponou `.tpl`. Barvy v něm nahraďte zástupnými symboly `{{ background }}`, `{{ foreground }}`, `{{ accent }}`, `{{ red }}`, `{{ color0 }}` až `{{ color15 }}` nebo dalšími barvami z palety. Při každém přepnutí motivu se z šablony vygeneruje konfigurace s jeho barvami.

V této složce najdete plně okomentovaný vzor `alacritty.toml.tpl.sample`, ze kterého můžete vyjít — uvádí všechny proměnné, které můžete použít, plus modifikátory `_strip` a `_rgb` pro aplikace, které chtějí barvy bez znaku `#` nebo jako desítkové hodnoty RGB. Vaše šablony mají přednost před šablonami Omarchy, takže tímto způsobem můžete také přepsat, jak se tvoří motiv pro vestavěnou aplikaci.

### Distribuce vašeho motivu

Pokud chcete svůj motiv distribuovat, aby ho mohli používat ostatní, musíte ho umístit na veřejný server git, například GitHub. Poté si ho lidé mohou nainstalovat v nabídce Omarchy v části _Instalovat > Vzhled > Motiv_ pomocí této adresy URL. Doporučuje se dodržovat zásadu pojmenování `omarchy-[themename]-theme`, protože motiv se po instalaci v nabídce výběru motivu správně zobrazí jen jako `[themename]`.

Zbylé `[themename]` se stává názvem adresáře motivu, takže musí jít o název, který může Omarchy bezpečně předávat: musí začínat písmenem, číslicí nebo podtržítkem a zbytek může obsahovat písmena, číslice, `.`, `_`, `+` a `-`. Velká písmena se vám převedou na malá, ale cokoli jiného — mezera, uvozovka, znak mimo ASCII — se při instalaci odmítne, místo aby se z toho stal název adresáře. Názvy `omarchy-tokyo-night-theme`, `omarchy-flexoki_light-theme` i `omarchy-c++-theme` se všechny nainstalují bez potíží.

Nezapomeňte, že po instalaci z repozitáře se všechny dodávané soubory `.lua`, konfigurace terminálu nebo `vscode.json` zahodí, takže motiv kolem nich nestavějte.

Svůj motiv můžete přidat na [stránku s dalšími motivy](https://omarchy.org/themes/) zasláním pull requestu do [repozitáře omarchy-site](https://github.com/omacom-io/omarchy-site).
