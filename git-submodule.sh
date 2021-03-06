#!/bin/sh
#
# git-submodules.sh: add, init, update or list git submodules
#
# Copyright (c) 2007 Lars Hjemli

dashless=$(basename "$0" | sed -e 's/-/ /')
USAGE="[--quiet] add [-b branch] [-f|--force] [--reference <repository>] [--] <repository> [<path>]
   or: $dashless [--quiet] status [--cached] [--recursive] [--] [<path>...]
   or: $dashless [--quiet] init [--] [<path>...]
   or: $dashless [--quiet] update [--init] [-N|--no-fetch] [-f|--force] [--rebase] [--reference <repository>] [--merge] [--recursive] [--] [<path>...]
   or: $dashless [--quiet] summary [--cached|--files] [--summary-limit <n>] [commit] [--] [<path>...]
   or: $dashless [--quiet] foreach [--recursive] <command>
   or: $dashless [--quiet] sync [--] [<path>...]"
OPTIONS_SPEC=
. git-sh-setup
. git-sh-i18n
. git-parse-remote
require_work_tree

command=
branch=
force=
reference=
cached=
recursive=
init=
files=
nofetch=
update=
prefix=

# Resolve relative url by appending to parent's url
resolve_relative_url ()
{
	remote=$(get_default_remote)
	remoteurl=$(git config "remote.$remote.url") ||
		die "$(eval_gettext "remote (\$remote) does not have a url defined in .git/config")"
	url="$1"
	remoteurl=${remoteurl%/}
	sep=/
	while test -n "$url"
	do
		case "$url" in
		../*)
			url="${url#../}"
			case "$remoteurl" in
			*/*)
				remoteurl="${remoteurl%/*}"
				;;
			*:*)
				remoteurl="${remoteurl%:*}"
				sep=:
				;;
			*)
				die "$(eval_gettext "cannot strip one component off url '\$remoteurl'")"
				;;
			esac
			;;
		./*)
			url="${url#./}"
			;;
		*)
			break;;
		esac
	done
	echo "$remoteurl$sep${url%/}"
}

#
# Get submodule info for registered submodules
# $@ = path to limit submodule list
#
module_list()
{
	git ls-files --error-unmatch --stage -- "$@" |
	perl -e '
	my %unmerged = ();
	my ($null_sha1) = ("0" x 40);
	while (<STDIN>) {
		chomp;
		my ($mode, $sha1, $stage, $modulepath) =
			/^([0-7]+) ([0-9a-f]{40}) ([0-3])\t(.*)$/;
		next unless $mode eq "160000";
		if ($stage ne "0") {
			if (!$unmerged{$modulepath}++) {
				print "$mode $null_sha1 U\t$modulepath\n";
			}
			next;
		}
		print "$_\n";
	}
	'
}

#
# Map submodule path to submodule name
#
# $1 = path
#
module_name()
{
	# Do we have "submodule.<something>.path = $1" defined in .gitmodules file?
	re=$(printf '%s\n' "$1" | sed -e 's/[].[^$\\*]/\\&/g')
	name=$( git config -f .gitmodules --get-regexp '^submodule\..*\.path$' |
		sed -n -e 's|^submodule\.\(.*\)\.path '"$re"'$|\1|p' )
       test -z "$name" &&
       die "$(eval_gettext "No submodule mapping found in .gitmodules for path '\$modulepath'")"
       echo "$name"
}

#
# Clone a submodule
#
# Prior to calling, cmd_update checks that a possibly existing
# path is not a git repository.
# Likewise, cmd_add checks that path does not exist at all,
# since it is the location of a new submodule.
#
module_clone()
{
	modulepath=$1
	url=$2
	reference="$3"

	if test -n "$reference"
	then
		git-clone "$reference" -n "$url" "$modulepath"
	else
		git-clone -n "$url" "$modulepath"
	fi ||
	die "$(eval_gettext "Clone of '\$url' into submodule path '\$modulepath' failed")"
}

#
# Add a new submodule to the working tree, .gitmodules and the index
#
# $@ = repo path
#
# optional branch is stored in global branch variable
#
cmd_add()
{
	# parse $args after "submodule ... add".
	while test $# -ne 0
	do
		case "$1" in
		-b | --branch)
			case "$2" in '') usage ;; esac
			branch=$2
			shift
			;;
		-f | --force)
			force=$1
			;;
		-q|--quiet)
			GIT_QUIET=1
			;;
		--reference)
			case "$2" in '') usage ;; esac
			reference="--reference=$2"
			shift
			;;
		--reference=*)
			reference="$1"
			shift
			;;
		--)
			shift
			break
			;;
		-*)
			usage
			;;
		*)
			break
			;;
		esac
		shift
	done

	repo=$1
	modulepath=$2

	if test -z "$modulepath"; then
		modulepath=$(echo "$repo" |
			sed -e 's|/$||' -e 's|:*/*\.git$||' -e 's|.*[/:]||g')
	fi

	if test -z "$repo" -o -z "$modulepath"; then
		usage
	fi

	# assure repo is absolute or relative to parent
	case "$repo" in
	./*|../*)
		# dereference source url relative to parent's url
		realrepo=$(resolve_relative_url "$repo") || exit
		;;
	*:*|/*)
		# absolute url
		realrepo=$repo
		;;
	*)
		die "$(eval_gettext "repo URL: '\$repo' must be absolute or begin with ./|../")"
	;;
	esac

	# normalize path:
	# multiple //; leading ./; /./; /../; trailing /
	modulepath=$(printf '%s/\n' "$modulepath" |
		sed -e '
			s|//*|/|g
			s|^\(\./\)*||
			s|/\./|/|g
			:start
			s|\([^/]*\)/\.\./||
			tstart
			s|/*$||
		')
	git ls-files --error-unmatch "$modulepath" > /dev/null 2>&1 &&
	die "$(eval_gettext "'\$modulepath' already exists in the index")"

	if test -z "$force" && ! git add --dry-run --ignore-missing "$modulepath" > /dev/null 2>&1
	then
		cat >&2 <<EOF
The following path is ignored by one of your .gitignore files:
$(gettext $modulepath)
Use -f if you really want to add it.
EOF
		exit 1
	fi

	# perhaps the path exists and is already a git repo, else clone it
	if test -e "$modulepath"
	then
		if test -d "$modulepath"/.git -o -f "$modulepath"/.git
		then
			eval_gettext "Adding existing repo at '\$modulepath' to the index"; echo
		else
			die "$(eval_gettext "'\$modulepath' already exists and is not a valid git repo")"
		fi

		case "$repo" in
		./*|../*)
			url=$(resolve_relative_url "$repo") || exit
		    ;;
		*)
			url="$repo"
			;;
		esac
		git config submodule."$modulepath".url "$url"
	else

		module_clone "$modulepath" "$realrepo" "$reference" || exit
		(
			clear_local_git_env
			cd "$modulepath" &&
			# ash fails to wordsplit ${branch:+-b "$branch"...}
			case "$branch" in
			'') git checkout -f -q ;;
			?*) git checkout -f -q -B "$branch" "origin/$branch" ;;
			esac
		) || die "$(eval_gettext "Unable to checkout submodule '\$modulepath'")"
	fi

	git add $force "$modulepath" ||
	die "$(eval_gettext "Failed to add submodule '\$modulepath'")"

	git config -f .gitmodules submodule."$modulepath".path "$modulepath" &&
	git config -f .gitmodules submodule."$modulepath".url "$repo" &&
	git add --force .gitmodules ||
	die "$(eval_gettext "Failed to register submodule '\$modulepath'")"
}

#
# Execute an arbitrary command sequence in each checked out
# submodule
#
# $@ = command to execute
#
cmd_foreach()
{
	# parse $args after "submodule ... foreach".
	while test $# -ne 0
	do
		case "$1" in
		-q|--quiet)
			GIT_QUIET=1
			;;
		--recursive)
			recursive=1
			;;
		-*)
			usage
			;;
		*)
			break
			;;
		esac
		shift
	done

	toplevel=$(pwd)

	module_list |
	while read mode sha1 stage modulepath
	do
		if test -e "$modulepath"/.git
		then
			say "$(eval_gettext "Entering '\$prefix\$modulepath'")"
			name=$(module_name "$modulepath")
			(
				prefix="$prefix$modulepath/"
				clear_local_git_env
				cd "$modulepath" &&
				eval "$@" &&
				if test -n "$recursive"
				then
					cmd_foreach "--recursive" "$@"
				fi
			) ||
			die "$(eval_gettext "Stopping at '\$modulepath'; script returned non-zero status.")"
		fi
	done
}

#
# Register submodules in .git/config
#
# $@ = requested paths (default to all)
#
cmd_init()
{
	# parse $args after "submodule ... init".
	while test $# -ne 0
	do
		case "$1" in
		-q|--quiet)
			GIT_QUIET=1
			;;
		--)
			shift
			break
			;;
		-*)
			usage
			;;
		*)
			break
			;;
		esac
		shift
	done

	module_list "$@" |
	while read mode sha1 stage modulepath
	do
		# Skip already registered paths
		name=$(module_name "$modulepath") || exit
		url=$(git config submodule."$name".url)
		test -z "$url" || continue

		url=$(git config -f .gitmodules submodule."$name".url)
		test -z "$url" &&
		die "$(eval_gettext "No url found for submodule path '\$modulepath' in .gitmodules")"

		# Possibly a url relative to parent
		case "$url" in
		./*|../*)
			url=$(resolve_relative_url "$url") || exit
			;;
		esac

		git config submodule."$name".url "$url" ||
		die "$(eval_gettext "Failed to register url for submodule path '\$modulepath'")"

		upd="$(git config -f .gitmodules submodule."$name".update)"
		test -z "$upd" ||
		git config submodule."$name".update "$upd" ||
		die "$(eval_gettext "Failed to register update mode for submodule path '\$modulepath'")"

		say "$(eval_gettext "Submodule '\$name' (\$url) registered for path '\$modulepath'")"
	done
}

#
# Update each submodule path to correct revision, using clone and checkout as needed
#
# $@ = requested paths (default to all)
#
cmd_update()
{
	# parse $args after "submodule ... update".
	orig_flags=
	while test $# -ne 0
	do
		case "$1" in
		-q|--quiet)
			GIT_QUIET=1
			;;
		-i|--init)
			init=1
			;;
		-N|--no-fetch)
			nofetch=1
			;;
		-f|--force)
			force=$1
			;;
		-r|--rebase)
			update="rebase"
			;;
		--reference)
			case "$2" in '') usage ;; esac
			reference="--reference=$2"
			orig_flags="$orig_flags $(git rev-parse --sq-quote "$1")"
			shift
			;;
		--reference=*)
			reference="$1"
			;;
		-m|--merge)
			update="merge"
			;;
		--recursive)
			recursive=1
			;;
		--)
			shift
			break
			;;
		-*)
			usage
			;;
		*)
			break
			;;
		esac
		orig_flags="$orig_flags $(git rev-parse --sq-quote "$1")"
		shift
	done

	if test -n "$init"
	then
		cmd_init "--" "$@" || return
	fi

	cloned_modules=
	module_list "$@" |
	while read mode sha1 stage modulepath
	do
		if test "$stage" = U
		then
			echo >&2 "Skipping unmerged submodule $modulepath"
			continue
		fi
		name=$(module_name "$modulepath") || exit
		url=$(git config submodule."$name".url)
		update_module=$(git config submodule."$name".update)
		if test -z "$url"
		then
			# Only mention uninitialized submodules when its
			# path have been specified
			test "$#" != "0" &&
			say "$(eval_gettext "Submodule path '\$modulepath' not initialized
Maybe you want to use 'update --init'?")"
			continue
		fi

		if ! test -d "$modulepath"/.git -o -f "$modulepath"/.git
		then
			module_clone "$modulepath" "$url" "$reference"|| exit
			cloned_modules="$cloned_modules;$name"
			subsha1=
		else
			subsha1=$(clear_local_git_env; cd "$modulepath" &&
				git rev-parse --verify HEAD) ||
			die "$(eval_gettext "Unable to find current revision in submodule path '\$modulepath'")"
		fi

		if ! test -z "$update"
		then
			update_module=$update
		fi

		if test "$subsha1" != "$sha1"
		then
			subforce=$force
			# If we don't already have a -f flag and the submodule has never been checked out
			if test -z "$subsha1" -a -z "$force"
			then
				subforce="-f"
			fi

			if test -z "$nofetch"
			then
				# Run fetch only if $sha1 isn't present or it
				# is not reachable from a ref.
				(clear_local_git_env; cd "$modulepath" &&
					( (rev=$(git rev-list -n 1 $sha1 --not --all 2>/dev/null) &&
					 test -z "$rev") || git-fetch)) ||
				die "$(eval_gettext "Unable to fetch in submodule path '\$modulepath'")"
			fi

			# Is this something we just cloned?
			case ";$cloned_modules;" in
			*";$name;"*)
				# then there is no local change to integrate
				update_module= ;;
			esac

			case "$update_module" in
			rebase)
				command="git rebase"
				die_msg="$(eval_gettext "Unable to rebase '\$sha1' in submodule path '\$modulepath'")"
				say_msg="$(eval_gettext "Submodule path '\$modulepath': rebased into '\$sha1'")"
				;;
			merge)
				command="git merge"
				die_msg="$(eval_gettext "Unable to merge '\$sha1' in submodule path '\$modulepath'")"
				say_msg="$(eval_gettext "Submodule path '\$modulepath': merged in '\$sha1'")"
				;;
			*)
				command="git checkout $subforce -q"
				die_msg="$(eval_gettext "Unable to checkout '\$sha1' in submodule path '\$modulepath'")"
				say_msg="$(eval_gettext "Submodule path '\$modulepath': checked out '\$sha1'")"
				;;
			esac

			(clear_local_git_env; cd "$modulepath" && $command "$sha1") || die $die_msg
			say $say_msg
		fi

		if test -n "$recursive"
		then
			(clear_local_git_env; cd "$modulepath" && eval cmd_update "$orig_flags") ||
			die "$(eval_gettext "Failed to recurse into submodule path '\$modulepath'")"
		fi
	done
}

set_name_rev () {
	revname=$( (
		clear_local_git_env
		cd "$1" && {
			git describe "$2" 2>/dev/null ||
			git describe --tags "$2" 2>/dev/null ||
			git describe --contains "$2" 2>/dev/null ||
			git describe --all --always "$2"
		}
	) )
	test -z "$revname" || revname=" ($revname)"
}
#
# Show commit summary for submodules in index or working tree
#
# If '--cached' is given, show summary between index and given commit,
# or between working tree and given commit
#
# $@ = [commit (default 'HEAD'),] requested paths (default all)
#
cmd_summary() {
	summary_limit=-1
	for_status=
	diff_cmd=diff-index

	# parse $args after "submodule ... summary".
	while test $# -ne 0
	do
		case "$1" in
		--cached)
			cached="$1"
			;;
		--files)
			files="$1"
			;;
		--for-status)
			for_status="$1"
			;;
		-n|--summary-limit)
			if summary_limit=$(($2 + 0)) 2>/dev/null && test "$summary_limit" = "$2"
			then
				:
			else
				usage
			fi
			shift
			;;
		--)
			shift
			break
			;;
		-*)
			usage
			;;
		*)
			break
			;;
		esac
		shift
	done

	test $summary_limit = 0 && return

	if rev=$(git rev-parse -q --verify --default HEAD ${1+"$1"})
	then
		head=$rev
		test $# = 0 || shift
	elif test -z "$1" -o "$1" = "HEAD"
	then
		# before the first commit: compare with an empty tree
		head=$(git hash-object -w -t tree --stdin </dev/null)
		test -z "$1" || shift
	else
		head="HEAD"
	fi

	if [ -n "$files" ]
	then
		test -n "$cached" &&
		die "$(gettext -- "--cached cannot be used with --files")"
		diff_cmd=diff-files
		head=
	fi

	cd_to_toplevel
	# Get modified modules cared by user
	modules=$(git $diff_cmd $cached --ignore-submodules=dirty --raw $head -- "$@" |
		sane_egrep '^:([0-7]* )?160000' |
		while read mod_src mod_dst sha1_src sha1_dst status name
		do
			# Always show modules deleted or type-changed (blob<->module)
			test $status = D -o $status = T && echo "$name" && continue
			# Also show added or modified modules which are checked out
			GIT_DIR="$name/.git" git-rev-parse --git-dir >/dev/null 2>&1 &&
			echo "$name"
		done
	)

	test -z "$modules" && return

	git $diff_cmd $cached --ignore-submodules=dirty --raw $head -- $modules |
	sane_egrep '^:([0-7]* )?160000' |
	cut -c2- |
	while read mod_src mod_dst sha1_src sha1_dst status name
	do
		if test -z "$cached" &&
			test $sha1_dst = 0000000000000000000000000000000000000000
		then
			case "$mod_dst" in
			160000)
				sha1_dst=$(GIT_DIR="$name/.git" git rev-parse HEAD)
				;;
			100644 | 100755 | 120000)
				sha1_dst=$(git hash-object $name)
				;;
			000000)
				;; # removed
			*)
				# unexpected type
				(
					eval_gettext "unexpected mode \$mod_dst" &&
					echo
				) >&2
				continue ;;
			esac
		fi
		missing_src=
		missing_dst=

		test $mod_src = 160000 &&
		! GIT_DIR="$name/.git" git-rev-parse -q --verify $sha1_src^0 >/dev/null &&
		missing_src=t

		test $mod_dst = 160000 &&
		! GIT_DIR="$name/.git" git-rev-parse -q --verify $sha1_dst^0 >/dev/null &&
		missing_dst=t

		total_commits=
		case "$missing_src,$missing_dst" in
		t,)
			errmsg="$(eval_gettext "  Warn: \$name doesn't contain commit \$sha1_src")"
			;;
		,t)
			errmsg="$(eval_gettext "  Warn: \$name doesn't contain commit \$sha1_dst")"
			;;
		t,t)
			errmsg="$(eval_gettext "  Warn: \$name doesn't contain commits \$sha1_src and \$sha1_dst")"
			;;
		*)
			errmsg=
			total_commits=$(
			if test $mod_src = 160000 -a $mod_dst = 160000
			then
				range="$sha1_src...$sha1_dst"
			elif test $mod_src = 160000
			then
				range=$sha1_src
			else
				range=$sha1_dst
			fi
			GIT_DIR="$name/.git" \
			git rev-list --first-parent $range -- | wc -l
			)
			total_commits=" ($(($total_commits + 0)))"
			;;
		esac

		sha1_abbr_src=$(echo $sha1_src | cut -c1-7)
		sha1_abbr_dst=$(echo $sha1_dst | cut -c1-7)
		if test $status = T
		then
			blob="$(gettext "blob")"
			submodule="$(gettext "submodule")"
			if test $mod_dst = 160000
			then
				echo "* $name $sha1_abbr_src($blob)->$sha1_abbr_dst($submodule)$total_commits:"
			else
				echo "* $name $sha1_abbr_src($submodule)->$sha1_abbr_dst($blob)$total_commits:"
			fi
		else
			echo "* $name $sha1_abbr_src...$sha1_abbr_dst$total_commits:"
		fi
		if test -n "$errmsg"
		then
			# Don't give error msg for modification whose dst is not submodule
			# i.e. deleted or changed to blob
			test $mod_dst = 160000 && echo "$errmsg"
		else
			if test $mod_src = 160000 -a $mod_dst = 160000
			then
				limit=
				test $summary_limit -gt 0 && limit="-$summary_limit"
				GIT_DIR="$name/.git" \
				git log $limit --pretty='format:  %m %s' \
				--first-parent $sha1_src...$sha1_dst
			elif test $mod_dst = 160000
			then
				GIT_DIR="$name/.git" \
				git log --pretty='format:  > %s' -1 $sha1_dst
			else
				GIT_DIR="$name/.git" \
				git log --pretty='format:  < %s' -1 $sha1_src
			fi
			echo
		fi
		echo
	done |
	if test -n "$for_status"; then
		if [ -n "$files" ]; then
			status_msg="$(gettext "# Submodules changed but not updated:")"
		else
			status_msg="$(gettext "# Submodule changes to be committed:")"
		fi
		status_sed=$(sed -e 's|^|# |' -e 's|^# $|#|')
		cat <<EOF
$status_msg
#
$status_sed
EOF
	else
		cat
	fi
}
#
# List all submodules, prefixed with:
#  - submodule not initialized
#  + different revision checked out
#
# If --cached was specified the revision in the index will be printed
# instead of the currently checked out revision.
#
# $@ = requested paths (default to all)
#
cmd_status()
{
	# parse $args after "submodule ... status".
	orig_flags=
	while test $# -ne 0
	do
		case "$1" in
		-q|--quiet)
			GIT_QUIET=1
			;;
		--cached)
			cached=1
			;;
		--recursive)
			recursive=1
			;;
		--)
			shift
			break
			;;
		-*)
			usage
			;;
		*)
			break
			;;
		esac
		orig_flags="$orig_flags $(git rev-parse --sq-quote "$1")"
		shift
	done

	module_list "$@" |
	while read mode sha1 stage modulepath
	do
		name=$(module_name "$modulepath") || exit
		url=$(git config submodule."$name".url)
		displaypath="$prefix$modulepath"
		if test "$stage" = U
		then
			say "U$sha1 $displaypath"
			continue
		fi
		if test -z "$url" || ! test -d "$modulepath"/.git -o -f "$modulepath"/.git
		then
			say "-$sha1 $displaypath"
			continue;
		fi
		set_name_rev "$modulepath" "$sha1"
		if git diff-files --ignore-submodules=dirty --quiet -- "$modulepath"
		then
			say " $sha1 $displaypath$revname"
		else
			if test -z "$cached"
			then
				sha1=$(clear_local_git_env; cd "$modulepath" && git rev-parse --verify HEAD)
				set_name_rev "$modulepath" "$sha1"
			fi
			say "+$sha1 $displaypath$revname"
		fi

		if test -n "$recursive"
		then
			(
				prefix="$displaypath/"
				clear_local_git_env
				cd "$modulepath" &&
				eval cmd_status "$orig_args"
			) ||
			die "$(eval_gettext "Failed to recurse into submodule path '\$modulepath'")"
		fi
	done
}
#
# Sync remote urls for submodules
# This makes the value for remote.$remote.url match the value
# specified in .gitmodules.
#
cmd_sync()
{
	while test $# -ne 0
	do
		case "$1" in
		-q|--quiet)
			GIT_QUIET=1
			shift
			;;
		--)
			shift
			break
			;;
		-*)
			usage
			;;
		*)
			break
			;;
		esac
	done
	cd_to_toplevel
	module_list "$@" |
	while read mode sha1 stage modulepath
	do
		name=$(module_name "$modulepath")
		url=$(git config -f .gitmodules --get submodule."$name".url)

		# Possibly a url relative to parent
		case "$url" in
		./*|../*)
			url=$(resolve_relative_url "$url") || exit
			;;
		esac

		say "$(eval_gettext "Synchronizing submodule url for '\$name'")"
		git config submodule."$name".url "$url"

		if test -e "$modulepath"/.git
		then
		(
			clear_local_git_env
			cd "$modulepath"
			remote=$(get_default_remote)
			git config remote."$remote".url "$url"
		)
		fi
	done
}

# This loop parses the command line arguments to find the
# subcommand name to dispatch.  Parsing of the subcommand specific
# options are primarily done by the subcommand implementations.
# Subcommand specific options such as --branch and --cached are
# parsed here as well, for backward compatibility.

while test $# != 0 && test -z "$command"
do
	case "$1" in
	add | foreach | init | update | status | summary | sync)
		command=$1
		;;
	-q|--quiet)
		GIT_QUIET=1
		;;
	-b|--branch)
		case "$2" in
		'')
			usage
			;;
		esac
		branch="$2"; shift
		;;
	--cached)
		cached="$1"
		;;
	--)
		break
		;;
	-*)
		usage
		;;
	*)
		break
		;;
	esac
	shift
done

# No command word defaults to "status"
test -n "$command" || command=status

# "-b branch" is accepted only by "add"
if test -n "$branch" && test "$command" != add
then
	usage
fi

# "--cached" is accepted only by "status" and "summary"
if test -n "$cached" && test "$command" != status -a "$command" != summary
then
	usage
fi

"cmd_$command" "$@"
