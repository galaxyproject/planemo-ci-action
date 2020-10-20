#!/usr/bin/env bash
set -ex

PLANEMO_TEST_OPTIONS="--database_connection $DATABASE_CONNECTION --galaxy_source $GALAXY_REPO --galaxy_branch $GALAXY_RELEASE"
PLANEMO_CONTAINER_DEPENDENCIES="--biocontainers --no_dependency_resolution --no_conda_auto_init"
PLANEMO_WORKFLOW_OPTIONS="--no_paste_test_data_paths --shed_tool_conf /cvmfs/main.galaxyproject.org/config/shed_tool_conf.xml --no_shed_install --tool_data_table /cvmfs/data.galaxyproject.org/byhand/location/tool_data_table_conf.xml --tool_data_table /cvmfs/data.galaxyproject.org/managed/location/tool_data_table_conf.xml --docker_extra_volume /cvmfs "
export PIP_QUIET=1

if [ "$CREATE_CACHE" != "false" ]; then
  tmp_dir=$(mktemp -d)
  touch "$tmp_dir/tool.xml"
  planemo test --no_conda_auto_init --galaxy_source "$GALAXY_SOURCE" --galaxy_branch "$GALAXY_BRANCH" "$tmp_dir"
fi

if [ "$CHANGED_REPOSITORIES" == "" ]; then
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

  planemo ci_find_repos --changed_in_commit_range $COMMIT_RANGE --exclude packages --exclude deprecated --exclude_from .tt_skip --output changed_repositories.list
  CHANGED_REPOSITORIES=$(cat changed_repositories.list)
else
  echo "$CHANGED_REPOSITORIES" > changed_repositories.list
fi

if [ "$PLANEMO_LINT_TOOLS" == "true" ]; then
  planemo shed_lint --tools --ensure_metadata --urls --report_level warn --fail_level error --recursive "$CHANGED_REPOSITORIES"
fi

if [ "$PLANEMO_LINT_WORKFLOWS" == "true" ]; then
  planemo workflow_lint --fail_level error "$CHANGED_REPOSITORIES"
fi

if [ "$PLANEMO_TEST_TOOLS" == "true" ] || [ "$PLANEMO_TEST_WORKFLOWS" == "true" ] ; then
  # Find tools
  touch changed_repositories_chunk.list changed_tools_chunk.list
  if [ $(wc -l < changed_repositories.list) -eq 1 ] && [ "$PLANEMO_TEST_WORKFLOWS" != "true"  ] ; then
      planemo ci_find_tools --chunk_count "$CHUNK_COUNT" --chunk "$CHUNK" \
                     --output changed_tools_chunk.list \
                     $(cat changed_repositories.list)
  else
      planemo ci_find_repos --chunk_count "$CHUNK_COUNT" --chunk "$CHUNK" \
                     --output changed_repositories_chunk.list \
                     $(cat changed_repositories.list)
  fi

  # show tools or workflows
  cat changed_tools_chunk.list changed_repositories_chunk.list
  # test tools or workflows
  if grep -lqf .tt_biocontainer_skip changed_tools_chunk.list changed_repositories_chunk.list; then
          PLANEMO_OPTIONS=""
  else
          PLANEMO_OPTIONS=$PLANEMO_CONTAINER_DEPENDENCIES
  fi
  if [ "$PLANEMO_TEST_WORKFLOWS" == "true" ]; then
      PLANEMO_OPTIONS="$PLANEMO_OPTIONS $PLANEMO_WORKFLOW_OPTIONS"
  fi
  if [ -s changed_tools_chunk.list ]; then
      planemo test $PLANEMO_TEST_OPTIONS $PLANEMO_OPTIONS --test_output_json test_output.json $(cat changed_tools_chunk.list) || true
  elif [ -s changed_repositories_chunk.list ]; then
      while read -r DIR; do
          if [[ "$DIR" =~ ^data_managers.* ]]; then
              TESTPATH=$(planemo ci_find_tools "$DIR")
          else
              TESTPATH="$DIR"
          fi
          planemo test $PLANEMO_TEST_OPTIONS $PLANEMO_OPTIONS --test_output_json "$DIR"/test_output.json "$TESTPATH" || true
          docker system prune --all --force --volumes || true
      done < changed_repositories_chunk.list
  else
      echo '{"tests":[]}' > test_output.json
  fi
fi

if [ "$PLANEMO_COMBINE_OUTPUTS" == "true" ]; then
  find . -name test_output.json -exec sh -c 'planemo merge_test_reports "$@" test_output.json' sh {} +
  [ ! -d upload ] && mkdir upload
  mv test_output.json upload/
  [ "$PLANEMO_HTML_REPORT" == "true" ] && planemo test_reports upload/test_output.json --test_output upload/test_output.html
  [ "$PLANEMO_MD_REPORT" == "true" ] && planemo test_reports upload/test_output.json --test_output_markdown upload/test_output.md
fi

if [ "$PLANEMO_SHED_UPDATE" == "true" ]; then
   while read -r DIR; do
       planemo shed_update --shed_target "$SHED_TARGET" --shed_key "$SHED_KEY" --force_repository_creation "$DIR" || exit 1;
   done < changed_repositories.list
fi

if [ "$PLANEMO_WORKFLOW_UPLOAD" == "true" ]; then
   while read -r DIR; do
       planemo workflow_upload --namespace "$WORKFLOW_NAMESPACE" || exit 1;
   done < changed_repositories.list
fi
