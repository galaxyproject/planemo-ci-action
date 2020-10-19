#!/usr/bin/env bash

# The range of commits to check for changes is:
# - `origin/master...` for all events happening on a feature branch
# - for events on the master branch we compare against the sha before the event
#   (note that this does not work for feature branch events since we want all
#   commits on the feature branch and not just the commits of the last event)
# - for pull requests we compare against the 1st ancestor, given the current
#   HEAD is the merge between the PR branch and the base branch

if [ "$GITHUB_EVENT_NAME" =  "push" ]; then
  case "$GITHUB_REF" in
    refs/heads/master|refs/heads/main )
    git fetch origin master
    COMMIT_RANGE="origin/master..."
    ;;
    *)
    COMMIT_RANGE="$EVENT_BEFORE.."
  esac
elif [ "$GITHUB_EVENT_NAME" = "pull_request" ]; then
  COMMIT_RANGE="HEAD~.."
fi

echo "COMMIT_RANGE=$COMMIT_RANGE" >> "$GITHUB_ENV"
