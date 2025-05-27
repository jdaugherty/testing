#!/bin/bash

# The following permissions are required to successfully execute this script:
# permissions:
#   contents: write // tags / commits

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

  # Export the variable so all variables are available in third party scripts
  eval "export $variableName=\"\$decidedValue\""
}

set -e

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

set_value_or_error "${RELEASE_URL}" `cat $GITHUB_EVENT_PATH | jq '.release.url' | sed -e 's/^"\(.*\)"$/\1/g'` "RELEASE_URL"

set_value_or_error "${GIT_USER_NAME}" "${GITHUB_ACTOR}" "GIT_USER_NAME"

set_value_or_error "${GITHUB_WORKSPACE}" "." "GIT_SAFE_DIR"

echo "Configuring git"
git config --global --add safe.directory "${GIT_SAFE_DIR}"
git config --global user.email "${GIT_USER_NAME}@users.noreply.github.com"
git config --global user.name "${GIT_USER_NAME}"
git fetch

echo -n "Determining target branch: "
set_value_or_error "${TARGET_BRANCH}" `cat $GITHUB_EVENT_PATH | jq '.release.target_commitish' | sed -e 's/^"\(.*\)"$/\1/g'` "TARGET_BRANCH"
echo "${TARGET_BRANCH}"
git checkout "${TARGET_BRANCH}"

echo "Setting release version in gradle.properties"
sed -i "s/^projectVersion.*$/projectVersion\=${RELEASE_VERSION}/" gradle.properties
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

echo "Pushing release version and recreating v${RELEASE_VERSION} tag"
git commit -m "[skip ci] Release v${RELEASE_VERSION}"
git push origin "${TARGET_BRANCH}"
git tag -fa v${RELEASE_VERSION} -m "Release v${RELEASE_VERSION}"
git push origin "${TARGET_BRANCH}"
# force push the updated tag
git push origin "v${RELEASE_VERSION}" --force

echo "Closing the release after updating the tag: ${RELEASE_URL}"
curl -s --request PATCH -H "Authorization: Bearer $1" -H "Content-Type: application/json" "${RELEASE_URL}" --data "{\"draft\": false}"
