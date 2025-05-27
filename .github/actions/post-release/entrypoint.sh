#!/bin/bash

# The following permissions are required to successfully execute this script:
# permissions:
#    issues: write # to close milestone (script will silently fail if not set)
#    contents: write # to commit

set_value_or_error() {
  local value="$1"
  local defaultValue="$2"
  local variableName="$3"
  local validValues="${4:-}"  # optional argument (if empty, skip validation)

  if [[ -z "$value" && -z "$defaultValue" ]]; then
    echo "ERROR: A value for $variableName is required." >&2
    exit 1
  fi

  if [[ -n "$value" ]]; then
    decidedValue="$value"
  else
    echo "${variableName}: Using default value: ${defaultValue}"
    decidedValue="$defaultValue"
  fi

  if [[ -n "$validValues" ]]; then
    local match=false
    local v
    for v in $validValues; do
      if [[ "$decidedValue" == "$v" ]]; then
        match=true
        break
      fi
    done

    if ! $match; then
      echo "ERROR: Invalid value for '$variableName': '$decidedValue'." >&2
      echo "       Must be one of: $validValues" >&2
      return 1
    fi
  fi

  eval "export $variableName=\"\$decidedValue\""
}

set -e

set_value_or_error "${GIT_USER_NAME}" "${GITHUB_ACTOR}" "GIT_USER_NAME"
set_value_or_error "${GITHUB_WORKSPACE}" "." "GIT_SAFE_DIR"

# for testing: git remote get-url origin | sed -E 's#(git@|https://)github.com[:/](.*).git#\2#'
set_value_or_error "${GITHUB_REPOSITORY}" "" "GITHUB_REPOSITORY"

set_value_or_error "${RELEASE_VERSION}" "${GITHUB_REF:11}" "RELEASE_VERSION"
if [[ ! "${RELEASE_VERSION}" =~ ^v?[^.]+\.[^.]+\.[^.]+$ ]]; then
  echo "ERROR: RELEASE_VERSION must be in the format 'X.X.X' or 'vX.X.X'. Got: '${RELEASE_VERSION}'"
  exit 1
fi
if [[ "${RELEASE_VERSION}" == v* ]]; then
  RELEASE_VERSION="${RELEASE_VERSION#v}"
else
  RELEASE_VERSION="${RELEASE_VERSION}"
fi
echo "Release Version: ${RELEASE_VERSION}"

echo -n "Determining next version: "
export NEXT_VERSION=`/increment_version.sh -p ${RELEASE_VERSION}`
echo "${NEXT_VERSION}"
echo "NEXT_VERSION=${NEXT_VERSION}" >> $GITHUB_OUTPUT

echo "Configuring git"
git config --global --add safe.directory "${GIT_SAFE_DIR}"
git config --global user.email "${GIT_USER_NAME}@users.noreply.github.com"
git config --global user.name "${GIT_USER_NAME}"
git fetch

echo -n "Determining target branch: "
set_value_or_error "${TARGET_BRANCH}" `cat $GITHUB_EVENT_PATH | jq '.release.target_commitish' | sed -e 's/^"\(.*\)"$/\1/g'` "TARGET_BRANCH"
echo "${TARGET_BRANCH}"
git checkout "${TARGET_BRANCH}"

set +e
echo -n "Retrieving current milestone number: "
milestone_number=`curl -s https://api.github.com/repos/${GITHUB_REPOSITORY}/milestones | jq -c ".[] | select (.title == \"${RELEASE_VERSION}\") | .number" | sed -e 's/"//g'`
echo $milestone_number
echo "Closing current milestone"
curl -s --request PATCH -H "Authorization: Bearer $1" -H "Content-Type: application/json" https://api.github.com/repos/${GITHUB_REPOSITORY}/milestones/$milestone_number --data '{"state":"closed"}'
set -e

echo "Setting new snapshot version"
sed -i "s/^projectVersion.*$/projectVersion\=${NEXT_VERSION}-SNAPSHOT/" gradle.properties
cat gradle.properties
echo "\n"
git add gradle.properties

if [[ -n "${RELEASE_SCRIPT_PATH}" && -x "${GITHUB_WORKSPACE}/${RELEASE_SCRIPT_PATH}" ]]; then
  echo "Executing additional release script at ${GITHUB_WORKSPACE}/${RELEASE_SCRIPT_PATH}"
  "${GITHUB_WORKSPACE}/${RELEASE_SCRIPT_PATH}"
else
  if [[ -n "${RELEASE_SCRIPT_PATH}" ]]; then
    echo "ERROR: RELEASE_SCRIPT_PATH is set to '${RELEASE_SCRIPT_PATH}' but is not executable or does not exist." >&2
    exit 1
  fi
fi

echo "Committing and pushing"
git commit -m "chore: Bump version to ${NEXT_VERSION}-SNAPSHOT"
git push origin "${TARGET_BRANCH}"

# Clean up .git artifacts we've created as root (so non-docker actions that follow can use git without re-cloning)
echo "Cleaning up artifacts with excessive permissions"
rm -f .git/COMMIT_EDITMSG

echo "Reverting repo changes so further actions will use the original versions, etc"
git reset --hard HEAD~1
