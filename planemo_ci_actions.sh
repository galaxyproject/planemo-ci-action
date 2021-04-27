#!/usr/bin/env bash
set -ex

PLANEMO_TEST_OPTIONS=("--database_connection" "$DATABASE_CONNECTION" "--galaxy_source" "https://github.com/$GALAXY_FORK/galaxy" "--galaxy_branch" "$GALAXY_BRANCH" "--galaxy_python_version" "$PYTHON_VERSION")
PLANEMO_CONTAINER_DEPENDENCIES=("--biocontainers" "--no_dependency_resolution" "--no_conda_auto_init")
PLANEMO_WORKFLOW_OPTIONS=("--shed_tool_conf" "/cvmfs/main.galaxyproject.org/config/shed_tool_conf.xml" "--no_shed_install" "--tool_data_table" "/cvmfs/data.galaxyproject.org/byhand/location/tool_data_table_conf.xml" "--tool_data_table" "/cvmfs/data.galaxyproject.org/managed/location/tool_data_table_conf.xml" "--docker_extra_volume" "/cvmfs")
# ensure that all files that are used for action outputs are present 
mkdir -p upload
touch repository_list.txt tool_list.txt chunk_count.txt commit_range.txt statistics.txt 

# run a mock planemo test (should be considered part of setup mode)
if [ "$CREATE_CACHE" != "false" ]; then
  tmp_dir=$(mktemp -d)
  touch "$tmp_dir/tool.xml"
  PIP_QUIET=1 planemo test --galaxy_python_version "$PYTHON_VERSION" --no_conda_auto_init --galaxy_source https://github.com/"$GALAXY_FORK"/galaxy --galaxy_branch "$GALAXY_BRANCH" "$tmp_dir"
fi

GITHUB_EVENT_NAME=${GITHUB_EVENT_NAME_OVERRIDE:-$GITHUB_EVENT_NAME}
GITHUB_REF=${GITHUB_REF_OVERRIDE:-$GITHUB_REF}

# setup mode
# - get commit range (for push and pull_request events) .. 
#   not set for sheduled and repository_dispatch events
# - get list of relevant tools and repositories
#   - tools/repos in the commit range (if set)
#   - tools/repos not listed in .tt_skip or contained in 
#     `packages/` or `deprecated/`
# - determine chunk count as linear function of the number
#   of tools (limited by MAX_CHUNK)
if [ "$REPOSITORIES" == "" ] && [ "$MODE" == "setup" ]; then
  # The range of commits to check for changes is:
  # - `origin/main...` (resp. `origin/master`) for all events happening on a feature branch
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
      if git fetch origin main; then
        COMMIT_RANGE="origin/main..."
      else
        git fetch origin master
        COMMIT_RANGE="origin/master..."
      fi
      ;;
    esac
  elif [ "$GITHUB_EVENT_NAME" = "pull_request" ]; then
    COMMIT_RANGE="HEAD~.."
  fi
  echo "$COMMIT_RANGE" > commit_range.txt

  if [ -n "$COMMIT_RANGE" ]; then
    PLANEMO_COMMIT_RANGE=("--changed_in_commit_range" "$COMMIT_RANGE")
  fi
  
  touch .tt_skip
  planemo ci_find_repos "${PLANEMO_COMMIT_RANGE[@]}" --exclude packages --exclude deprecated --exclude_from .tt_skip --output repository_list.txt
  REPOSITORIES=$(cat repository_list.txt)

  touch tool_list.txt
  if [ "$WORKFLOWS" != "true" ]; then
    planemo ci_find_tools "${PLANEMO_COMMIT_RANGE[@]}" --exclude packages --exclude deprecated --exclude_from .tt_skip --output tool_list.txt
    TOOLS=$(cat tool_list.txt)
  fi

  # determine the number of chunks to use as linear function of the number of
  # tested tools (i.e. all tools in the changed repos)
  if [ "$WORKFLOWS" != "true" ]; then
    if [ -s repository_list.txt ]; then
      if [ -n "$COMMIT_RANGE" ]; then
        mapfile -t REPO_ARRAY < repository_list.txt
        planemo ci_find_tools --output count_list.txt "${REPO_ARRAY[@]}" 
      else
        ln -s tool_list.txt count_list.txt
      fi
    fi
    touch count_list.txt
  else
    ln -s repository_list.txt count_list.txt
  fi

  CHUNK_COUNT=$(wc -l < count_list.txt)
  if [ "$CHUNK_COUNT" -gt "$MAX_CHUNKS" ]; then
    CHUNK_COUNT=$MAX_CHUNKS
  elif [ "$CHUNK_COUNT" -eq 0 ]; then
    CHUNK_COUNT=1
  fi
  echo $CHUNK_COUNT > chunk_count.txt
else
  echo -n "$REPOSITORIES" > repository_list.txt
  echo -n "$TOOLS" > tool_list.txt
  echo -n "$CHUNK_COUNT" > chunk_count.txt
fi

# lint mode
# - call `planemo lint` for each repo
# - check if each tool is in a repo (i.e. if `.shed.yml` is present)
if [ "$MODE" == "lint" ]; then
  mapfile -t REPO_ARRAY < repository_list.txt
  for DIR in "${REPO_ARRAY[@]}"; do
    if [ "$WORKFLOWS" != "true" ]; then
      planemo shed_lint --tools --ensure_metadata --urls --report_level warn --fail_level error --recursive "$DIR" | tee -a lint_report.txt
    else
      planemo workflow_lint --fail_level error "$DIR" | tee -a lint_report.txt
    fi
  done

  # Check if each changed tool is in the list of changed repositories
  mapfile -t TOOL_ARRAY < tool_list.txt
  for TOOL in "${TOOL_ARRAY[@]}"; do
    # Check if any changed repo dir is a substring of $TOOL
    if ! echo "$TOOL" | grep -qf repository_list.txt; then
      echo "Tool $TOOL not in changed repositories list: .shed.yml file missing" >&2
      exit 1
    fi
  done
fi

# test mode
# - compute grouped chunked tool list
# - run `planemo test` each tool group
# - merge the test reports for the tool groups
if [ "$MODE" == "test" ]; then

  # set a random date. ofen tools put time stamps in output files
  # for tools undergoing short reviews (<1d) these will produce
  # problems with weekly checks that may be avoided by this
  rand=$(echo "$RANDOM * $RANDOM * $RANDOM / 1000" | bc -l | sed 's/\..*$//')
  randdate=$(date -d "$rand" +%Y%m%d %H:%M)
  sudo date -s "$randdate"

  if [ "$WORKFLOWS" == "true" ] && [ "$SETUP_CVMFS" == "true" ]; then
    "$GITHUB_ACTION_PATH"/cvmfs/setup_cvmfs.sh
  fi

  # Find tools for chunk
  touch tool_list_chunk.txt
  if [ -s repository_list.txt ]; then
    mapfile -t REPO_ARRAY < repository_list.txt
    if [ "$WORKFLOWS" != "true" ]; then
      planemo ci_find_tools --chunk_count "$CHUNK_COUNT" --chunk "$CHUNK" --group_tools --output tool_list_chunk.txt "${REPO_ARRAY[@]}"
    else
      planemo ci_find_repos --chunk_count "$CHUNK_COUNT" --chunk "$CHUNK" --output tool_list_chunk.txt "${REPO_ARRAY[@]}"
    fi 
  fi

  # show tools
  cat tool_list_chunk.txt
  
  # Test tools
  mkdir -p json_output
  touch .tt_biocontainer_skip
  while read -r -a TOOL_GROUP; do
    # Check if any of the lines in .tt_biocontainer_skip is a substring of $TOOL_GROUP
    if echo "${TOOL_GROUP[@]}" | grep -qf .tt_biocontainer_skip; then
      PLANEMO_OPTIONS=()
    else
      PLANEMO_OPTIONS=("${PLANEMO_CONTAINER_DEPENDENCIES[@]}")
    fi
    if [ "$WORKFLOWS" == "true" ]; then
      PLANEMO_OPTIONS+=("${PLANEMO_WORKFLOW_OPTIONS[@]}")
    fi  
    json=$(mktemp -u -p json_output --suff .json)
    PIP_QUIET=1 planemo test "${PLANEMO_OPTIONS[@]}" "${PLANEMO_TEST_OPTIONS[@]}" --test_output_json "$json" "${TOOL_GROUP[@]}" || true
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
if [ "$MODE" == "combine" ]; then
  find artifacts/ -name tool_test_output.json
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
if [ "$MODE" == "check" ]; then

  if jq '.["tests"][]["data"]["status"]' upload/tool_test_output.json | grep -v "success"; then
    echo "Unsuccessful tests found, inspect the 'All tool test results' artifact for details."
    exit 1
  fi
fi

# deploy mode
if [ "$MODE" == "deploy" ]; then
  mapfile -t REPO_ARRAY < repository_list.txt
  for DIR in "${REPO_ARRAY[@]}"
  do
    if [ "$WORKFLOWS" != "true" ]; then
      planemo shed_update --shed_target "$SHED_TARGET" --shed_key "$SHED_KEY" --force_repository_creation "$DIR" || exit 1;
    else
      planemo workflow_upload --namespace "$WORKFLOW_NAMESPACE" "$DIR" || exit 1;
    fi
  done
fi
