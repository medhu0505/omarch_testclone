# Fix microphone and speakers on the ASUS ProArt PX13 HN7306 (Strix Halo).
#
# Stock installs of alsa-ucm-conf (as of 1.2.16.1) ship no UCM data for the
# TAS2783 speaker amp used on this board's amd-soundwire card. UCM import
# for the whole card fails as a result (not just the speaker), which takes
# the microphone and headphone paths down with it and leaves PipeWire with
# no real audio device at all -- only its dummy fallback.
#
# The three files below are the already-merged upstream fix
# (alsa-project/alsa-ucm-conf#812), plus explicit PlaybackChannels/Rate/
# Format on the Speaker device: this board's SmartAmp PCM only accepts
# S16_LE/2ch/48000Hz (no ranges), and PipeWire's ACP profile probe defaults
# to a different format/rate before falling back, which fails outright on
# a PCM that offers no alternative to fall back to.
#
# Even with UCM fixed, ACP still can't bring up the "HiFi" profile here: it
# bundles the Speaker and Headphones ports into one sink mapping, and the
# rt721 "SimpleJack" headphone PCM fails to open at the driver level
# (unrelated to UCM, and unrelated to whether a jack is physically
# plugged in) on this board's current SOF/soundwire driver stack. One
# broken port takes the whole profile down with it, including the mic.
# Until that driver issue is fixed upstream, this uses the "pro-audio"
# profile instead, which exposes each working port independently and
# tolerates the broken one.
#
# Under "pro-audio", UCM's Speaker EnableSequence never runs (pro-audio
# talks to raw ALSA devices directly, bypassing UCM device enable/disable),
# so the amp's four hardware enable switches (Left/Right Spk[2] Switch)
# come up off and stay off -- not just at boot, but after every WirePlumber
# restart, since each restart re-probes and re-activates the profile the
# same way. A systemd drop-in re-applies them after every WirePlumber
# start, once its own profile activation has settled (setting them too
# early gets them reset right back to off by that activation). It runs in
# the background so it never delays or fails the WirePlumber start. This is
# safe with respect to user mute preferences: it only touches this
# hardware enable gate, which has no exposure in any mute UI on this
# card -- actual user mute (volume slider, mute key) is PipeWire's own
# per-sink software Mute/Volume, a separate layer WirePlumber already
# persists correctly on its own and which this never touches.
#
# This runs as root during installation, so the WirePlumber rules and the
# wireplumber.service drop-in go to the system-wide /etc locations, which
# apply to every user, rather than to a home directory.
#
# The UCM files are only written while they're missing, so a copy that
# alsa-ucm-conf ships later is never overwritten here.

if omarchy-hw-asus-proart-px13-hn7306; then
  [[ -e /usr/share/alsa/ucm2/codecs/tas2783/init.conf ]] || sudo install -Dm644 /dev/stdin /usr/share/alsa/ucm2/codecs/tas2783/init.conf <<'EOF'
# tas2783 specific switch control settings

BootSequence [
	cset "name='Left Spk' on"
	cset "name='Right Spk' on"
	cset "name='Left Spk2' on"
	cset "name='Right Spk2' on"
]
EOF

  [[ -e /usr/share/alsa/ucm2/sof-soundwire/tas2783.conf ]] || sudo install -Dm644 /dev/stdin /usr/share/alsa/ucm2/sof-soundwire/tas2783.conf <<'EOF'
# Use case Configuration for sof-soundwire card

SectionDevice."Speaker" {
	Comment	"Speaker"

	EnableSequence [
		cset "name='Left Spk Switch' on"
		cset "name='Right Spk Switch' on"
		cset "name='Left Spk2 Switch' on"
		cset "name='Right Spk2 Switch' on"
	]

	DisableSequence [
		cset "name='Left Spk Switch' off"
		cset "name='Right Spk Switch' off"
		cset "name='Left Spk2 Switch' off"
		cset "name='Right Spk2 Switch' off"
	]

	Value {
	      PlaybackPriority 100
	      PlaybackPCM "hw:${CardId},2"
	      PlaybackChannels 2
	      PlaybackRate 48000
	      PlaybackFormat "S16_LE"
	}
}
EOF

  # Adds tas2783 to the speaker-codec filter regex, matching alsa-ucm-conf#812
  # as merged (the reviewer asked for tas2783 to stay out of MultiCodecRegex,
  # since it defines only a Speaker device, not a multi-function codec, so
  # only this one line changes). Exact string replace, not sed, to avoid any
  # ambiguity from the heavy regex-special-character content of this line.
  # Raw strings keep the file's literal "\\+" intact. A file that doesn't
  # match the expected version is left alone without failing the install.
  sudo python3 - <<'EOF'
import os

path = "/usr/share/alsa/ucm2/sof-soundwire/sof-soundwire.conf"
old = "\t\t\t" + r'Regex "(${var:MultiCodecRegex}|rt1318|cs42l43-spk(\\+cs35l56)?|cs35l56((-bridge)|(\\+cs42l43-spk))?)"' + "\n"
new = "\t\t\t" + r'Regex "(${var:MultiCodecRegex}|tas2783|rt1318|cs42l43-spk(\\+cs35l56)?|cs35l56((-bridge)|(\\+cs42l43-spk))?)"' + "\n"

if not os.path.exists(path):
    print(f"{path} not found, skipping tas2783 speaker regex patch")
else:
    with open(path) as f:
        content = f.read()
    if new in content:
        pass
    elif content.count(old) != 1:
        print(
            f"expected exactly 1 occurrence of the unpatched line, found {content.count(old)} "
            "-- sof-soundwire.conf may differ from the version this fix was written against, skipping"
        )
    else:
        with open(path, "w") as f:
            f.write(content.replace(old, new, 1))
EOF

  sudo install -Dm644 /dev/stdin /etc/wireplumber/wireplumber.conf.d/asus-proart-px13-hn7306-audio.conf <<'EOF'
## Use the pro-audio profile on the amd-soundwire card of the ASUS ProArt
## PX13 HN7306, give its ports friendly names, and hide its non-functional
## amp-telemetry capture channel. The card only reports a generic "Audio
## Coprocessor" description, so pro-audio's raw port names default to
## "Audio Coprocessor Pro N". Names are matched by suffix so the PCI
## address the card enumerates at doesn't matter.

monitor.alsa.rules = [
  {
    matches = [
      { device.name = "~alsa_card.*-platform-amd_sdw" }
    ]
    actions = { update-props = { device.profile = "pro-audio" } }
  }
  {
    matches = [
      { node.name = "~alsa_output.*-platform-amd_sdw.pro-output-0" }
    ]
    actions = { update-props = { node.description = "PX13 Headphones" node.nick = "Headphones" } }
  }
  {
    matches = [
      { node.name = "~alsa_output.*-platform-amd_sdw.pro-output-2" }
    ]
    actions = { update-props = { node.description = "PX13 Speakers" node.nick = "Speakers" } }
  }
  {
    matches = [
      { node.name = "~alsa_input.*-platform-amd_sdw.pro-input-1" }
    ]
    actions = { update-props = { node.description = "PX13 Headset Microphone" node.nick = "Headset Mic" } }
  }
  {
    ## pro-input-3 is the tas2783 amp's internal feedback/telemetry capture
    ## channel (speaker protection DSP), not a real microphone, and it is
    ## unreliable to stream from. Hide it from mic pickers entirely.
    matches = [
      { node.name = "~alsa_input.*-platform-amd_sdw.pro-input-3" }
    ]
    actions = { update-props = { node.description = "PX13 Speaker Amp Reference (internal)" node.disabled = true } }
  }
  {
    matches = [
      { node.name = "~alsa_input.*-platform-amd_sdw.pro-input-4" }
    ]
    actions = { update-props = { node.description = "PX13 Internal Microphone" node.nick = "Internal Mic" } }
  }
]
EOF

  sudo install -Dm644 /dev/stdin /etc/systemd/user/wireplumber.service.d/asus-proart-px13-hn7306-speaker-enable.conf <<'EOF'
[Service]
ExecStartPost=-/bin/bash -c '(sleep 3; for c in "Left Spk Switch" "Right Spk Switch" "Left Spk2 Switch" "Right Spk2 Switch"; do amixer -c amdsoundwire cset iface=MIXER,name="$c" on >/dev/null 2>&1; done) &'
EOF

  for control in "Left Spk Switch" "Right Spk Switch" "Left Spk2 Switch" "Right Spk2 Switch"; do
    amixer -c amdsoundwire cset iface=MIXER,name="$control" on >/dev/null 2>&1 || true
  done
  sudo alsactl store 2>/dev/null || true
fi
