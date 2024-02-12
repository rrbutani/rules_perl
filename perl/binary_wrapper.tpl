#!/bin/sh

# NOTE: `PATH_PREFIX` corresponds to the main workspace's directory under the
# runfiles tree for this target.
#
# This is the directory `.short_path` should be relative to.

# TODO: what is the $(dirname)/../../MANIFEST thing about?
#  - why go up three dirs?

if [ -n "${RUNFILES_DIR+x}" ]; then
  PATH_PREFIX=$RUNFILES_DIR/{main_workspace_name}/
elif [ -s `dirname $0`/../../MANIFEST ]; then
  PATH_PREFIX=`cd $(dirname $0); pwd`/
elif [ -d $0.runfiles ]; then
  PATH_PREFIX=`cd $0.runfiles; pwd`/{main_workspace_name}/
else
  echo "WARNING: it does not look to be at the .runfiles directory" >&2
  exit 1
fi

INCLUDES=(
  {includes}
)

{env_vars} "$PATH_PREFIX{interpreter}" "${INCLUDES[@]}" "${PATH_PREFIX}{main}" "$@"
