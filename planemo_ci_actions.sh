#!/usr/bin/env bash
set -ex

if [ "$CREATE_CACHE" != "false" ]; then
  tmp_dir=$(mktemp -d)
  touch "$tmp_dir/tool.xml"
  PIP_QUIET=1 planemo test --no_conda_auto_init --galaxy_source "$GALAXY_SOURCE" --galaxy_branch "$GALAXY_BRANCH" "$tmp_dir"
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

if [ "$PLANEMO_TEST_TOOLS" == "true" ]; then
  # Find tools
  touch changed_repositories_chunk.list changed_tools_chunk.list
  if [ $(wc -l < changed_repositories.list) -eq 1 ]; then
      planemo ci_find_tools --chunk_count "$CHUNK_COUNT" --chunk "$CHUNK" \
                     --output changed_tools_chunk.list \
                     $(cat changed_repositories.list)
  else
      planemo ci_find_repos --chunk_count "$CHUNK_COUNT" --chunk "$CHUNK" \
                     --output changed_repositories_chunk.list \
                     $(cat changed_repositories.list)
  fi

  # show tools
  cat changed_tools_chunk.list changed_repositories_chunk.list
  # test tools
  if grep -lqf .tt_biocontainer_skip changed_tools_chunk.list changed_repositories_chunk.list; then
          PLANEMO_OPTIONS=""
  else
          PLANEMO_OPTIONS="--biocontainers --no_dependency_resolution --no_conda_auto_init"
  fi
  if [ -s changed_tools_chunk.list ]; then
      PIP_QUIET=1 planemo test --database_connection "$DATABASE_CONNECTION" $PLANEMO_OPTIONS --galaxy_source $GALAXY_REPO --galaxy_branch $GALAXY_RELEASE --test_output_json test_output.json $(cat changed_tools_chunk.list) || true
      docker system prune --all --force --volumes || true
  elif [ -s changed_repositories_chunk.list ]; then
      while read -r DIR; do
          if [[ "$DIR" =~ ^data_managers.* ]]; then
              TESTPATH=$(planemo ci_find_tools "$DIR")
          else
              TESTPATH="$DIR"
          fi
          PIP_QUIET=1 planemo test --database_connection "$DATABASE_CONNECTION" $PLANEMO_OPTIONS --galaxy_source $GALAXY_REPO --galaxy_branch $GALAXY_RELEASE --test_output_json "$DIR"/test_output.json "$TESTPATH" || true
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

if [ "$PLANEMO_DEPLOY" == "true" ]; then
   while read -r DIR; do
       planemo shed_update --shed_target "$SHED_TARGET" --shed_key "$SHED_KEY" --force_repository_creation "$DIR" || exit 1;
   done < changed_repositories.list
fi
