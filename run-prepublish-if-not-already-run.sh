#!/bin/sh

# Run the prepublish step if hasn't already been run. This is necessary because
# doing an npm install for a dependency with a Git url _does not_ run prepublish.
# And without this, installs from a Git url would never transpile our CoffeeScript files.
#
# More info in https://github.com/npm/npm/issues/3055

SCRIPT_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )

# Only prepublish if the lib/ dir is missing (since it is .gitignore-ed)
if ! [ -f "$SCRIPT_DIR/index.js" ]; then
  echo "Building CoffeeScript files because prepublish was never run (installed from a Git url?)"
  npm run prepublish
fi
