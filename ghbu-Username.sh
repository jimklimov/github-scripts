#!/bin/bash

# Sample wrapper to call backup-github.sh for org/user/gists
# (C) 2023 by Jim Klimov

# Regarding pruning (if enabled): the systemd unit default is to
# run the backup weekly; this way 30 days (below) keep 4-5 copies.
#GHBU_PRUNE_OLD="false" \
GHBU_PRUNE_AFTER_N_DAYS=30 \
GHBU_ORGMODE="user" \
GHBU_ORG="Username" \
GHBU_UNAME="Username" \
GHBU_PASSWD="ghp_SomeGithubAPITokenValueString" \
GHBU_BACKUP_DIR="`dirname $0`/${GHBU_ORGMODE}_${GHBU_ORG}" \
GHBU_PRUNE_INCOMPLETE="true" \
GHBU_REUSE_REPOS="true" \
"`dirname $0`/backup-github.sh"
