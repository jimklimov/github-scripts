#!/bin/bash
# A simple script to backup an organization's GitHub repositories.
# Initially from https://gist.github.com/rodw/3073987 snapshot at
# https://gist.githubusercontent.com/rodw/3073987/raw/d5e9ab4785647e558df488eb18623aa6c52af86b/backup-github.sh
# Continued afterwards 2023+ by Jim Klimov <gmail.com>

#-------------------------------------------------------------------------------
# NOTES:
#-------------------------------------------------------------------------------
# * Under the heading "CONFIG" below you'll find a number of configuration
#   parameters that must be personalized for your GitHub account and org.
#   Replace the `<CHANGE-ME>` strings with the value described in the comments
#   (or overwrite those values at run-time by providing environment variables).
#
# * If you have more than 100 repositories, the script should be able to
#   step thru the list of repos returned by GitHub one page at a time,
#   beware API limits (server-side throttling); maybe support for HTTP-304
#   cache would be beneficial (also to avoid fetches that bring no news?)
#
# * If you want to back up the repos for a USER rather than an ORGANIZATION,
#   or a user's gists (and their comments), see GHBU_ORGMODE setting below.
#
# * Thanks to @rodw for the original script, and to @Calrion, @vnaum,
#   @BartHaagdorens and other commenters in original gist for various fixes
#   and updates.
#
# * Also see those comments (and related revisions and forks) for more
#   information and general troubleshooting.
#-------------------------------------------------------------------------------

#-------------------------------------------------------------------------------
# CONFIG:
#-------------------------------------------------------------------------------
GHBU_ORG=${GHBU_ORG-"<CHANGE-ME>"}                                   # the GitHub organization whose repos will be backed up
#                                                                    # (if you're backing up a USER's repos, this should be your GitHub username; also see the note below about the `REPOLIST` definition)
GHBU_UNAME=${GHBU_UNAME-"<CHANGE-ME>"}                               # the username of a GitHub account (to use with the GitHub API)
GHBU_PASSWD=${GHBU_PASSWD-"<CHANGE-ME>"}                             # the password for that account
#-------------------------------------------------------------------------------
GHBU_ORGMODE=${GHBU_ORGMODE-"org"}                                   # "org", "user" or "gists"?
GHBU_BACKUP_DIR=${GHBU_BACKUP_DIR-"github-backups"}                  # where to place the backup files; avoid using ":" in the name (confuses tar as a hostname; confuses Windows as a drive letter)
GHBU_GITHOST=${GHBU_GITHOST-"github.com"}                            # the GitHub hostname (see comments)
GHBU_REUSE_REPOS=${GHBU_REUSE_REPOS-false}                           # as part of backup process, we mirror-clone remote git repos; should we keep and reuse them for next backups (true), or always snatch from scratch (false)?
GHBU_PRUNE_INCOMPLETE=${GHBU_PRUNE_INCOMPLETE-false}                 # when `true`, backups named like *.__WRITING__ will be deleted when script starts (set `false` if using same GHBU_BACKUP_DIR for several scripts running in parallel)
GHBU_PRUNE_OLD=${GHBU_PRUNE_OLD-true}                                # when `true`, old backups will be deleted
GHBU_PRUNE_AFTER_N_DAYS=${GHBU_PRUNE_AFTER_N_DAYS-3}                 # the min age (in days) of backup files to delete
GHBU_SILENT=${GHBU_SILENT-false}                                     # when `true`, only show error messages
GHBU_API=${GHBU_API-"https://api.github.com"}                        # base URI for the GitHub API
GHBU_GIT_CLONE_CMD="git clone --quiet --mirror "                     # base command to use to clone GitHub repos from an URL (may need more info for SSH)
GHBU_GIT_CLONE_CMD_SSH="${GHBU_GIT_CLONE_CMD} git@${GHBU_GITHOST}:"  # base command to use to clone GitHub repos over SSH
GHBU_GIT_UPDATE_CMD="git fetch --quiet --all && git fetch --quiet --tags"       # base command to update an existing repo (if reusing)
TSTAMP="`TZ=UTC date "+%Y%m%dT%H%MZ"`"                               # format of timestamp suffix appended to archived files
#-------------------------------------------------------------------------------
# (end config)
#-------------------------------------------------------------------------------

# The function `check` will exit the script if the given command fails.
function check {
    "$@"
    status=$?
    if [ $status -ne 0 ]; then
        echo "ERROR: Encountered error (${status}) while running the following:" >&2
        echo "           $@"  >&2
        echo "       (at line ${BASH_LINENO[0]} of file $0.)"  >&2
        echo "       Aborting." >&2
        exit $status
    fi
}

# The function `tgz` will create a gzipped tar archive of the specified
# file ($1) and then optionally remove the original
function tgz {
    check tar zcf "$1.$TSTAMP.tar.gz.__WRITING__" "$1" \
    && check mv -f "$1.$TSTAMP.tar.gz.__WRITING__" "$1.$TSTAMP.tar.gz" \
    || return

    if ! $GHBU_REUSE_REPOS ; then
        check rm -rf "$1"
    fi
}

# The function `getdir` will return the repo directory name on stdout
# if successful (it depends on GHBU_REUSE_REPOS value).
function getdir {
    local REPOURI="$1"
    local DIRNAME

    REPOURI="$(echo "$REPOURI" | sed 's,^https://gist.github.com/\(.*\)$,gist-\1,')"
    REPOURI="$(echo "$REPOURI" | sed 's,^'"$GHBU_API"'/gists/\([^/]*\)/comments$,gist-\1-comments,')"

    if $GHBU_REUSE_REPOS ; then
        DIRNAME="${GHBU_BACKUP_DIR}/${GHBU_ORG}-${REPOURI}"
    fi
    if ! $GHBU_REUSE_REPOS ; then
        DIRNAME="${DIRNAME}-${TSTAMP}"
    fi
    case "$REPOURI" in
        *.git) ;;
        *) DIRNAME="${DIRNAME}.git" ;;
    esac
    echo "$DIRNAME"
}

# The function `getgit` will clone (or update) specified repo ($1, without
# a `.git` suffix) into specified directory ($2)
function getgit {
    local REPOURI="$1"
    local DIRNAME="$2"

    if $GHBU_REUSE_REPOS && [ -d "${DIRNAME}" ] ; then
        $GHBU_SILENT || echo "... Updating $REPOURI clone in $DIRNAME"
        (cd "${DIRNAME}" && eval $GHBU_GIT_UPDATE_CMD) || return
    else
        $GHBU_SILENT || echo "... Cloning $REPOURI into $DIRNAME"
        case x"$1" in
            x*@*|x*://*) # URL already; .git suffix should be irrelevant
                ${GHBU_GIT_CLONE_CMD} "${REPOURI}" "${DIRNAME}" || return
                ;;
            *) # Just a repo name
                ${GHBU_GIT_CLONE_CMD_SSH}"${GHBU_ORG}/${REPOURI}.git" "${DIRNAME}" || return
                ;;
        esac
    fi

    # Return a success either way here:
    $GHBU_SILENT || echo "+++ Received $REPOURI into $DIRNAME"
}

function filter_user_org {
    check grep  "^    \"name\"" | check awk -F': "' '{print $2}' | check sed -e 's/",//g'
}

function filter_gist {
    check sed -n 's/.*git_pull_url": "\(.*\)",/\1/p'
}

function filter_gist_comments {
    check sed -n 's/.*comments_url": "\(.*\)",/\1/p'
}

$GHBU_SILENT || (echo "" && echo "=== INITIALIZING ===" && echo "")

$GHBU_SILENT || echo "Using backup directory $GHBU_BACKUP_DIR"
check mkdir -p $GHBU_BACKUP_DIR

if $GHBU_PRUNE_INCOMPLETE ; then
    $GHBU_SILENT || (echo "" && echo "=== PRUNING INCOMPLETE LEFTOVERS (if any) ===" && echo "")
    $GHBU_SILENT || echo "Found `find $GHBU_BACKUP_DIR -maxdepth 1 -name '*.__WRITING__' | wc -l` files to prune."
    find $GHBU_BACKUP_DIR -maxdepth 1 -name '*.__WRITING__' -exec rm -fv {} > /dev/null \;
fi

$GHBU_SILENT || echo -n "Fetching list of repositories for ${GHBU_ORG}..."

case x"$GHBU_ORGMODE" in
    x"gist"|x"gists")
        GHBU_ORG_URI="/gists"
        ;;
    x"user"|x"users")
        # NOTE: if you're backing up a *user's* repos, not an organizations, use this instead:
        GHBU_ORG_URI="/user"
        ;;
    x"org"|*)   # Legacy default
        GHBU_ORG_URI="/orgs/${GHBU_ORG}"
        ;;
esac

GIST_COMMENTLIST=""
GIST_COMMENTLIST_PAGE=""
REPOLIST=""
REPOLIST_PAGE=""
PAGENUM=1
while : ; do
    JSON=""
    case x"$GHBU_ORGMODE" in
        xorg*|xuser*)
            # hat tip to https://gist.github.com/rodw/3073987#gistcomment-3217943 for the license name workaround
            JSON="$(check curl --silent -u "${GHBU_UNAME}:${GHBU_PASSWD}" "${GHBU_API}${GHBU_ORG_URI}/repos?per_page=100&page=$PAGENUM" -q)"
            REPOLIST_PAGE="$(echo "$JSON" | filter_user_org)"
            ;;
        xgist*)
            JSON="$(check curl --silent -u "${GHBU_UNAME}:${GHBU_PASSWD}" "${GHBU_API}${GHBU_ORG_URI}?per_page=100&page=$PAGENUM" -q)"
            REPOLIST_PAGE="$(echo "$JSON" | filter_gist)"
            GIST_COMMENTLIST_PAGE="$(echo "$JSON" | filter_gist_comments)"
            ;;
    esac

    echo "$JSON" >> "${GHBU_BACKUP_DIR}/${GHBU_ORG}-metadata-${TSTAMP}.json"

    if [ -z "$REPOLIST" ] ; then
        REPOLIST="$REPOLIST_PAGE"
    else
        REPOLIST="$REPOLIST
$REPOLIST_PAGE"
    fi
    if [ -z "$GIST_COMMENTLIST" ] ; then
        GIST_COMMENTLIST="$GIST_COMMENTLIST_PAGE"
    else
        GIST_COMMENTLIST="$GIST_COMMENTLIST
$GIST_COMMENTLIST_PAGE"
    fi
    if [ 100 -ne `echo $REPOLIST_PAGE | wc -w` ] ; then
        break
    fi
    PAGENUM=$(($PAGENUM+1))
    $GHBU_SILENT || echo -n " Fetching next page of repos: $PAGENUM..."
done

$GHBU_SILENT || echo " found `echo $REPOLIST | wc -w` repositories."
GHBU_REUSE_REPOS=false tgz "${GHBU_BACKUP_DIR}/${GHBU_ORG}-metadata-${TSTAMP}.json"

$GHBU_SILENT || (echo "" && echo "=== BACKING UP ===" && echo "")

for REPO in $REPOLIST; do
    $GHBU_SILENT || echo "Backing up ${GHBU_ORG}/${REPO}"
    DIRNAME="`getdir "$REPO"`"
    check getgit "${REPO}" "${DIRNAME}" && tgz "${DIRNAME}"

    # No wikis nor issues for gists; but there are comments (see another loop)
    case x"$GHBU_ORGMODE" in
        xorg*|xuser*)
            $GHBU_SILENT || echo "Backing up ${GHBU_ORG}/${REPO}.wiki (if any)"
            DIRNAME="`getdir "$REPO.wiki"`"
            # Failure is an option
            getgit "${REPO}.wiki" "${DIRNAME}" 2>/dev/null && tgz "${DIRNAME}"

            $GHBU_SILENT || echo "Backing up ${GHBU_ORG}/${REPO} issues"
            DIRNAME="`getdir "$REPO.issues" | sed 's,.git$,,'`"
            check curl --silent -u "${GHBU_UNAME}:${GHBU_PASSWD}" \
                "${GHBU_API}/repos/${GHBU_ORG}/${REPO}/issues" -q \
            > "${DIRNAME}" && GHBU_REUSE_REPOS=false tgz "${DIRNAME}"
            ;;
    esac
done

# Assumes GHBU_ORGMODE=gist, but no reason to constrain:
for COMMENT_URL in $GIST_COMMENTLIST; do
    $GHBU_SILENT || echo "Backing up ${GHBU_ORG}/${REPO} comments"
    DIRNAME="`getdir "${COMMENT_URL}.comments" | sed 's,.git$,,'`"
    check curl --silent -u "${GHBU_UNAME}:${GHBU_PASSWD}" \
        "${COMMENT_URL}" -q \
    > "${DIRNAME}" && GHBU_REUSE_REPOS=false tgz "${DIRNAME}"
done

# FIXME: Leave at least one backup for each timestamped item sequence!
# GitHub going AWOL and us deleting all backups after 3 days would be folly!
# (Less of a problem if we do keep the repos, but comments/issues/medatata
# are still at risk - maybe GIT their evolution locally?)
if $GHBU_PRUNE_OLD && [ "${GHBU_PRUNE_AFTER_N_DAYS}" -gt 0 ]; then
    $GHBU_SILENT || (echo "" && echo "=== PRUNING ===" && echo "")
    $GHBU_SILENT || echo "Pruning backup files ${GHBU_PRUNE_AFTER_N_DAYS} days old or older."
    $GHBU_SILENT || echo "Found `find $GHBU_BACKUP_DIR -maxdepth 1 -name '*.tar.gz' -mtime +${GHBU_PRUNE_AFTER_N_DAYS} | wc -l` files to prune."
    find $GHBU_BACKUP_DIR -maxdepth 1 -name '*.tar.gz' -mtime "+${GHBU_PRUNE_AFTER_N_DAYS}" -exec rm -fv {} > /dev/null \;
fi

$GHBU_SILENT || (echo "" && echo "=== DONE ===" && echo "")
$GHBU_SILENT || (echo "GitHub backup completed." && echo "")
