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
# * Your terminal/screen session used for backups would benefit from having
#   your SSH key preloaded into the ssh-agent, e.g.:
#      eval `ssh-agent`
#      ssh-add ~/.ssh/id_rsa
#   or otherwise made available to the git client (no passphrase? oh no!)
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
GHBU_TARBALL_REPOS=${GHBU_TARBALL_REPOS-true}                        # when `true`, tarballs for each backed-up repository would be made; when false (e.g. if persistent repos due to GHBU_REUSE_REPOS=true suffice), only non-git items would be tarballed (issues, comments, metadata)
GHBU_PRUNE_INCOMPLETE=${GHBU_PRUNE_INCOMPLETE-false}                 # when `true`, backups named like *.__WRITING__ will be deleted when script starts (set `false` if using same GHBU_BACKUP_DIR for several scripts running in parallel)
GHBU_PRUNE_PREV=${GHBU_PRUNE_PREV-false}                             # when `true`, only the "*.latest.tar.gz" backups will be tracked; when `false` also the `*.prev.tar.gz"
GHBU_PRUNE_OLD=${GHBU_PRUNE_OLD-true}                                # when `true`, old backups will be deleted
GHBU_PRUNE_AFTER_N_DAYS=${GHBU_PRUNE_AFTER_N_DAYS-3}                 # the min age (in days) of backup files to delete
GHBU_SILENT=${GHBU_SILENT-false}                                     # when `true`, only show error messages
GHBU_API=${GHBU_API-"https://api.github.com"}                        # base URI for the GitHub API
GHBU_GIT_CLONE_CMD="GITCMD clone --quiet --mirror "                  # base command to use to clone GitHub repos from an URL (may need more info for SSH)
GHBU_GIT_CLONE_CMD_SSH="${GHBU_GIT_CLONE_CMD} git@${GHBU_GITHOST}:"  # base command to use to clone GitHub repos over SSH
GHBU_FAILFAST_GETGIT="${GHBU_FAILFAST_GETGIT-true}"                  # if true, repeated failure of getgit() will fail the script; if false - go over other repos
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
    $GHBU_TARBALL_REPOS || return 0

    check tar zcf "$1.$TSTAMP.tar.gz.__WRITING__" "$1" \
    && check mv -f "$1.$TSTAMP.tar.gz.__WRITING__" "$1.$TSTAMP.tar.gz" \
    || return

    if ! $GHBU_REUSE_REPOS ; then
        check rm -rf "$1"
    fi

    # Let one copy (or two if "prev" is used) survive the auto-prune
    if $GHBU_PRUNE_PREV ; then
        rm -f "$1.prev.tar.gz" || true
        rm -f "$1.latest.tar.gz" || true
    else
        if [ -e "$1.latest.tar.gz" ] ; then
            mv -f "$1.latest.tar.gz" "$1.prev.tar.gz" || true
        fi
    fi
    check ln "$1.$TSTAMP.tar.gz" "$1.latest.tar.gz"
}

# Shortcut for non-repo items (issues, comments, metadata JSONs...)
function tgz_nonrepo {
    GHBU_TARBALL_REPOS=true \
    GHBU_REUSE_REPOS=false \
    tgz "$@"
}

# Optionally delete files with a __WRITING__ extension,
# likely abandoned due to run-time errors like a reboot,
# Ctrl+C, connection loss, disk space...
function prune_incomplete {
    if $GHBU_PRUNE_INCOMPLETE ; then
        $GHBU_SILENT || (echo "" && echo "=== PRUNING INCOMPLETE LEFTOVERS (if any) ===" && echo "")
        $GHBU_SILENT || echo "Found `find $GHBU_BACKUP_DIR -maxdepth 1 -name '*.__WRITING__' | wc -l` files to prune."
        find $GHBU_BACKUP_DIR -maxdepth 1 -name '*.__WRITING__' -exec rm -fv {} > /dev/null \;
        $GHBU_SILENT || (echo "" && echo "=== PRUNING FINISHED ===" && echo "")
    fi
}

# The function `getdir` will return the repo directory name on stdout
# if successful (it depends on GHBU_REUSE_REPOS value).
function getdir {
    local REPOURI="$1"
    local DIRNAME

    REPOURI="$(echo "$REPOURI" | sed 's,^https://gist.github.com/\(.*\)$,gist-\1,')"
    # Note our caller adds a ".comments" suffix; another may be from API, orig:
    #   https://api.github.com/gists/b92a4fe5bb8eab70e79d6f1581563863/comments
    REPOURI="$(echo "$REPOURI" | sed 's,^'"$GHBU_API"'/gists/\([^/]*\)/comments\(\.comments\)*$,gist-\1-comments,')"

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

# See coments below
function GITCMD {
    if [ -z "$CRED_HELPER" ] ; then
        git "$@"
    else
        # Note the deletion of credential.helper first, it is multivalued
        # Per https://stackoverflow.com/a/70963737 explanation:
        # > The additional empty value for credential.helper causes any
        # > existing credential helpers to be removed, preventing the
        # > addition of this token into the user's credential helper.
        # > If you'd like the user to be able to save it, then remove
        # > that directive.
        # In our case, the first HTTP(S) download would block asking for
        # user/pass; however a "credential.helper=cache --timeout=360000"
        # might help subsequent activities (and/or corrupt them, if we use
        # different credentials for backups and/or interactive development).
        git -c credential.helper= -c credential.helper="$CRED_HELPER" "$@"
    fi
}

# The function `getgit` will clone (or update) specified repo ($1, without
# a `.git` suffix) into specified directory ($2)
function getgit (
    # Sub-shelled to constrain "export" visibility of credentials
    local REPOURI="$1"
    local DIRNAME="$2"

    case x"$1" in
        xhttp://*|xhttps://*)
            # Prepare HTTP(S) credential support for this git operation.
            local CRED_HELPER='!f() { echo "username=$GHBU_UNAME"; echo "password=$GHBU_PASSWD"; }; f'
            export CRED_HELPER GHBU_UNAME GHBU_PASSWD
            ;;
    esac

    if $GHBU_REUSE_REPOS && [ -d "${DIRNAME}" ] ; then
        # Update an existing repo (if reusing)
        $GHBU_SILENT || echo "... Updating $REPOURI clone in $DIRNAME"
        # Note "fatal: fetch --all does not make sense with refspecs" likely in the mirror:
        (cd "${DIRNAME}" && {
            GITCMD fetch --quiet --tags \
            && GITCMD fetch --quiet --all \
            || GITCMD fetch --quiet
        }) || return
    else
        $GHBU_SILENT || echo "... Cloning $REPOURI into $DIRNAME"
        case x"$1" in
            x*@*|x*://*) # URL already; .git suffix should be irrelevant
                ${GHBU_GIT_CLONE_CMD} "${REPOURI}" "${DIRNAME}" || return
                ;;
            *) # Just a repo name - complete it with data we know of
                ${GHBU_GIT_CLONE_CMD_SSH}"${GHBU_ORG}/${REPOURI}.git" "${DIRNAME}" \
                || { # Errors were seen above, so no GHBU_SILENT here:
                    echo "..... Attempt a retry over HTTPS" >&2
                    # FIXME: Effectively we craft the clone_url
                    # here, rather than using one from metadata
                    ${GHBU_GIT_CLONE_CMD} "https://${GHBU_GITHOST}/${GHBU_ORG}/${REPOURI}" "${DIRNAME}" \
                    && echo "..... Attempt a retry over HTTPS: SUCCEEDED" >&2 ; \
                } || return
                ;;
        esac
    fi

    # Return a success either way here:
    $GHBU_SILENT || echo "+++ Received $REPOURI into $DIRNAME"
)

function filter_user_org {
    # Might be better off getting a "clone_url" here, but so far our
    # directory naming etc. rely on the "REPONAME" value received here:
    check grep  "^    \"name\"" | check awk -F': "' '{print $2}' | check sed -e 's/",//g'
}

function filter_gist {
    check sed -n 's/.*git_pull_url": "\(.*\)",/\1/p'
}

function filter_gist_comments {
    check sed -n 's/.*comments_url": "\(.*\)",/\1/p'
}

function get_multipage_file {
    # Uses caller envvars FILENAME, APIURL, APIQUERY_SUFFIX, ENTRYID_REGEX
    # Returns MULTIPAGE_NUM, MULTIPAGE_OK, ENTRY_COUNT

    # Assumes GNU date or compatible - try to avoid extra traffic for us
    # and load for servers (and REST API quota hits), by asking GitHub
    # REST API directly: "If-Modified-Since" we last fetched the document:
    [ -s "$FILENAME" ] && FILEDATE="`date -R -u -r "$FILENAME" | sed 's,\+0000,GMT,'`" || FILEDATE=""
    rm -f "$FILENAME" || true
    MULTIPAGE_NUM=1
    MULTIPAGE_OK=true
    ENTRY_COUNT=0
    while : ; do
        # ex. APIURL="${GHBU_API}/repos/${GHBU_ORG}/${REPO}/issues"
        # ex. APIQUERY_SUFFIX="&state=all"
        # Also note: https://docs.github.com/en/rest/overview/resources-in-the-rest-api?apiVersion=2022-11-28#user-agent-required
        # hence `the User-Agent: username`
        # Ordering defaults to showing newest issues first
        CURLRES=0
        rm -f "${FILENAME}.headers" || true
        curl --silent -u "${GHBU_UNAME}:${GHBU_PASSWD}" \
            -H "User-Agent: ${GHBU_UNAME}" \
            ${FILEDATE+-H "If-Modified-Since: $FILEDATE" -D "${FILENAME}.headers"} \
            "${APIURL}?per_page=100&page=${MULTIPAGE_NUM}${APIQUERY_SUFFIX}" -q \
        > "${FILENAME}.__WRITING__" \
        || {
            echo "FAILED to fetch '${APIURL}' once: will sleep in case it is about the usage quota and try again"
            sleep 120
            check curl --silent -u "${GHBU_UNAME}:${GHBU_PASSWD}" \
                -H "User-Agent: ${GHBU_UNAME}" \
                ${FILEDATE+-H "If-Modified-Since: $FILEDATE" -D "${FILENAME}.headers"} \
                "${APIURL}?per_page=100&page=${MULTIPAGE_NUM}${APIQUERY_SUFFIX}" -q \
            > "${FILENAME}.__WRITING__"
        } || CURLRES=$?

        if head -1 "${FILENAME}.headers" | grep -E "HTTP.*304" ; then
            rm -f "${FILENAME}.headers" "${FILENAME}.__WRITING__"
            MULTIPAGE_OK=true
            ENTRY_COUNT="`grep -Ec "$ENTRYID_REGEX" < "${FILENAME}"`"
            break
        fi
        # Only ask for first page
        FILEDATE=""

        if [ $CURLRES != 0 ] ; then
            MULTIPAGE_OK=false
            break
        fi

        # ex. ENTRYID_REGEX='"url": "'"${GHBU_API}/repos/${GHBU_ORG}/${REPO}/issues/[0123456789]+"'"'
        NUM="`grep -Ec "$ENTRYID_REGEX" < "${FILENAME}.__WRITING__"`"
        ENTRY_COUNT="`expr $ENTRY_COUNT + $NUM`"

        if [ ! -e "${FILENAME}" ] ; then
            mv -f "${FILENAME}.__WRITING__" "${FILENAME}"
        else
            (head -n -2 "${FILENAME}" && \
             echo "  }," && \
             tail -n +2 "${FILENAME}.__WRITING__"
            ) > "${FILENAME}.__WRITING__.tmp" \
            || { MULTIPAGE_OK=false; break; }

            mv -f "${FILENAME}.__WRITING__.tmp" "${FILENAME}"
            rm -f "${FILENAME}.__WRITING__"
        fi

        if [ $NUM -lt 100 ] ; then
            # Last page
            break
        fi
        MULTIPAGE_NUM="`expr $MULTIPAGE_NUM + 1`"
    done

    # Return status
    $MULTIPAGE_OK
}

$GHBU_SILENT || (echo "" && echo "=== INITIALIZING ===" && echo "")

$GHBU_SILENT || echo "Using backup directory $GHBU_BACKUP_DIR"
check mkdir -p $GHBU_BACKUP_DIR

prune_incomplete

$GHBU_SILENT || echo -n "Fetching list of repositories for ${GHBU_ORG}..."

case x"$GHBU_ORGMODE" in
    x"gist"|x"gists")
        GHBU_ORG_URI="/gists"
        ;;
    x"user"|x"users")
        # NOTE: if you're backing up a *user's* repos, not an organizations, use this instead:
        if [ "${GHBU_ORG}" = "${GHBU_UNAME}" ] ; then
            # Backing up ourselves
            GHBU_ORG_URI="/user"
        else
            # Backing up a friend/alter-ego (using our login)
            GHBU_ORG_URI="/users/${GHBU_ORG}"
        fi
        ;;
    x"org"|*)   # Legacy default
        GHBU_ORG_URI="/orgs/${GHBU_ORG}"
        ;;
esac

# Be sure to stash a fresh copy, even if previous backup was interrupted
rm -f "${GHBU_BACKUP_DIR}/${GHBU_ORG}-metadata.json.__WRITING__"
touch "${GHBU_BACKUP_DIR}/${GHBU_ORG}-metadata.json.__WRITING__"

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
            # The "type=owner" should be default per https://docs.github.com/en/rest/repos/repos?apiVersion=2022-11-28#list-repositories-for-a-user
            # but with a powerful token a "user" backup may see all repos
            # one has access to (collaborating in other orgs). Other than
            # lots of noise and more time to get the listing, this leads
            # to broken backup cycles when we try to fetch repo names that
            # are not known under this user's personal namespace.
            JSON="$(check curl --silent -u "${GHBU_UNAME}:${GHBU_PASSWD}" -H "User-Agent: ${GHBU_UNAME}" "${GHBU_API}${GHBU_ORG_URI}/repos?per_page=100&page=$PAGENUM&type=owner" -q)"
            REPOLIST_PAGE="$(echo "$JSON" | filter_user_org)"
            ;;
        xgist*)
            JSON="$(check curl --silent -u "${GHBU_UNAME}:${GHBU_PASSWD}" -H "User-Agent: ${GHBU_UNAME}" "${GHBU_API}${GHBU_ORG_URI}?per_page=100&page=$PAGENUM" -q)"
            REPOLIST_PAGE="$(echo "$JSON" | filter_gist)"
            GIST_COMMENTLIST_PAGE="$(echo "$JSON" | filter_gist_comments)"
            ;;
    esac

    echo "$JSON" >> "${GHBU_BACKUP_DIR}/${GHBU_ORG}-metadata.json.__WRITING__"

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

REPOS_COUNT=0
REPOS_TOTAL="`echo $REPOLIST | wc -w`"
$GHBU_SILENT || echo " found $REPOS_TOTAL repositories."

mv -f "${GHBU_BACKUP_DIR}/${GHBU_ORG}-metadata.json.__WRITING__" "${GHBU_BACKUP_DIR}/${GHBU_ORG}-metadata.json"
tgz_nonrepo "${GHBU_BACKUP_DIR}/${GHBU_ORG}-metadata.json"

$GHBU_SILENT || (echo "" && echo "=== BACKING UP ===" && echo "")

for REPO in $REPOLIST; do
    REPOS_COUNT=$(($REPOS_COUNT+1))
    $GHBU_SILENT || echo "Backing up ${GHBU_ORG}/${REPO} ($REPOS_COUNT of $REPOS_TOTAL)"
    DIRNAME="`getdir "$REPO"`"
    { getgit "${REPO}" "${DIRNAME}" || {
        echo "FAILED to getgit '${REPO}' '${DIRNAME}': will sleep in case it is about the usage quota and try again"
        sleep 120
        if [ x"$GHBU_FAILFAST_GETGIT" = xtrue ]; then
            echo "RETRY getgit '${REPO}' '${DIRNAME}': failure now WILL BE FATAL"
            check getgit "${REPO}" "${DIRNAME}"
        else
            echo "RETRY getgit '${REPO}' '${DIRNAME}': failure now will NOT be fatal"
            getgit "${REPO}" "${DIRNAME}"
        fi
    } ; } && tgz "${DIRNAME}"

    # No wikis nor issues for gists; but there are comments (see another loop)
    case x"$GHBU_ORGMODE" in
        xorg*|xuser*)
            $GHBU_SILENT || echo "Backing up ${GHBU_ORG}/${REPO}.wiki (if any)"
            DIRNAME="`getdir "$REPO.wiki"`"
            # Failure is an option for wikis:
            getgit "${REPO}.wiki" "${DIRNAME}" 2>/dev/null && tgz "${DIRNAME}"

            # NOTE: While internally issues and PRs seem to be the same,
            # at least using the same numbering and responding with them
            # to either URL (can discern by "html_url"), they are both
            # listed via both numbers: all entities are in "issues" but
            # only PRs (with partially different metadata) are in "pulls".

            DIRNAME="`getdir "$REPO.issues-and-pulls"`"
            $GHBU_SILENT || echo "Preparing local git repo in '${DIRNAME}' to receive issue and PR data"
            if [ -d "${DIRNAME}/.git" ]; then
                ( cd "${DIRNAME}" && git checkout -f && git clean -fffdddxxx ) \
                || check [ "$?" = 0 ]
            else
                check mkdir -p "${DIRNAME}" \
                && ( cd "${DIRNAME}" && git init \
                    && touch list-issues.json list-pulls.json \
                    && git add list-issues.json list-pulls.json \
                    && git commit -m 'Initial commit' ) \
                || check [ "$?" = 0 ]
            fi

            # List of issues:
            $GHBU_SILENT || echo "Backing up ${GHBU_ORG}/${REPO} issues"
            ISSUES_FILENAME="${DIRNAME}/list-issues.json"
            FILENAME="${ISSUES_FILENAME}" \
                APIURL="${GHBU_API}/repos/${GHBU_ORG}/${REPO}/issues" \
                APIQUERY_SUFFIX="&state=all" \
                ENTRYID_REGEX='"url": "'"${GHBU_API}/repos/${GHBU_ORG}/${REPO}/issues/[0123456789]+"'"' \
                get_multipage_file
            $GHBU_SILENT || echo "Collected ${ENTRY_COUNT} issues in ${MULTIPAGE_NUM} pages for ${GHBU_ORG}/${REPO}; overall success: ${MULTIPAGE_OK}"
            $MULTIPAGE_OK && ( cd "${DIRNAME}" && git add "`basename "$ISSUES_FILENAME"`" ) || MULTIPAGE_OK=false
            ISSUES_OK="$MULTIPAGE_OK"
            ISSUES_NUM="${ENTRY_COUNT}"

            # List of PRs:
            $GHBU_SILENT || echo "Backing up ${GHBU_ORG}/${REPO} pull requests"
            PULLS_FILENAME="${DIRNAME}/list-pulls.json"
            FILENAME="${PULLS_FILENAME}" \
                APIURL="${GHBU_API}/repos/${GHBU_ORG}/${REPO}/pulls" \
                APIQUERY_SUFFIX="&state=all" \
                ENTRYID_REGEX='"url": "'"${GHBU_API}/repos/${GHBU_ORG}/${REPO}/pulls?/[0123456789]+"'"' \
                get_multipage_file
            $GHBU_SILENT || echo "Collected ${ENTRY_COUNT} pull requests in ${MULTIPAGE_NUM} pages for ${GHBU_ORG}/${REPO}; overall success: ${MULTIPAGE_OK}"
            $MULTIPAGE_OK && ( cd "${DIRNAME}" && git add "`basename "$PULLS_FILENAME"`" ) || MULTIPAGE_OK=false
            PULLS_OK="$MULTIPAGE_OK"
            PULLS_NUM="${ENTRY_COUNT}"

            # Contents
            ( $ISSUES_OK && grep '"comments_url"' "$ISSUES_FILENAME" || true
              $PULLS_OK && grep -E '"(comments_url|review_comments_url|commits_url)"' "$PULLS_FILENAME" || true
            ) | awk '{print $NF}' | sed -e 's,^",,' -e 's/",*$//' | sort -n | uniq | \
            while IFS= read SUB_URL \
            ; do
                SUB_FILENAME="`echo "$SUB_URL" | sed -e "s,^${GHBU_API}/repos/${GHBU_ORG}/${REPO}/,," -e 's,[:/],-,g'`.json"
                # Skip user metadata
                case "$SUB_FILENAME" in
                    http---*|https---*|*"{-"*"}"*) continue ;;
                esac
                $GHBU_SILENT || echo "Backing up ${GHBU_ORG}/${REPO} issue or pull request details from: ${SUB_URL}"
                FILENAME="${DIRNAME}/${SUB_FILENAME}" APIURL="${SUB_URL}" \
                    ENTRYID_REGEX='("sha": "[0-9a-f]{40}"|"url": "'"${GHBU_API}/repos/${GHBU_ORG}/${REPO}/(issues|pulls)/comments/[0-9]+"'")' \
                    get_multipage_file \
                && ( cd "${DIRNAME}" && git add "${SUB_FILENAME}" )
            done

            $PULLS_OK && $ISSUES_OK \
            && ( cd "${DIRNAME}" && git commit -m "Update due to backup at `LANG=C LC_ALL=C TZ=UTC date -u`" ) \
            && tgz "${DIRNAME}"
            ;;
    esac
done

# Assumes GHBU_ORGMODE=gist, but no reason to constrain:
COMMENT_COUNT=0
COMMENT_TOTAL="`echo $GIST_COMMENTLIST | wc -w`"
for COMMENT_URL in $GIST_COMMENTLIST; do
    COMMENT_COUNT=$(($COMMENT_COUNT+1))
    $GHBU_SILENT || echo "Backing up ${GHBU_ORG}/${COMMENT_URL} comments ($COMMENT_COUNT of $COMMENT_TOTAL)"
    FILENAME="`getdir "${COMMENT_URL}.comments" | sed 's,.git$,,'`"
    check curl --silent -u "${GHBU_UNAME}:${GHBU_PASSWD}" \
        -H "User-Agent: ${GHBU_UNAME}" \
        "${COMMENT_URL}" -q \
    > "${FILENAME}.__WRITING__" \
    && mv -f "${FILENAME}.__WRITING__" "${FILENAME}" \
    && tgz_nonrepo "${FILENAME}"
done

# NOTE: the "latest" and optional "prev" handling below allows us to leave at
# least one (better two) backup tarballs for each timestamped item sequence.
# GitHub going AWOL and us deleting all backups after 3 days would be folly!
# (Less of a problem if we do keep the repos, but comments/issues/medatata
# are still at risk - maybe GIT their evolution locally?)

# NOTE: according to `man find` (GNU, comments to `-atime` et al handling),
# the fractional parts of "n*24 hours" are ignored, "so to match -atime +1,
# a file has to have been accessed at least two days ago".
# This way, GHBU_PRUNE_AFTER_N_DAYS=0 only chops files older than 24 hours.
if $GHBU_PRUNE_OLD && [ "${GHBU_PRUNE_AFTER_N_DAYS}" -ge 0 ]; then
    $GHBU_SILENT || (echo "" && echo "=== PRUNING ===" && echo "")
    $GHBU_SILENT || echo "Pruning backup files ${GHBU_PRUNE_AFTER_N_DAYS} days old or older."
    $GHBU_SILENT || echo "Found `find $GHBU_BACKUP_DIR -maxdepth 1 -name '*.tar.gz' -a \! -name '*.prev.tar.gz' -a \! -name '*.latest.tar.gz' -mtime +${GHBU_PRUNE_AFTER_N_DAYS} | wc -l` files to prune."
    find $GHBU_BACKUP_DIR -maxdepth 1 -name '*.tar.gz' -a \! -name '*.prev.tar.gz' -a \! -name '*.latest.tar.gz' -mtime "+${GHBU_PRUNE_AFTER_N_DAYS}" -exec rm -fv {} > /dev/null \;
    $GHBU_SILENT || (echo "" && echo "=== PRUNING FINISHED ===" && echo "")
fi
prune_incomplete

$GHBU_SILENT || (echo "" && echo "=== DONE ===" && echo "")
$GHBU_SILENT || (echo "GitHub backup for ${GHBU_ORG} (${GHBU_ORGMODE}) completed." && echo "")
