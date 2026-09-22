# powerlevel10k's instant prompt. Inert unless you use p10k.
#
# ORDERING IS LOAD-BEARING AND THIS IS THE ONLY UNIT WHERE THAT IS TRUE.
#
# p10k's instant prompt replays a cached prompt before the rest of zsh startup runs, and it
# refuses to do that if anything writes to the console first -- it prints a multi-paragraph
# "[WARNING]: Console output during zsh initialization detected" and then makes the prompt
# jump. So this has to come before any unit that can print.
#
# That currently holds because macboot's other units are silent on a normal start, and it is
# worth knowing WHY rather than trusting it: 80-plugins.zsh only prints if autojump.sh is
# missing, and 50-compinit.zsh only prints under MACBOOT_ZSH_COMPAUDIT. If you add a unit
# below 05 that prints, or make one of those print unconditionally, you break the instant
# prompt and the symptom will look like a p10k bug rather than an ordering one.
#
# `05` rather than `00`: 00-path.zsh sets PATH and prints nothing, and having PATH ready
# first is worth more than five filenames of margin.
#
# SKIPPED WHILE PROFILING, because the two cannot coexist: rc.zsh's profiler prints a
# timing line per unit DURING startup, which is exactly the console output the instant
# prompt refuses to tolerate. Without this, `zprofile` ends every run with p10k's
# multi-paragraph "[WARNING]: Console output during zsh initialization detected" -- a
# warning macboot causes and then shows you, about nothing. Skipping also takes this unit's
# own ~13 ms out of a measurement you are taking to find where the time goes.
#
# The cache path is p10k's own, not ours -- do not "tidy" it into $XDG_CACHE_HOME
# unconditionally, because p10k computes this exact string itself and would miss the file.
if [[ -z ${MACBOOT_ZSH_PROFILE:-} ]] &&
  [[ -r ${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh ]]; then
  source ${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh
fi
