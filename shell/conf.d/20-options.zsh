# 20-options.zsh — shell behaviour. A deliberately short list: every entry here
# changes how your shell responds to something you already type, so the bar for
# adding one is "the default is actively surprising", not "this is nicer".

setopt INTERACTIVE_COMMENTS # off by default in zsh: pasting any command with a
# trailing `# comment` fails with "no such file"
setopt NO_BEEP
setopt NO_FLOW_CONTROL # frees ^S/^Q, which otherwise freeze the terminal for good
