#!/bin/bash

# Default duration (in seconds)
DURATION=${1:-20}
URL="http://abc.com/value"

echo "Fetching values from $URL every second for $DURATION seconds..."
sum=0
count=0

for ((i=1; i<=DURATION; i++)); do
    value=$(curl -s "$URL" | tr -dc '0-9.\n')  # extract numeric value
    if [[ -n "$value" ]]; then
        sum=$(echo "$sum + $value" | bc)
        ((count++))
        echo "[$i] Value: $value"
    else
        echo "[$i] No numeric value found"
    fi
    sleep 1
done

if ((count > 0)); then
    avg=$(echo "scale=4; $sum / $count" | bc)
    echo "---------------------------------"
    echo "Average value over $count seconds: $avg"
else
    echo "No valid values collected."
fi
