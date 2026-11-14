#!/bin/bash
# PC only (WSL, root). Stops any running lab experiment and removes the lab's namespaces.
pkill -f 'tests/lab/e[0-9]' 2>/dev/null
sleep 1
. "$(dirname "$0")/lab.sh"
lab_down
echo "lab stopped; namespaces left: $(ip netns list | grep -c ztl-)"
