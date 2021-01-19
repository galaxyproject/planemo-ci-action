Planemo discover action
=======================

Installs planemo and discovers changed workflows and tools to test.

The action runs in one of six modes which are controled with the following
boolean inputs:

- `lint-tools`: Lint tools with `planemo shed_lint` and check presence of repository metadata files (`.shed.yml`).
- `test-tools`: Test tools with `planemo test`.
- `combine-outputs`: Combine the outputs from individual tool tests (`planemo merge_test_reports`) and create html/markdown reports (`planemo test_reports`).
- `check-outputs`: Check if any of the tests failed.
- `deploy-tool`: Deploy tools to a toolshed using `planemo shed_update`.

If none of these inputs is set then a setup mode runs.

In all modes required software will be installed automatically, i.e. `planemo` and `jq`. 
The version of planemo can be controlled with the input `planemo-version` (default `"planemo"`).

Assumptions on the repository
-----------------------------

Two files `.tt_skip` and `.tt_biocontainer_skip` must be present. They may contain path (or prefixes of paths). 
Tools in a path that has a prefix in:


- `.tt_skip` are ignored in all modes
- `.tt_biocontainer_skip` are not tested using containers but conda is used for resolving requirements.

Tools and tool repositories are discovered in all directories, except for `packages/` and `deprecated/`. These directories may be absent.



Setup mode
----------

This mode runs if no other mode is selected. It:

- runs `planemo test` on a mock tool (if `create-cache` is set to true)
- determines the relevant set or repositories and tools with `planemo ci_find_repos` and `planemo ci_find_tools`, respectively.
  - for push and pull_request events (using `GITHUB_EVENT_NAME`) tools and repos that changed in the commit range
  - all tools and repos otherwise
- calulates the number of chunks to use for tool testing and the
  list of chunks

Optional inputs: 

- `create-cache` (default `false`)
- `galaxy-branch` (default latest Galaxy release)
- `galaxy-source` (default `galaxyproject`)
- `max-chunks` (default `20`)
- `python-version` (default `"3.7"`)

Outputs:

- `commit-range`: The used commit range.
- `tools`: List of tools.
- `repositories` List of repositories.
- `chunk-count`: Number of chunks to use.
- `chunk-list`: List of chunks

Lint mode
---------

Calls `planemo shed_lint` for each repository and checks if each tool is in a repository (i.e. metadata like `.shed.yml` is present).

Inputs (all of them required):

- `repositories` 
- `tools`

Test mode
---------

Runs `planemo test` for each tool in a chunk using `ci_find_tools`. Note that none of the tests
will produce a non-zero exit code even if the tests fail. Success needs to be checked with the
"check outputs" mode after combining the outputs of the chunks.

Inputs:

- `repositories`: List of repositories
- `chunk`: Current chunk
- `chunk-count`: Maximum chunk

Optional inputs: 

- `database_connection`
- `galaxy-branch`
- `galaxy-source`
- `python-version`

Output:

The test mode creates a directory `upload/` containing the test results as json file.

Combine test outputs mode
-------------------------

Combines the test result of the chunked tests and create html or markdown reports.

Input: 

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

Input:

`upload/tool_test_output.json`

Output:

`statistics`: Text containg the number of successful and failed tests

Deploy mode
-----------

Deploy all repositories to a toolshed.

Inputs:

- `shed-target` toolshed name (e.g. `"toolshed"` or `"testtoolshed"`)
- `shed-key` API key for the toolshed