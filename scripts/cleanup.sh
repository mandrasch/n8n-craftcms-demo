#!/bin/bash
MAX_AGE_HOURS=48

for dir in ~/preview-system/previews/*/; do
    [ -d "$dir" ] || continue
    branch=$(basename "$dir")
    age_hours=$(( ($(date +%s) - $(stat -c %Y "$dir")) / 3600 ))
    if [ "$age_hours" -gt "$MAX_AGE_HOURS" ]; then
        echo "Cleaning up stale preview: $branch (${age_hours}h old)"
        ~/preview-system/scripts/destroy.sh "$branch"
    fi
done
