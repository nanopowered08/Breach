# Open Cloud map-load smoke test

This workflow runs the Roblox adapter's mission initialization and map renderer in a headless Open Cloud Luau task. It is deliberately **manual-only**: it has a \`workflow_dispatch\` trigger and does not run on pushes or pull requests.

## GitHub configuration

Add these repository secrets:

- \`ROBLOX_API_KEY\`: an Open Cloud API key scoped to the test universe/place with permission to create Luau execution session tasks.
- \`ROBLOX_UNIVERSE_ID\`: the numeric universe ID.
- \`ROBLOX_PLACE_ID\`: the numeric place ID.

Add this repository variable:

- \`MISSION_GIST_URL\`: the HTTPS raw \`gist.githubusercontent.com\` URL for the mission source. The workflow downloads it on the GitHub runner; mission data is not committed to this repository or printed in logs.

The API key must be allowed to create Luau execution session tasks for the selected place. The place should be published and configured for the loader's HTTP and \`loadstring\` requirements.

## Running it

1. Open **Actions** in the repository.
2. Select **Open Cloud map-load smoke test**.
3. Choose **Run workflow** and the branch/commit to test.
4. Inspect the task output and Roblox logs in the workflow run.

The runner pins the loader and every fetched engine module to the exact commit SHA selected by the workflow. It uploads the downloaded mission as an Open Cloud binary input rather than embedding mission text in the task script.

## What it checks

- The loader can be fetched at the selected commit.
- The adapter can initialize the mission from the supplied mission source.
- The Geometry and Barrier parts finish rendering in Workspace.
- The task returns the map ID, rendered/expected part counts, bot count, and engine version.

Props and lighting are intentionally disabled so the smoke test does not depend on optional \`ReplicatedStorage.Assets\` content.

This is a map-load smoke test, not a full gameplay test. Open Cloud does not automatically run scripts placed in the DataModel, and the task's DataModel changes are temporary. The test explicitly invokes the loader and adapter, then checks the generated map before the task exits.

## Limits and safety

- The task uses Roblox Open Cloud Luau execution's 300-second maximum timeout.
- The mission source remains external and is only held by the runner and the temporary task input.
- Do not add mission source, API keys, or other credentials to Git.
- The workflow is not triggered automatically. Do not enable push/PR triggers unless that behavior is intentionally changed.
