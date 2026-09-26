# Tab at OriCode's shell prompt, answered by the user's own zsh (ZshCompletion.swift).
#
# OriCode starts `zsh -l -i` behind a pty with ZDOTDIR at a folder of its own, whose .zshenv,
# .zprofile and .zshrc each source this file with their name. The user's file of that name is read
# in its place; after .zshrc, ZDOTDIR stays the user's, so zsh reads their .zlogin itself.
#
# A Tab is a file of three lines in that folder, its number, the folder and the line so far, and a
# key bound to _oricode_tab, which completes the line as a Tab would and prints each match between
# two marks instead of listing it.

_oricode_file=$1
_oricode_ours=$ZDOTDIR
ZDOTDIR=${ORICODE_USER_ZDOTDIR:-$HOME}
[[ -r $ZDOTDIR/$_oricode_file ]] && source $ZDOTDIR/$_oricode_file
# Their .zshenv may have moved it, to ~/.config/zsh say.
ORICODE_USER_ZDOTDIR=$ZDOTDIR
if [[ $_oricode_file != .zshrc ]]; then
  ZDOTDIR=$_oricode_ours
  return
fi

# Nothing is run here, and nothing of this shell belongs in the user's history.
unset HISTFILE

# One match per line, whatever the user's styles group together, and its description after --,
# which is where ShellCompletion.zsh(_:line:) looks for it.
zstyle ':completion:*' list-grouped false
zstyle ':completion:*' list-separator --

# Each match a completion function adds goes in as usual, and is printed as where its word starts
# in the line, the word it would make there, and the text it's listed with. The locals are named
# apart, since compadd -a and -k read arrays by name from the function calling it.
compadd() {
  setopt localoptions extendedglob
  # The options that shape the word, read the way compadd reads them: letters cluster, and one
  # that takes a value takes the rest of its word or the next.
  local -A _oricode_opt
  local _oricode_arg _oricode_letter _oricode_rest
  local -i _oricode_i=1
  while (( _oricode_i <= $# )); do
    _oricode_arg=${@[_oricode_i]}
    [[ $_oricode_arg == (-|--) || $_oricode_arg != -* ]] && break
    _oricode_rest=${_oricode_arg#-}
    while [[ -n $_oricode_rest ]]; do
      _oricode_letter=${_oricode_rest[1]} _oricode_rest=${_oricode_rest[2,-1]}
      if [[ $_oricode_letter == [PSpsiIWdJVXxrRMFOADE] ]]; then
        [[ -z $_oricode_rest ]] && _oricode_rest=${@[++_oricode_i]}
        _oricode_opt[$_oricode_letter]=$_oricode_rest
        _oricode_rest=
      elif [[ $_oricode_letter == o ]]; then
        # -o's order is optional, so the next word is its only if it reads as one.
        [[ -z $_oricode_rest && ${@[_oricode_i+1]} == (match|nosort|numeric|reverse)(,*|) ]] && _oricode_rest=${@[++_oricode_i]}
        _oricode_opt[o]=${_oricode_rest:-match}
        _oricode_rest=
      else
        _oricode_opt[$_oricode_letter]=1
      fi
    done
    (( _oricode_i++ ))
  done
  # -O, -A and -D ask for matches back rather than adding them: a function at work, not an answer.
  if (( ${+_oricode_opt[O]} || ${+_oricode_opt[A]} || ${+_oricode_opt[D]} )); then
    builtin compadd "$@"
    return
  fi

  local -a _oricode_words _oricode_shown
  if [[ $_oricode_opt[d] == \(* ]]; then
    eval "_oricode_shown=$_oricode_opt[d]"
  elif [[ -n $_oricode_opt[d] ]]; then
    _oricode_shown=("${(@P)_oricode_opt[d]}")
  fi
  builtin compadd -A _oricode_words -D _oricode_shown "$@"
  builtin compadd "$@"
  local -i _oricode_added=$?

  (( $#_oricode_words )) || return $_oricode_added

  # From the line as sent, since inside quotes zsh takes the opening one out of LBUFFER.
  local -i _oricode_start=$(( ${#_oricode_line} - ${#QIPREFIX} - ${#IPREFIX} - ${#PREFIX} ))
  local _oricode_match _oricode_word
  # zsh sorts each group it lists unless it's -V or -o nosort; OriCode sorts them the same way.
  local _oricode_group=${_oricode_opt[J]:+J$_oricode_opt[J]}
  [[ -n $_oricode_opt[V] || $_oricode_opt[o] == *nosort* ]] && _oricode_group=V$_oricode_opt[V]
  for _oricode_i in {1..$#_oricode_words}; do
    _oricode_match=$_oricode_words[_oricode_i]
    if [[ -z $_oricode_opt[Q] ]]; then
      case $compstate[quote] in
        \") _oricode_match=${_oricode_match//(#m)[\"\\\$\`]/\\$MATCH} ;;
        \') ;;
        *) _oricode_match=${(q)_oricode_match} ;;
      esac
    fi
    _oricode_word=$QIPREFIX$IPREFIX$_oricode_opt[i]$_oricode_opt[P]$_oricode_opt[p]$_oricode_match$_oricode_opt[s]
    # A file's match that is a folder takes a slash, as zsh's own listing shows it. -W is the
    # folder the matches are in, else they're where -p says.
    [[ -n $_oricode_opt[f] && -z $_oricode_opt[s] && -d ${_oricode_opt[W]:-${~${(Q)_oricode_opt[p]}}}${(Q)_oricode_words[_oricode_i]} ]] && _oricode_word+=/
    [[ $_oricode_opt[S] != ' ' ]] && _oricode_word+=$_oricode_opt[S]
    print -rn -- $_oricode_start$'\x1f'$_oricode_word$'\x1f'$_oricode_shown[_oricode_i]$'\x1f'$_oricode_group$'\n'
  done
  return $_oricode_added
}

# Nothing listed and no menu: the matches go to OriCode, and the line takes what they agree on.
_oricode_quiet() {
  compstate[list]=
  (( compstate[nmatches] > 1 )) && compstate[insert]=unambiguous
}
zle -C _oricode_complete complete-word _main_complete

_oricode_tab() {
  local _oricode_id _oricode_folder _oricode_line
  {
    IFS= read -r _oricode_id
    IFS= read -r _oricode_folder
    IFS= read -r _oricode_line
  } < $_oricode_ours/request
  cd -q -- $_oricode_folder 2>/dev/null
  BUFFER=$_oricode_line
  CURSOR=$#BUFFER
  print -rn -- $'\x1e'$_oricode_id$'\n'
  # _main_complete empties comppostfuncs after each completion.
  comppostfuncs+=(_oricode_quiet)
  zle _oricode_complete
  print -rn -- $'\x1d'$BUFFER$'\n\x1e'$_oricode_id$'\n'
  BUFFER=
}
zle -N _oricode_tab
for _oricode_map in emacs viins vicmd; do
  bindkey -M $_oricode_map $'\e[5555~' _oricode_tab
done
unset _oricode_map _oricode_file
