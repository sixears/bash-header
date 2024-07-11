{pkgs?import<nixpkgs>{} }:pkgs.writeTextFile{name = "header.bash";text = ''#
# Use a dedicated fd for logging/warning/debugging, to avoid confusion with
# called cmds that write to stderr.
exec 99>&2

set -u -o pipefail -o noclobber
shopt -s nullglob
PATH=/dev/null

# noclobber: don't overwrite extant files with shell redirects
set -o noclobber
# nullglob: If set, bash allows patterns which match no files to expand to a
#           null string, rather than themselves.
shopt -s nullglob

declare -A Cmd

# we'd might as well pre-add coreutils cmds, as we already depend on coreutils
Cmd[basename]=${pkgs.coreutils}/bin/basename
Cmd[bash]=${pkgs.bash}/bin/bash
Cmd[cat]=${pkgs.coreutils}/bin/cat
Cmd[chmod]=${pkgs.coreutils}/bin/chmod
Cmd[chown]=${pkgs.coreutils}/bin/chown
Cmd[cp]=${pkgs.coreutils}/bin/cp
Cmd[cpio]=${pkgs.cpio}/bin/cpio
Cmd[cut]=${pkgs.coreutils}/bin/cut
Cmd[date]=${pkgs.coreutils}/bin/date
Cmd[dirname]=${pkgs.coreutils}/bin/dirname
Cmd[du]=${pkgs.coreutils}/bin/du
Cmd[env]=${pkgs.coreutils}/bin/env
Cmd[find]=${pkgs.findutils}/bin/find
Cmd[flock]=${pkgs.utillinux}/bin/flock
Cmd[getopt]=${pkgs.utillinux}/bin/getopt
Cmd[grep]=${pkgs.gnugrep}/bin/grep
Cmd[head]=${pkgs.coreutils}/bin/head
Cmd[id]=${pkgs.coreutils}/bin/id
Cmd[ln]=${pkgs.coreutils}/bin/ln
Cmd[ls]=${pkgs.coreutils}/bin/ls
Cmd[mkdir]=${pkgs.coreutils}/bin/mkdir
Cmd[mktemp]=${pkgs.coreutils}/bin/mktemp
Cmd[mv]=${pkgs.coreutils}/bin/mv
Cmd[nix]=${pkgs.nix}/bin/nix
Cmd[nix-env]=${pkgs.nix}/bin/nix-env
Cmd[pv]=${pkgs.pv}/bin/pv
Cmd[realpath]=${pkgs.coreutils}/bin/realpath
Cmd[rm]=${pkgs.coreutils}/bin/rm
Cmd[seq]=${pkgs.coreutils}/bin/seq
Cmd[sleep]=${pkgs.coreutils}/bin/sleep
Cmd[sort]=${pkgs.coreutils}/bin/sort
Cmd[stat]=${pkgs.coreutils}/bin/stat
Cmd[sudo]=/run/wrappers/bin/sudo
Cmd[tail]=${pkgs.coreutils}/bin/tail
Cmd[tee]=${pkgs.coreutils}/bin/tee
Cmd[touch]=${pkgs.coreutils}/bin/touch
Cmd[tr]=${pkgs.coreutils}/bin/tr
Cmd[tty]=${pkgs.coreutils}/bin/tty
Cmd[wc]=${pkgs.coreutils}/bin/wc

DryRun=false
OrigArgs=( "$@" )
Progname="$(''${Cmd[basename]} "$0")"
Verbose=0
Cleanups=()
Tab="$(echo -en \\t)"
Debug=false
UseShowCmds=false
ShowCmds=false

# ------------------------------------------------------------------------------

warn               () { local i; for i in "$@"; do echo -e "$i" >&99; done; }
warnf              () { printf "$@" >&99; }
info_              () { local m=$1; [[ $m -le $Verbose ]] && warn "''${@:2}"; }
infof_             () { local m=$1; [[ $m -le $Verbose ]] && warnf "''${@:2}"; }
info               () { info_ 1 "$@"; }
infof              () { infof_ 1 "$@"; }
info2              () { info_ 2 "$@"; }
info3              () { info_ 3 "$@"; }
die                () { warn "$Progname: ''${@:2}"; exit "''${@:1:1}"; }
dieusage           () { die   2 "$@"; }
dieinternal        () { die 255 "$@"; }
die_unless_dryrun  () { warn "''${@:2}"; $DryRun || exit "''${@:1:1}"; }
# don't use `die` here, as we don't want to precede with the progname
usage  () { warn "$Usage"; exit 2; }
debug  () {
  $Debug || return
  local i
  for i in "$@"; do warn "DEBUG: $Progname: $i"; done
}
debugf () { $Debug || return; warnf "DEBUG: $Progname: $1" "''${@:2}"; }

# ------------------------------------------------------------------------------

loc() {
  local level=''${1:-1}
  local funcname=''${FUNCNAME[$level]:-UNKNOWN}
  local bash_source=''${BASH_SOURCE[$level+1]:-UNKNOWN}
  local bash_lineno=''${BASH_LINENO[$level]:-UNKNOWN}

  echo "$funcname ($bash_source:$bash_lineno)"
}

# -------------------------------------

# Print the arguments in a form suitable for feeding to bash (i.e., with
# quoting).
# args:
#   *) cmd - A cmd (typically), in original form.
# returns:
#   *) strings - The input cmd, suitable quoted to be able to re-execute with
#                copy-n-paste on the cmdline.
showcmd () {
  [[ $# -ge 1 ]] || dieinternal "$(loc 1) showcmd called with no arguments"
  for i in "''${@:1:$(($#-1))}"; do
    builtin printf '%q ' "$i"
  done
  builtin printf '%q\n' "''${@:$(($#))}"
}

# -------------------------------------

# Internal engine for go* cmds.  Takes a cmd (list of words), and executes that
# cmd.  Uses info() to write cmd to stderr in verbose mode.
#
# Usage: _go <--exit <NUM>|--no-exit|no-exit-status> option* --CMD
#
# Options
#   --exit <NUM>           If the command fails, exit(die) with this exit code.
#                          Either this, or --no-exit must be specified.
#   --no-exit              Do not exit, evin if the command fails.   Either this
#                          or --exit <NUM> must be specified,
#   --no-exit-status       Always return 0, even if the command exits non-zero.
#                          Implies --no-exit.
#   --return-zero          If the command succeeds (per --expect), then return
#                          0.  If used without --expect, then as 0 is the
#                          default expect, this is effectively a no-op.
#                          N.B., this is different from --no-exit-status because
#                          that command never returns non-zero; whereas this
#                          will return non-zero if the command exits with a
#                          value that is not in the expect list.
#   --expect <NUM(,NUM)*>  Typically, the cmd is considered to have failed if it
#                          exits with any code other than 0.  This sets the
#                          expected exit values to some other set.
#   --no-dry-run           Run the command even in $DryRun mode.
#   --eval                 Eval the arguments rather than just executing them.
#   --cmd <CMD>            By default, the cmd is called as-is; with this, the
#                          value CMD is used as an index into the global `Cmd`
#                          dictionary; the value found is prepended to the cmd
#                          words.  If the given CMD is not found in the global
#                          `Cmd` dictionary, then we exit (dieinternal).

_go() {
  # getopt bug: there must be a -o provided, even if it is empty; else it will
  # take the first provided argument not beginning with '-', and treat that as
  # an argument to -o !
  local -a getopt_opts=( --options ""
			 --long exit:,no-dry-run,eval,no-exit,expect:,cmd:
                         --long info-level:,no-exit-status,return-zero )
  local -a getopt_cmd=( ''${Cmd[getopt]} "''${getopt_opts[@]}" -- "$@" )
  # no quote protection around $(...) here - getopt pre-quotes values
  local -a opts=$( "''${getopt_cmd[@]}" ); local rv=$?
  [ 0 -eq $rv ] || dieinternal "$(loc 2): options parsing failed ($rv)"

  # copy the values of opts (getopt quotes them) into the shell's $@
  eval set -- "$opts"

  local no_exit=false
  local expect=()
  local exit=""
  local dryrun=$DryRun
  local eval=false
  local usecmd=""
  local -a cmd=()
  local info_level=1
  local return_zero=false

  local xs

  while [[ 0 -ne $# ]]; do
    case "$1" in
      --exit           ) exit="$2"                       ; shift 2 ;;
      --no-exit        ) no_exit=true                    ; shift   ;;
      --no-exit-status ) no_exit=true; return_zero=true  ; shift   ;;
      --return-zero    ) return_zero=true                ; shift   ;;
      --no-dry-run     ) dryrun=false                    ; shift   ;;
      --eval           ) eval=true                       ; shift   ;;
      --cmd            ) usecmd="$2"                     ; shift 2 ;;
      --info-level     ) info_level="$2"                 ; shift 2 ;;
      --expect         )
        IFS=, read -a xs <<<"$2"; expect+=("''${xs[@]}") ; shift 2 ;;
      --               ) cmd+=("''${@:2}")               ; break   ;;
      *                ) cmd+=("$1")                     ; shift   ;;
    esac
  done

  if [[ -z $exit ]]; then
    if ! $no_exit; then
      dieinternal "$(loc 2): specify --exit <VAL> or --no-exit"
    fi
  else
    if [[ $exit =~ ^[0-9]+$ ]]; then
      if [[ 255 -lt $exit ]]; then
        dieinternal "$(loc 2): --exit must not be <= 255 (got $exit)"
      fi
    else
      dieinternal "$(loc 2): exit must be in the range [0,255] (got $exit)"
    fi
  fi

  if [ 0 -eq ''${#expect[@]} ]; then
    expect=(0)
  fi

  if [[ x != x$usecmd ]]; then
    if [[ -v Cmd[$usecmd] ]]; then
      cmd=(''${Cmd[$usecmd]} "''${cmd[@]}")
    else
      dieinternal "$(loc 2): called with non-extant CMD '$usecmd'"
    fi
  fi

  local -A expects
  local e
  for e in "''${expect[@]}"; do
    expects["$e"]=1
  done

  [[ ''${#cmd[@]} -ge 1 ]] || dieinternal "$(loc 2) _go called with no cmd"
  cmdstr="$(showcmd "''${cmd[@]}")"
  if $dryrun; then
    if $UseShowCmds; then
      $ShowCmds && warn "(CMD) $cmdstr"
    else
      info_ "$info_level" "(CMD) $cmdstr"
    fi
  else
    if $UseShowCmds; then
      $ShowCmds && warn "CMD> $cmdstr"
    else
      info_ "$info_level" "CMD> $cmdstr"
    fi

    if $eval; then eval "''${cmd[@]}"; else "''${cmd[@]}"; fi; rv=$?
    if ! $no_exit && [[ ! -v expects[$rv] ]]; then
      die "$exit" "failed (got $rv; expected ''${expect[@]}): $cmdstr"
    fi
    if $return_zero; then
      if $no_exit || [[ -v expects[$rv] ]]; then
        return 0
      else
        return $rv
      fi
    else
      return $rv
    fi
  fi
}

# ------------------

go               () { _go --exit "$1" -- "''${@:2}"; }
gocmd            () { _go --exit "$1" --cmd "$2" -- "''${@:3}"; }
gocmd2           () { _go --exit "$1" --cmd "$2" --info-level 2 -- "''${@:3}"; }
goeval           () { _go --exit "$1" --eval -- "''${@:2}"; }
goevalnodryrun   () { _go --exit "$1" --eval --no-dry-run -- "''${@:2}"; }
gocmdeval        () { _go --exit "$1" --eval --cmd "$2" -- "''${@:3}"; }
gonodryrun       () { _go --exit "$1" --no-dry-run -- "''${@:2}"; }
gocmdnodryrun    () { _go --exit "$1" --cmd "$2" --no-dry-run -- "''${@:3}"; }
gocmdnoexit      () { _go --no-exit --cmd "$1" -- "''${@:2}"; }
gonoexit         () { _go --no-exit -- "$@"; }
gocmdnoexitnodryrun   () { _go --no-exit --no-dry-run --cmd "$1" -- "''${@:2}"; }
gocmdnodryrunnoexit   () { _go --no-exit --no-dry-run --cmd "$1" -- "''${@:2}"; }
gocmdnodryrunexitzero () { _go --no-exit-status --no-dry-run --cmd "$1" -- "''${@:2}"; }
gocmd2nodryrun   () {
  _go --exit "$1" --cmd "$2" --info-level 2 --no-dry-run -- "''${@:3}"
}
gocmd3nodryrun   () {
  _go --exit "$1" --cmd "$2" --info-level 3 --no-dry-run -- "''${@:3}"
}
gocmd2noexitnodryrun () {
  _go --no-exit --no-dry-run --cmd "$1" --info-level 2 -- "''${@:2}"
}

# like gocmd, but expects 0 or 1 for exit; returns 0 if cmd returns 0 or 1
gocmd01 () {
  _go --exit "$1" --cmd "$2" --expect 0,1 --return-zero -- "''${@:3}"
}
# like gocmd, but expects 0 or 1 for exit; returns 0 if cmd returns 0 or 1
gocmd01nodryrun () {
  _go --exit "$1" --cmd "$2" --expect 0,1 --return-zero --no-dry-run -- \
      "''${@:3}"
}

# --------------------------------------

# gocmd{noexit,}{nodryrun,}; dependent on the exit code
#
# arguments:
#   -) Exit code on failure (including no lines produced).
#      Use 0 for noexit.  Use -<exit> for nodryrun.  Use -0 for noexit nodryrun.
#   -) The Cmd index to use.
#   *) Arguments to the cmd.
gocmde() {
  if [[ - == ''${1:0:1} ]]; then
    # nodryrun
    if [[ 0 -eq $1 ]]; then
      # noexit
      gocmdnoexitnodryrun "''${@:2}"
    else
      gocmdnodryrun "$1" "''${@:2}"
    fi

  elif [[ 0 -eq $1 ]]; then
    # noexit
    gocmdnoexit "''${@:2}"
  else
    gocmd "$1" "''${@:2}"
  fi
}

# --------------------------------------

# check that the value of $1 is $0, else fail citing $2...
check() { [[ 0 -eq $1 ]] || die "$1" "''${*:2} failed"; }
check_() { check $? "''${@:1}"; }

# --------------------------------------

id_u() {
  local id
  id="$( gocmdnodryrun 253 id --user )"
  rv=$?; [ 0 -eq $rv ] || die $rv "id failed"
  echo "$id"
}

exec_as_root() {
  local id
  id="$(id_u)"; rv=$?; [ 0 -eq $rv ] || die $rv "id failed"
  [ 0 -eq $id ] || go 252 exec ''${Cmd[sudo]} "$0" "''${OrigArgs[@]}"
}

# --------------------------------------

# Create a file or directory, in a temporary space, that will be automatically
# cleaned up; write the name of this created file to a given var.
#
# Args:
#   varname ) the variable to write the created dir name to
#
# Options:
#   --dir                 ) Create a directory rather than a file.
#   --exit       EXITCODE ) On failure, exit this.  Defaults to 253.
#   --tmpdir     TMPDIR   ) Create the tempfile/dir in this dir.  Defaults to
#                           the `mktemp` defaults; $TMPDIR if set, else /tmp.
#   --no-dry-run          ) Create even in dry-run mode.
#   --template   TEMPLATE ) Use this template for the file/dir name.  Defaults
#                           to $Progname.DATE.XXXXXX (but see --infix), where
#                           DATE is the current date, in UTC.  May not contain
#                           '/' chars (or nulls, obviously).  May not be
#                           combined with --infix.
#   --infix      INFIX    ) Use $Progname.INFIX.XXXXXX as the template for the
#                           file/dir name.  May not be combined with --template.
#   --suffix     SUFFIX   ) Append SUFFIX to the template.  May not be combined
#                           with --template.
mktemp() {
  local -a getopt_opts=( --options ""
			 --long dir,exit:,template:,tmpdir:,no-dry-run,infix:
                         --long suffix: )
  local -a getopt_cmd=( ''${Cmd[getopt]} "''${getopt_opts[@]}" -- "$@" )
  # no quote protection around $(...) here - getopt pre-quotes values
  local -a opts=$( "''${getopt_cmd[@]}" ); local rv=$?
  [ 0 -eq $rv ] || dieinternal "$(loc 1): options parsing failed ($rv)"

  # copy the values of opts (getopt quotes them) into the shell's $@
  eval set -- "$opts"

  local exit=253 no_dry_run=false directory=false template="" tmpdir=""
  local suffix=""
  local infix="" args=()
  while [[ 0 -ne $# ]]; do
    case "$1" in
      --dir        ) directory=true       ; shift   ;;
      --exit       ) exit="$2"            ; shift 2 ;;
      --template   ) template="$2"        ; shift 2 ;;
      --infix      ) infix="$2"           ; shift 2 ;;
      --tmpdir     ) tmpdir="$2"          ; shift 2 ;;
      --suffix     ) suffix="$2"          ; shift 2 ;;
      --no-dry-run ) no_dry_run=true      ; shift   ;;
      --           ) args+=( "''${@:2}" ) ; break   ;;
      *            ) args+=( "$1" )       ; shift   ;;
    esac
  done

  if [[ 1 -eq ''${#args[@]} ]]; then
    local varname="$args"
  else
    dieinternal "$(loc 1): takes 1 arg (varname)"
  fi

  local mktemp_cmd=( mktemp )
  if [[ -z $tmpdir ]]; then
    mktemp_cmd+=( --tmpdir )
  else
    mktemp_cmd+=( --tmpdir="$tmpdir" )
  fi
  $directory && mktemp_cmd+=( --directory )
  if [[ -z $template ]]; then
    if [[ -z $infix ]]; then
      infix="$(gocmdnodryrun 252 date +%FZ%R:%S)"; check_ date
    elif [[ $infix != ''${infix#*/} ]]; then
      dieinternal "$(loc 1): infix '$infix' contains slashes"
    fi
    template="$Progname.$infix.XXXXXX''${suffix:-}"
  else # template is a set var
    if [[ -n $suffix ]]; then
      local msg="$(loc 1): cannot set both --template ($template)"
            msg+="&& --suffix ($suffix)"
      dieinternal "$msg"
    fi

    if [[ -z $infix ]]; then
      if [[ $template != ''${template#*/} ]]; then
        dieinternal "$(loc 1): template '$template' contains slashes"
      fi
    else
      local msg="$(loc 1): cannot set both --template ($template)"
            msg+="&& --infix ($infix)"
      dieinternal "$msg"
    fi
  fi

  mktemp_cmd+=( "$template" )

  local tmpd
  if $no_dry_run; then
    tmpd="$( gocmdnodryrun "$exit" "''${mktemp_cmd[@]}" )"; check_ mktemp
  else
    tmpd="$( gocmd "$exit" "''${mktemp_cmd[@]}" )"; check_ mktemp
  fi
  local abs_tmp
  if [[ -n $tmpd ]]; then
    abs_tmp="$(gocmdnodryrun 251 realpath "$tmpd")"; check_ realpath
    Cleanups+=( "$abs_tmp" )
  fi
  printf -v "$varname" %s "$tmpd"
}

# --------------------------------------

cleanup() {
  local i
  local -a failed=()
  for i in "''${Cleanups[@]}"; do
    gocmdnoexitnodryrun rm --force --recursive "$i"; rv=$?
    [ 0 -eq $rv ] || failed+=( "$i" )
  done
  if [ 0 -ne ''${#failed[@]} ]; then
    for i in "''${failed[@]}"; do
      warn "failed to clean up: $i"
    done
    die 254 "Cleanups failed"
  fi
}
trap "cleanup" EXIT

# --------------------------------------

# Copy a directory tree from $1 to $2.  Includes progress bar using `pv`.
# ARGS:
#  -) from (dir; must exist)
#  -) to   (dir; must exist & be empty)
cp_dir() {
  local from="$1" to="$2"
  [[ -d $from ]] || die 244 "$(loc 1) not a directory: '$from'"
  [[ -d $to   ]] || die_unless_dryrun 245 "$(loc 1) not a directory: '$to'"
  dir_empty "$to" || die 246 "$(loc 1) directory not empty: '$to'"

  local du=( du --summarize --bytes "$from" )
  local cut=( cut --delimiter="$Tab" --fields=1 )
  local size
  size="$(gocmd 238 "''${du[@]}" | gocmd 242 "''${cut[@]}")";check $? "du | cut"
  info "source size: $size"

  local find=( find "$from" -depth -printf '%P\n' )
  local cpio_from=( cpio -D "$from" --create )
  local pv=(pv --size "$size" --progress --fineta --rate --eta --bytes )
  local cpio_to=( cpio -D "$to" --extract --make-directories )
  local blocks_grep=( grep --invert-match --extended-regexp '^[0-9]+ blocks' )
  local space

  gocmd 243 "''${find[@]}"                                                     \
    | gocmd 250 grep --invert-match --extended-regexp '^[[:space:]]*$'         \
    | gocmd 249 "''${cpio_from[@]}" \
                                2> >(gocmdnoexit "''${blocks_grep[@]}" 1>&2)   \
    | gocmd 248 "''${pv[@]}"                                                   \
    | gocmd 247 "''${cpio_to[@]}" \
                                2> >(gocmdnoexit "''${blocks_grep[@]}" 1>&2)
  check $? "find | cpio | pv | cpio"
}

# --------------------------------------

# test if dir is empty

dir_empty() { [[ "" == "$( gocmd 240 ls -A "$1" )" ]]; }

# --------------------------------------

# grep out comments & blank lines
#
# arguments:
#   -) Exit code on failure (including no lines produced).
#      See `gocmde` for interpretations.
#
#   *) Passed to grep.
cgrep() {
  local -a grep_args=( --extended-regexp --invert-match '^[[:space:]]*(#.*)?$' )
  gocmde "$1" grep "''${grep_args[@]}" "''${@:2}"
}

# --------------------------------------

# Run a cmd, capture its stdout to a variable.  If the cmd returns non-sero,
# we die with that exit code (citing the cmd that caused it).
#
# Arguments:
#   varname ) write captured output to this
#   cmd+    ) cmd to run, as a list of words
#
# Examples:
#
#   capture Pid gocmdnodryrun 10 cat "$Pidfile"
capture() {
  # use unlikely-looking var names here, to avoid bash confusion when we printf
  # to __varname
  local __varname="$1" __cmd=("''${@:2}")

  local __captured
  __captured="$("''${__cmd[@]}")"
  check_ "''${__cmd[@]}"

  printf -v "$__varname" %s "$__captured"
}

# --------------------------------------

# Run a cmd, capture its stdout to an array variable.  If the cmd returns
# non-zero, we die with that exit code (citing the cmd that caused it).
#
# The variable created will be an array, the contents being the space-separated
# words from the command output; leading and trailing spaces are dropped.
# Newlines are considered as spaces.  Multiple spaces are conjoined, so e.g.,
# output of "  bar\n\tfoo" will result in the array `( bar foo )`.
#
# A 'space' in this context is a literal space, tab-character or newline.
#
# Any prior contents of the array are nuked.
#
# Arguments:
#  varname ) write captured output to this (as an array)
#  cmd+    ) cmd to run, as a list of words
#
# Examples:
#
#   capture_array harry go 7 echo -e '  foo\n bar\t\tbaz'
#     # equivalent to harry=( foo bar baz )
capture_array() {
  [[ $1 == __varname__ ]] && die 242 "$(loc) don't use '__varname__' here!"
  # if we called this varname, then bash would warn of a circular name
  # reference: which I think would be effectively just a warning (everything
  # would work fine); but still, the use of __varname__ makes it less likely to
  # be noisy
  local -n __varname__="$1"
  local cmd=("''${@:2}")

  local captured
  # readarray swallows the exit code.
  #
  # a possible alternate approach would be to set +m (turn off job control)
  # (being careful to restore the prior setting of -m on return, e.g., with a
  # `trap`); shopt -s lastpipe (again, restoring the original value on return)
  # and then putting the read array at the end of the pipeline.  :shrug: either
  # works, I can't think of a reason to prefer one over the other
  capture captured "''${__cmd__[@]}"

  readarray -t __varname__ < <( echo "$captured"                       \
                                     | gocmdnodryrun   241 tr -s ' \n\t' '\n' \
                                     | gocmd01nodryrun 239 grep -Ev '^ *$'    )
}

# Concatenate strings, separated by a given character
# Args:
#  - ) Name of var to write to.
#  - ) Character to join with: note it must be a character, not a string.
#  * ) The strings to join.
joinsep() { local IFS="$2"; printf -v "$1" %s "''${*:3}"; }

# -- that's all, folks! --------------------------------------------------------
'';}

# Local Variables:
# mode: sh
# sh-basic-offset: 2
# End:
