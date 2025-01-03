#!/bin/bash

# Check if a commit hash is provided
if [ -z "$1" ]; then
  echo "Usage: $0 <commit-hash>"
  exit 1
fi

COMMIT_HASH=$1

# Get the current author of the commit
CURRENT_AUTHOR=$(git log -1 --pretty=format:"%an" "$COMMIT_HASH")

# Get the list of modified files in the commit
MODIFIED_FILES=$(git diff-tree --no-commit-id --name-only -r "$COMMIT_HASH")

# Define the threshold for "refactor" and "help others" (3 weeks in seconds)
REFACTOR_THRESHOLD=$((3 * 7 * 24 * 60 * 60))
HELP_OTHERS_THRESHOLD=$((3 * 7 * 24 * 60 * 60))

for FILE in $MODIFIED_FILES; do
  echo "Analyzing file: $FILE"

  # Get the last modification author and date of the file before the current commit
  LAST_MODIFIED_INFO=$(git log -1 --pretty=format:"%an %ct" "$COMMIT_HASH^" -- "$FILE")
  LAST_MODIFIED_AUTHOR=$(echo "$LAST_MODIFIED_INFO" | awk '{print $1}')
  LAST_MODIFIED_DATE=$(echo "$LAST_MODIFIED_INFO" | awk '{print $2}')

  # Get the current commit date
  CURRENT_COMMIT_DATE=$(git log -1 --pretty=format:%ct "$COMMIT_HASH")

  # Calculate the time difference in seconds
  TIME_DIFFERENCE=$((CURRENT_COMMIT_DATE - LAST_MODIFIED_DATE))

  # Check if the file qualifies as "refactor"
  if [ "$TIME_DIFFERENCE" -gt "$REFACTOR_THRESHOLD" ]; then
    echo "Category: Refactor"
  else
    # If not "refactor", check if it qualifies as "help others"
    if [ "$LAST_MODIFIED_AUTHOR" != "$CURRENT_AUTHOR" ] && [ "$TIME_DIFFERENCE" -le "$HELP_OTHERS_THRESHOLD" ]; then
      echo "Category: Help Others"
    else
      # If not "help others", check if it qualifies as "new work"
      DIFF=$(git diff --unified=0 "$COMMIT_HASH^" "$COMMIT_HASH" -- "$FILE")
      if echo "$DIFF" | grep -q '^+[^+]' && ! echo "$DIFF" | grep -q '^-'; then
        echo "Category: New Work"
      else
        # If none of the above, categorize as "churn/rework"
        echo "Category: Churn/Rework"
      fi
    fi
  fi

  echo "------------------------"
done