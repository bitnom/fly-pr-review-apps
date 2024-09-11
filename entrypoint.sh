#!/usr/bin/env bash

# Exit immediately if a command exits with a non-zero status.
# Print commands and their arguments as they are executed.
set -ex

# Change to the specified directory if INPUT_PATH is provided
if [ -n "$INPUT_PATH" ]; then
  cd "$INPUT_PATH" || exit
fi

# Extract the PR number from the GitHub event JSON
PR_NUMBER=$(jq -r .number /github/workflow/event.json)
if [ -z "$PR_NUMBER" ]; then
  echo "This action only supports pull_request actions."
  exit 1
fi

# Check the flyctl version
flyctl version

# Extract repository name and event type from the GitHub event JSON
REPO_NAME=$(jq -r .repository.name /github/workflow/event.json)
EVENT_TYPE=$(jq -r .action /github/workflow/event.json)

# Set up variables with default values
app="${INPUT_NAME:-$REPO_NAME-pr-$PR_NUMBER}"
postgres_app="${INPUT_POSTGRES:-$REPO_NAME-pr-$PR_NUMBER-postgres}"
region="${INPUT_REGION:-${FLY_REGION:-ord}}"
org="${INPUT_ORG:-${FLY_ORG:-personal}}"
dockerfile="$INPUT_DOCKERFILE"

# Set detach flag based on INPUT_WAIT
detach=""
[ "$INPUT_WAIT" != "true" ] && detach="--detach"

# Safety check: ensure app name contains PR number
if ! echo "$app" | grep "$PR_NUMBER"; then
  echo "For safety, this action requires the app's name to contain the PR number."
  exit 1
fi

# If PR is closed, destroy the app and exit
if [ "$EVENT_TYPE" = "closed" ]; then
  flyctl apps destroy "$app" -y || true
  echo "message=Review app deleted." >> $GITHUB_OUTPUT
  exit 0
fi

# Initialize the command array
build_cmd=(flyctl launch --no-deploy --copy-config --name "$app" --dockerfile "$dockerfile" --regions "$region" --org "$org")

# Add --ha flag with the correct value
if [ "$INPUT_HA" = "true" ]; then
  ha_flag="--ha=true"
else
  ha_flag="--ha=false"
fi

build_cmd+=("$ha_flag")

# Check if the app already exists
if ! flyctl status --app "$app"; then
  # Add build arguments if provided
  if [ -n "$INPUT_BUILD_ARGS" ]; then
    while IFS= read -r arg; do
      build_cmd+=(--build-arg "$arg")
    done <<< "$INPUT_BUILD_ARGS"
  fi

  # Execute the build command
  "${build_cmd[@]}"

  # Attach postgres cluster
  flyctl postgres attach "$postgres_app" --app "$app"

  # Prepare deploy command
  deploy_cmd=(flyctl deploy --app "$app" --regions "$region" --strategy immediate --remote-only "$ha_flag")
  [ -n "$detach" ] && deploy_cmd+=("$detach")

  # Add build arguments to deploy command if provided
  if [ -n "$INPUT_BUILD_ARGS" ]; then
    while IFS= read -r arg; do
      deploy_cmd+=(--build-arg "$arg")
    done <<< "$INPUT_BUILD_ARGS"
  fi

  # Execute the deploy command
  "${deploy_cmd[@]}"

  statusmessage="Review app created. It may take a few minutes for the app to deploy."
elif [ "$EVENT_TYPE" = "synchronize" ]; then
  # App exists and PR was updated, so we need to redeploy
  deploy_cmd=(flyctl deploy --app "$app" --regions "$region" --strategy immediate --remote-only "$ha_flag")
  [ -n "$detach" ] && deploy_cmd+=("$detach")

  # Add build arguments to deploy command if provided
  if [ -n "$INPUT_BUILD_ARGS" ]; then
    while IFS= read -r arg; do
      deploy_cmd+=(--build-arg "$arg")
    done <<< "$INPUT_BUILD_ARGS"
  fi

  # Execute the deploy command
  "${deploy_cmd[@]}"

  statusmessage="Review app updated. It may take a few minutes for your changes to be deployed."
fi

# Get the app status and extract relevant information
flyctl status --app "$app" --json >status.json
hostname=$(jq -r .Hostname status.json)
appid=$(jq -r .ID status.json)

# Output relevant information for use in GitHub Actions
echo "hostname=$hostname" >> $GITHUB_OUTPUT
echo "url=https://$hostname" >> $GITHUB_OUTPUT
echo "id=$appid" >> $GITHUB_OUTPUT
echo "name=$app" >> $GITHUB_OUTPUT
echo "message=$statusmessage" >> $GITHUB_OUTPUT
