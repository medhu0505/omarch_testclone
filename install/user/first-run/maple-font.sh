# The installer asks no language, so a Chinese keyboard is how someone says
# they read Chinese. Not mozc: Maple draws kanji in Chinese forms.
case $(omarchy-input-method status | jq -r .installed_method) in
pinyin | chewing | cangjie5) omarchy-font-invite-maple ;;
esac
