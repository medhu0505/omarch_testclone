# Síť

Síť v Omarchy zajišťuje NetworkManager a ovládáte ji přes ikonu sítě v [horní liště](05-the-top-bar.md) nebo zkratkou `Super + Ctrl + W`.

Panel vyhledává sítě Wi-Fi, zobrazuje sílu signálu a připojuje. Ethernet nevyžaduje vůbec nic — zapojíte kabel a funguje. Pokud raději zůstáváte v terminálu, `nmtui` nabízí stejné ovládací prvky a existuje také skupina příkazů `omarchy network`.

## Sdílení vaší Wi-Fi

Místo abyste nahlas četli dlouhé heslo, spusťte, zatímco jste připojeni přes Wi-Fi, volbu _Nastavení > Síť > QR kód_. Na obrazovce se zobrazí QR kód, který může naskenovat fotoaparát libovolného telefonu a připojit se. Patří k věcem, které budete používat častěji, než byste čekali, jakmile o nich víte.

Pokud skutečně potřebujete samotné heslo, vypíše ho příkaz `omarchy network password <interface>`.

## DNS

Omarchy používá DNS, které vaše síť předává přes DHCP. Pro celý počítač to můžete přepsat v části _Nastavení > Síť > DNS_, kde jsou Cloudflare a Google na jedno kliknutí daleko. Volba _Vlastní_ vám umožní zadat vlastní servery.

Z terminálu příkaz `omarchy dns` vypíše aktuálního poskytovatele a příkaz `omarchy dns Cloudflare` některého nastaví.

## Výběr pásma Wi-Fi

Pokud váš router používá pro pásma 2,4 GHz, 5 GHz a 6 GHz stejný název sítě, notebook se někdy připojí k pomalejšímu pásmu. Příkaz `omarchy network band` ukáže, ve kterém pásmu jste, a příkaz `omarchy network band 5` omezí připojení na 5 GHz. Pomocí `auto` znovu povolíte automatický výběr.

Omezí se pouze pásmo, nikoli konkrétní přístupový bod. Zařízení tak může nadále automaticky přecházet mezi přístupovými body.

## Jak je rychlá?

Volba _Akce > Test rychlosti > Test rychlosti sítě_ měří vaši skutečnou rychlost stahování a odesílání pomocí dvojice ukazatelů. Z terminálu to je `omarchy network speedtest down` nebo `up`. (Ve stejné nabídce vedle něj sedí test rychlosti disku, pokud zrovna měříte druhé úzké hrdlo.)

## Firewall

Firewall je ve výchozím nastavení zapnutý a blokuje veškerý příchozí provoz s jednou výjimkou: portem 53317, aby aplikace [LocalSend](22-guis.md) fungovala ihned po instalaci.

SSH je vypnuté, dokud ho nezapnete volbou _Nastavení > Zabezpečení > SSHD_, která spustí démona, otevře port 22 s omezením rychlosti proti útokům hrubou silou a autorizuje klíč. I Docker je uzamčený, aby se kontejnery nemohly nechtěně vystavit světu. Celý příběh najdete v části [zabezpečení](48-security.md).

## Tailscale

[Tailscale](https://tailscale.com/) je síťová VPN typu mesh, která umožňuje jednoduše a bezpečně dosáhnout na všechny vaše počítače a servery přes internet. Nainstalujete ji volbou _Instalovat > Služba > Tailscale_.

Na horní liště tím získáte ikonu Tailscale. Otevře ovládací panel, ve kterém se můžete připojit k síti Tailscale nebo se odpojit, přepnout účet a vybrat výstupní uzel — v seznamu se objeví vaše vlastní počítače i regiony sítě Mullvad. Zobrazuje také vaše počítače a nabízí Taildrop: vyberete počítač a stiskem `s` mu pošlete soubory, případně pomocí `c`, `n` a `d` zkopírujete jeho IP adresu, název nebo úplný název DNS. Ekvivalentem v terminálu je `omarchy tailscale send <machine> [file...]` a soubory odeslané vám automaticky skončí ve složce `~/Downloads`. Oznámení o doručení čeká, dokud na něj nekliknete a neotevřete ho nebo ho nezavřete, takže soubor, který dorazí, zatímco nejste u počítače, na vás po návratu stále čeká.

Při instalaci se přidá také webová aplikace pro administrátorskou konzoli Tailscale.

## Když přestane fungovat

Než budete restartovat počítač, zkuste restartovat pouze danou problematickou součást. Volba _Aktualizovat > Hardware_ nabízí Wi-Fi, Bluetooth, Zvuk a Touchpad a opětovné načtení některé z nich vyřeší většinu situací typu „před pěti minutami to fungovalo“. Viz [řešení potíží](45-troubleshooting.md).
