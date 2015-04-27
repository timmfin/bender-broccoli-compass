#!/bin/sh

find . -iname '*.coffee' | sed 's/\.coffee$/.js/' | xargs rm -f
