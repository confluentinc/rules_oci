#!/usr/bin/env bash
set -o pipefail -o errexit -o nounset

readonly CRANE="{{crane_path}}"
readonly JQ="{{jq_path}}"
readonly IMAGE_DIR="{{image_dir}}"
readonly TAGS_FILE="{{tags}}"
readonly FIXED_ARGS=({{fixed_args}})
readonly REPOSITORY_FILE="{{repository_file}}"
readonly APPEND_ARCHITECTURE_TAG="{{append_architecture_tag}}"

VERBOSE=""

REPOSITORY=""
if [ -f $REPOSITORY_FILE ] ; then
  REPOSITORY=$(tr -d '\n' < "$REPOSITORY_FILE")
fi

# set $@ to be FIXED_ARGS+$@
ALL_ARGS=(${FIXED_ARGS[@]+"${FIXED_ARGS[@]}"} $@)
if [[ ${#ALL_ARGS[@]} -gt 0 ]]; then
  set -- ${ALL_ARGS[@]}
fi

TAGS=()
ARGS=()

while (( $# > 0 )); do
  case $1 in
    (-v|--verbose)
      VERBOSE="--verbose"
      shift;;
    (-t|--tag)
      TAGS+=( "$2" )
      shift
      shift;;
    (--tag=*) 
      TAGS+=( "${1#--tag=}" )
      shift;;
    (-r|--repository)
      REPOSITORY="$2"
      shift
      shift;;
    (--repository=*)
      REPOSITORY="${1#--repository=}"
      shift;;
    (*) 
      ARGS+=( "$1" )
      shift;;
  esac
done

# Digest of index.json points to a file in blobs directory
# that contains the manifest of the image or index
DIGEST=$("${JQ}" -r '.manifests[0].digest' "${IMAGE_DIR}/index.json")

# Push the image and write the image reference to REFS
REFS=$(mktemp)
"${CRANE}" push ${VERBOSE} "${IMAGE_DIR}" "${REPOSITORY}@${DIGEST}" "${ARGS[@]+"${ARGS[@]}"}" --image-refs "${REFS}"

# Get the actual manifest json
BLOB_FILE="${IMAGE_DIR}/blobs/sha256/${DIGEST#sha256:}"

# If the blob file contains 'manifests', then it is an index and we want to tag each image in the index
if "${JQ}" -e '.manifests' "${BLOB_FILE}" > /dev/null && [ "${APPEND_ARCHITECTURE_TAG}" = "True" ]; then
  manifests=$("${JQ}" -c '.manifests[]' "${BLOB_FILE}")
  for manifest in $manifests; do
    digest=$(echo "$manifest" | "${JQ}" -r '.digest')
    architecture=$(echo "$manifest" | "${JQ}" -r '.platform.architecture')
    for tag in "${TAGS[@]+"${TAGS[@]}"}"; do
      "${CRANE}" tag ${VERBOSE} "${REPOSITORY}@${digest}" "${tag}-${architecture}"
    done

    if [[ -e "${TAGS_FILE:-}" ]]; then
      xargs -r -n1 -I {} "${CRANE}" tag ${VERBOSE} $(cat "${REFS}") "{}-${architecture}" < "${TAGS_FILE}"
    fi
  done
fi

for tag in "${TAGS[@]+"${TAGS[@]}"}"; do
  "${CRANE}" tag ${VERBOSE} $(cat "${REFS}") "${tag}"
done

if [[ -e "${TAGS_FILE:-}" ]]; then
  xargs -r -n1 "${CRANE}" tag ${VERBOSE} $(cat "${REFS}") < "${TAGS_FILE}"
fi
