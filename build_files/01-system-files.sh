#!/bin/bash
# system_files/ into the image -- after 00-pre-build.sh's package removal.
set -ouex pipefail

cp -avf /ctx/system_files/. /
