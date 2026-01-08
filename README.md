Planemo CI action
=======================

Installs planemo, discovers changed workflows and tools, and allows to lint, test or deploy them.

The reference use cases of this action are the [pull request](https://github.com/galaxyproject/tools-iuc/blob/master/.github/workflows/pr.yaml) and [continuous integration](https://github.com/galaxyproject/tools-iuc/blob/master/.github/workflows/ci.yaml) workflows of the [intergalactic utility comission (IUC)](https://github.com/galaxyproject/tools-iuc/).


The action runs in one of six modes which are controled with the `mode` input. Possible values are:

- `setup`: This is the default. 
  - Optionally do a fake `planemo test` run to fill `.cache/pip`  and `.planemo` for caching.
  - Determine the relevant commit range. 
  - Determine the set of relevant repositories and tools.
  - Determine the number of chunks and the chunk list.
- `lint`: Lint tools with `planemo shed_lint` (resp. workflows with `planemo workflow_lint`) and check presence of repository metadata files (`.shed.yml`).
- `test`: Test tools or workflows with `planemo test`.
- `combine`: Combine the outputs from individual tool tests (`planemo merge_test_reports`) and create html/markdown reports (`planemo test_reports`).
- `check`: Check if any of the tool tests failed.
- `deploy`: Deploy tools to a toolshed using `planemo shed_update` and workflows to a github namespace, resp.

If none of these modes is set then a setup mode runs.

In all modes required software will be installed automatically, i.e. `planemo` and `jq`. 
The version of planemo can be controlled with the input `planemo-version` (default `"planemo"`, i.e. the latest version).

Assumptions
-----------

The action currently only works on github actions workflows using an Ubuntu image.

Assumptions on the repository
-----------------------------

Two files `.tt_skip` and `.tt_biocontainer_skip` containing paths (or prefixes of paths) can be used
to skip or modify the testing for tools.

Tools/workflows in a path that has a prefix in:

- `.tt_skip` are ignored in all modes
- `.tt_biocontainer_skip` are not tested using containers but conda is used for resolving requirements.

Tools and workflows are discovered in all directories, except for `packages/` and `deprecated/`. These directories may be absent.

A global `.lint_skip` file and per repo `.lint_skip` files can be used to list tool/workflow linters that should be skipped.

Setup mode
----------

This mode runs if no other mode is selected. It:

- runs `planemo test` on a mock tool (if `create-cache` is set to `true`)
- determines the relevant set of tool/workflow repositories and tools with `planemo ci_find_repos` and `planemo ci_find_tools`, respectively.
  - for push and pull_request events (using `GITHUB_EVENT_NAME`) tools and repositories that changed in the commit range
  - all tools and repositories otherwise

- calulates the number of chunks to use for tool testing and the
  list of chunks

Optional inputs: 

- `workflows`: look for workflows instead of tools
- `create-cache` (default `false`)
- `galaxy-branch` (default latest Galaxy release)
- `galaxy-source` (default `galaxyproject`)
- `max-chunks` (default `20`)
- `python-version` (default `"3.11"`)

Outputs:

- `commit-range`: The used commit range.
- `tool-list`: List of tools (empty if `workflows` is `true`).
- `repository-list` List of repositories.
- `chunk-count`: Number of chunks to use.
- `chunk-list`: List of chunks

Lint mode
---------

Calls `planemo shed_lint` for each repository and checks if each tool is in a repository (i.e. metadata like `.shed.yml` is present).

Required inputs:

- `repository-list` 
- `tool-list`

Optional inputs: 

- `report_level`: all|warn|error (default: all)
- `fail_level`: warn|error (default: error)
- `additional-planemo-options`: additional options passed to `planemo lint`. [Here](https://github.com/galaxyproject/planemo-ci-action/blob/b8ede8dc7767a86ac8bae582554d18ea00863259/.github/workflows/tools.yaml#L179) this is used to overwrite the warn level of `planemo lint`.
- `galaxy-branch`: Galaxy branch to test against (default: `master`). Used for Galaxy package installation when testing with non-master/main branches.
- `galaxy-fork`: Galaxy fork to test against (default: `galaxyproject`). Used for Galaxy package installation when testing with non-master/main branches.

Output:

- creates a file `lint_report.txt`

Test mode
---------

Runs `planemo test` for each tool in a chunk using `ci_find_tools`. Note that none of the tests
will produce a non-zero exit code even if the tests fail. Success needs to be checked with the
`check` mode after combining the outputs of the chunks.

Required inputs:

- `repository-list`: List of repositories
- `workflows`: test workflows
- `setup-cvmfs`: setup CVMFS (only useful for testing workflows)
- `chunk`: Current chunk
- `chunk-count`: Maximum chunk

Optional inputs: 

- `database_connection`
- `galaxy-branch`
- `galaxy-source`
- `python-version`
- `additional-planemo-options`: additional options passed to `planemo test`, see for instance [here](https://github.com/galaxyproject/planemo-ci-action/blob/657582777416fc51b6171961d90dced7dacbeea2/.github/workflows/tools.yaml#L229)
- `galaxy-slots`: number of slots (threads) to use in Galaxy jobs (sets the `GALAXY_SLOTS` environment variable)
- `test_timeout`:  Maximum runtime of a single test in seconds, default: 86400

Output:

The test mode creates a directory `upload/` containing the test results as json file.

Combine test outputs mode
-------------------------

Combines the test result of the chunked tests and create html or markdown reports.

Required input: 

- json files need to be placed in a directory `artifacts/`.

Optional inputs:

- `html-report` (default: `false`)
- `markdown-report` (default: `false`)

Output:

- `statistics`: (text) historam of the number of tests that passed, errored, failed, skipped.

A directory `upload/` containing the combined test results as json file and optionally as html/markdow files (named `tool_test_output.[json|html|md]`).

Test combined outputs mode
--------------------------

Check the combined outputs for failed test runs. If a failed test is found exit code 1 is returned.

Required input:

tool test results in `upload/tool_test_output.json`

Output:

`statistics`: Text containg the number of successful and failed tests

Deploy mode
-----------

Deploy all repositories to a toolshed.

Required inputs:

- `workflows`: deploy workflows to github namespace
- `workflow-namespace`
- `shed-target` toolshed name (e.g. `"toolshed"` or `"testtoolshed"`)
- `shed-key` API key for the toolshed
