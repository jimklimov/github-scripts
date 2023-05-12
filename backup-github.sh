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
# * If you have more than 100 repositories, you'll need to step thru the list
#   of repos returned by GitHub one page at a time, as described at 
#   https://gist.github.com/darktim/5582423
#
# * If you want to back up the repos for a USER rather than an ORGANIZATION, 
#   there's a small change needed. See the comment on the `REPOLIST` definition
#   below (i.e search for "REPOLIST" and make the described change).
#
# * Thanks to @Calrion, @vnaum, @BartHaagdorens and other commenters below for
#   various fixes and updates.
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
GHBU_ORGMODE=${GHBU_ORGMODE-"org"}                                   # "org" or "user"?
GHBU_BACKUP_DIR=${GHBU_BACKUP_DIR-"github-backups"}                  # where to place the backup files
GHBU_GITHOST=${GHBU_GITHOST-"github.com"}                            # the GitHub hostname (see comments)
GHBU_PRUNE_OLD=${GHBU_PRUNE_OLD-true}                                # when `true`, old backups will be deleted
GHBU_PRUNE_AFTER_N_DAYS=${GHBU_PRUNE_AFTER_N_DAYS-3}                 # the min age (in days) of backup files to delete
GHBU_SILENT=${GHBU_SILENT-false}                                     # when `true`, only show error messages 
GHBU_API=${GHBU_API-"https://api.github.com"}                        # base URI for the GitHub API
GHBU_GIT_CLONE_CMD="git clone --quiet --mirror git@${GHBU_GITHOST}:" # base command to use to clone GitHub repos
TSTAMP=`date "+%Y%m%d-%H%M"`                                         # format of timestamp suffix appended to archived files
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

# The function `tgz` will create a gzipped tar archive of the specified file ($1) and then remove the original
function tgz {
   check tar zcf $1.tar.gz $1 && check rm -rf $1
}

$GHBU_SILENT || (echo "" && echo "=== INITIALIZING ===" && echo "")

$GHBU_SILENT || echo "Using backup directory $GHBU_BACKUP_DIR"
check mkdir -p $GHBU_BACKUP_DIR

$GHBU_SILENT || echo -n "Fetching list of repositories for ${GHBU_ORG}..."

if [ x"$GHBU_ORGMODE" = x"org" ] ; then
    GHBU_ORG_URI="/orgs/${GHBU_ORG}"
else
    # NOTE: if you're backing up a *user's* repos, not an organizations, use this instead:
    GHBU_ORG_URI="/user"
fi

REPOLIST=""
REPOLIST_PAGE=""
PAGENUM=1
while : ; do
    # hat tip to https://gist.github.com/rodw/3073987#gistcomment-3217943 for the license name workaround
    REPOLIST_PAGE="$(check curl --silent -u "$GHBU_UNAME:$GHBU_PASSWD" "${GHBU_API}${GHBU_ORG_URI}/repos?per_page=100&page=$PAGENUM" -q | check grep  "^    \"name\"" | check awk -F': "' '{print $2}' | check sed -e 's/",//g')"
    if [ -z "$REPOLIST" ] ; then
        REPOLIST="$REPOLIST_PAGE"
    else
        REPOLIST="$REPOLIST
$REPOLIST_PAGE"
    fi
    if [ 100 -ne `echo $REPOLIST_PAGE | wc -w` ] ; then
        break
    fi
    PAGENUM=$(($PAGENUM+1))
    $GHBU_SILENT || echo -n " Fetching next page of repos: $PAGENUM..."
done

$GHBU_SILENT || echo " found `echo $REPOLIST | wc -w` repositories."


$GHBU_SILENT || (echo "" && echo "=== BACKING UP ===" && echo "")

for REPO in $REPOLIST; do
   $GHBU_SILENT || echo "Backing up ${GHBU_ORG}/${REPO}"
   check ${GHBU_GIT_CLONE_CMD}${GHBU_ORG}/${REPO}.git ${GHBU_BACKUP_DIR}/${GHBU_ORG}-${REPO}-${TSTAMP}.git && tgz ${GHBU_BACKUP_DIR}/${GHBU_ORG}-${REPO}-${TSTAMP}.git

   $GHBU_SILENT || echo "Backing up ${GHBU_ORG}/${REPO}.wiki (if any)"
   ${GHBU_GIT_CLONE_CMD}${GHBU_ORG}/${REPO}.wiki.git ${GHBU_BACKUP_DIR}/${GHBU_ORG}-${REPO}.wiki-${TSTAMP}.git 2>/dev/null && tgz ${GHBU_BACKUP_DIR}/${GHBU_ORG}-${REPO}.wiki-${TSTAMP}.git

   $GHBU_SILENT || echo "Backing up ${GHBU_ORG}/${REPO} issues"
   check curl --silent -u $GHBU_UNAME:$GHBU_PASSWD ${GHBU_API}/repos/${GHBU_ORG}/${REPO}/issues -q > ${GHBU_BACKUP_DIR}/${GHBU_ORG}-${REPO}.issues-${TSTAMP} && tgz ${GHBU_BACKUP_DIR}/${GHBU_ORG}-${REPO}.issues-${TSTAMP}
done

if $GHBU_PRUNE_OLD; then
  $GHBU_SILENT || (echo "" && echo "=== PRUNING ===" && echo "")
  $GHBU_SILENT || echo "Pruning backup files ${GHBU_PRUNE_AFTER_N_DAYS} days old or older."
  $GHBU_SILENT || echo "Found `find $GHBU_BACKUP_DIR -name '*.tar.gz' -mtime +$GHBU_PRUNE_AFTER_N_DAYS | wc -l` files to prune."
  find $GHBU_BACKUP_DIR -name '*.tar.gz' -mtime +$GHBU_PRUNE_AFTER_N_DAYS -exec rm -fv {} > /dev/null \; 
fi

$GHBU_SILENT || (echo "" && echo "=== DONE ===" && echo "")
$GHBU_SILENT || (echo "GitHub backup completed." && echo "")
