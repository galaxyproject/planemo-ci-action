#!/usr/bin/env bash
set -ex

# ensure that all files that are used for action outputs are present 
mkdir -p upload
touch repository_list.txt tool_list.txt chunk_count.txt commit_range.txt statistics.txt 

# run a mock planemo test (should be considered part of setup mode)
if [ "$CREATE_CACHE" != "false" ]; then
  tmp_dir=$(mktemp -d)
  touch "$tmp_dir/tool.xml"
  PIP_QUIET=1 planemo test --galaxy_python_version "$PYTHON_VERSION" --no_conda_auto_init --galaxy_source https://github.com/"$GALAXY_FORK"/galaxy --galaxy_branch "$GALAXY_BRANCH" "$tmp_dir"
fi

# setup mode
# 
# - get commit range (for push and pull_request events) .. 
#   not set for sheduled and repository_dispatch events
# - get list of relevant tools and repositories
#   - tools/repos in the commit range (if set)
#   - tools/repos not listed in .tt_skip or contained in 
#     `packages/` or `deprecated/`
# - determine chunk count as linear function of the number
#   of tools (limited by MAX_CHUNKS)
if [ "$REPOSITORIES" == "" -a "$PLANEMO_LINT_TOOLS" != "true" -a "$PLANEMO_TEST_TOOLS" != "true" -a "$PLANEMO_COMBINE_OUTPUTS" != "true" -a "$PLANEMO_CHECK_OUTPUTS" != "true" -a "$PLANEMO_DEPLOY_TOOLS" != "true" ]; then
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
      COMMIT_RANGE="$EVENT_BEFORE.."
      ;;
      *)
      git fetch origin master
      COMMIT_RANGE="origin/master..."
      ;;
    esac
  elif [ "$GITHUB_EVENT_NAME" = "pull_request" ]; then
    COMMIT_RANGE="HEAD~.."
  fi
  echo $COMMIT_RANGE > commit_range.txt

  if [ ! -z $COMMIT_RANGE ]; then
    PLANEMO_COMMIT_RANGE="--changed_in_commit_range $COMMIT_RANGE"
  fi
  
  planemo ci_find_repos $PLANEMO_COMMIT_RANGE --exclude packages --exclude deprecated --exclude_from .tt_skip --output repository_list.txt
  REPOSITORIES=$(cat repository_list.txt)

  # TODO check: run ci_find_tools on complete repo has the advantage that it can be reused in the linting step
  planemo ci_find_tools $PLANEMO_COMMIT_RANGE --exclude packages --exclude deprecated --exclude_from .tt_skip --output tool_list.txt
  TOOLS=$(cat tool_list.txt)
  # touch tool_list.txt
  # if [ -s repository_list.txt ]; then
  #   planemo ci_find_tools --output tool_list.txt $(cat repository_list.txt)
  # fi

  CHUNK_COUNT=$(wc -l < tool_list.txt)
  if [ "$CHUNK_COUNT" -gt "$MAX_CHUNKS" ]; then
    CHUNK_COUNT=$MAX_CHUNKS
  elif [ "$CHUNK_COUNT" -eq 0 ]; then
    CHUNK_COUNT=1
  fi
  echo $CHUNK_COUNT > chunk_count.txt
else
  echo "$REPOSITORIES" > repository_list.txt
  echo "$TOOLS" > tool_list.txt
  echo "$COMMIT_RANGE" > commit_range.txt
  echo "$CHUNK_COUNT" > chunk_count.txt
fi

# lint mode
# - call `planemo lint` for each repo
# - check if each tool is in a repo (i.e. if `.shed.yml` is present)
if [ "$PLANEMO_LINT_TOOLS" == "true" ]; then
  echo TOOLS
  cat tool_list.txt
  echo REPOSITORIES
  cat repository_list.txt
  while read -r DIR; do
    planemo shed_lint --tools --ensure_metadata --urls --report_level warn --fail_level error --recursive "$DIR";
  done < repository_list.txt
  # Check if each changed tool is in the list of changed repositories
  while read -r TOOL; do
    # Check if any changed repo dir is a substring of $TOOL
    if ! echo $TOOL | grep -qf repository_list.txt; then
      echo "Tool $TOOL not in changed repositories list: .shed.yml file missing" >&2
      exit 1
    fi
  done < tool_list.txt
fi

# test mode
# - compute grouped chunked tool list
# - run `planemo test` each tool group
# - merge the test reports for the tool groups
if [ "$PLANEMO_TEST_TOOLS" == "true" ]; then
  # Find tools for chunk
  touch tool_list_chunk.txt
  if [ -s repository_list.txt ]; then
    planemo ci_find_tools --chunk_count $CHUNK_COUNT --chunk $CHUNK --group_tools --output tool_list_chunk.txt $(cat repository_list.txt)
  fi

  # show tools
  cat tool_list_chunk.txt
  
  # Test tools
  mkdir json_output
  while read -r TOOL_GROUP; do
    # Check if any of the lines in .tt_biocontainer_skip is a substring of $TOOL_GROUP
    if echo $TOOL_GROUP | grep -qf .tt_biocontainer_skip; then
      PLANEMO_OPTIONS=""
    else
      PLANEMO_OPTIONS="--biocontainers --no_dependency_resolution --no_conda_auto_init"
    fi
    json=$(mktemp -u -p json_output --suff .json)
    PIP_QUIET=1 planemo test $PLANEMO_OPTIONS --database_connection "$DATABASE_CONNECTION" --galaxy_source https://github.com/"$GALAXY_FORK"/galaxy --galaxy_branch "$GALAXY_BRANCH" --galaxy_python_version "$PYTHON_VERSION" --test_output_json "$json" $TOOL_GROUP || true
    docker system prune --all --force --volumes || true
  done < tool_list_chunk.txt

  if [ ! -s tool_list_chunk.txt ]; then
    echo '{"tests":[]}' > "$(mktemp -u -p json_output --suff .json)"
  fi

  planemo merge_test_reports json_output/*.json tool_test_output.json
  planemo test_reports tool_test_output.json --test_output tool_test_output.html
  
  mv tool_test_output.json tool_test_output.html upload/
fi

# combine reports mode
# - combine the reports of the chunks
# - optionally generate html / markdown reports
# - compute statistics
if [ "$PLANEMO_COMBINE_OUTPUTS" == "true" ]; then
  # combine test reports in artifacts into a single one (upload/tool_test_output.json)
  find artifacts/ -name tool_test_output.json -exec sh -c 'planemo merge_test_reports "$@" upload/tool_test_output.json' sh {} +
  # create html and markdown reports
  [ "$PLANEMO_HTML_REPORT" == "true" ] && planemo test_reports upload/tool_test_output.json --test_output upload/tool_test_output.html
  [ "$PLANEMO_MD_REPORT" == "true" ] && planemo test_reports upload/tool_test_output.json --test_output_markdown upload/tool_test_output.md
  # get statistics
  jq '.["tests"][]["data"]["status"]' upload/tool_test_output.json | sed 's/"//g' | sort | uniq -c > statistics.txt
fi

# check outputs mode
# - check if there were unsuccessful tests
if [ "$PLANEMO_CHECK_OUTPUTS" == "true" ]; then

  if jq '.["tests"][]["data"]["status"]' upload/tool_test_output.json | grep -v "success"; then
    echo "Unsuccessful tests found, inspect the 'All tool test results' artifact for details."
    exit 1
  fi
fi

# deploy mode
if [ "$PLANEMO_DEPLOY_TOOLS" == "true" ]; then
   while read -r DIR; do
       planemo shed_update --shed_target "$SHED_TARGET" --shed_key "$SHED_KEY" --force_repository_creation "$DIR" || exit 1;
   done < repository_list.txt
fi
