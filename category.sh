#!/bin/bash

# Initialize JSON output
output="{\"total_commits_processed\": 0, \"commits\": []}"

# Define the threshold for "refactor" and "help others" (3 weeks in seconds)
REFACTOR_THRESHOLD=$((3 * 7 * 24 * 60 * 60))
HELP_OTHERS_THRESHOLD=$((3 * 7 * 24 * 60 * 60))

# Get the list of commits in the last 24 hours
COMMITS=$(git log --since="1 week ago" --pretty=format:"%H")

# Check if there are any commits in the last 24 hours
if [ -z "$COMMITS" ]; then
  echo "No commits found in the last week."
  exit 0
fi

# Iterate through each commit
for COMMIT_HASH in $COMMITS; do
  
  files_json="[]"
  #echo "Analyzing commit: $COMMIT_HASH"

  # Get the current author name and email of the commit
  CURRENT_AUTHOR=$(git log -1 --pretty=format:"%an" "$COMMIT_HASH")
  CURRENT_AUTHOR_EMAIL=$(git log -1 --pretty=format:"%ae" "$COMMIT_HASH")

  # Print the author name and email
  #echo "  Author: $CURRENT_AUTHOR <$CURRENT_AUTHOR_EMAIL>"

  # Get the list of modified files in the commit
  MODIFIED_FILES=$(git diff-tree --no-commit-id --name-only -r "$COMMIT_HASH")

  for FILE in $MODIFIED_FILES; do
    #echo "  Analyzing file: $FILE"
    # Get the last modification author and date of the file before the current commit
    LAST_MODIFIED_INFO=$(git log -1 --pretty=format:"%an %ct" "$COMMIT_HASH^" -- "$FILE" 2>/dev/null)
    if [ -z "$LAST_MODIFIED_INFO" ]; then
      # If the file has no history before this commit, it's "new work"
      #echo "    Category: New Work"
      CATEGORY="New Work"
      continue
    fi

    # Extract the last modification author and date
    LAST_MODIFIED_AUTHOR=$(echo "$LAST_MODIFIED_INFO" | awk '{$NF=""; print $0}' | sed 's/ *$//')
    LAST_MODIFIED_DATE=$(echo "$LAST_MODIFIED_INFO" | awk '{print $NF}')
    # Get the current commit date
    CURRENT_COMMIT_DATE=$(git log -1 --pretty=format:%ct "$COMMIT_HASH")
    # Calculate the time difference in seconds
    TIME_DIFFERENCE=$((CURRENT_COMMIT_DATE - LAST_MODIFIED_DATE))

    # Check if the file qualifies as "refactor"
    if [ "$TIME_DIFFERENCE" -gt "$REFACTOR_THRESHOLD" ]; then
      #echo "    Category: Refactor"
      CATEGORY="Refactor"
    else
      # If not "refactor", check if it qualifies as "help others"
      if [ "$LAST_MODIFIED_AUTHOR" != "$CURRENT_AUTHOR" ] && [ "$TIME_DIFFERENCE" -le "$HELP_OTHERS_THRESHOLD" ]; then
        #echo "    Category: Help Others"
        CATEGORY="Help Others"
      else
        # If not "help others", check if it qualifies as "new work"
        DIFF=$(git diff --unified=0 "$COMMIT_HASH^" "$COMMIT_HASH" -- "$FILE")
        if echo "$DIFF" | grep -q '^+[^+]' && ! echo "$DIFF" | grep -q '^-'; then
          #echo "    Category: New Work"
          CATEGORY="New Work"
        else
          # If none of the above, categorize as "churn/rework"
          #echo "    Category: Churn/Rework"
          CATEGORY="Churn/Rework"
        fi
      fi
    fi

    # Add file details to JSON
    file_json="{\"file\": \"$FILE\", \"category\": \"$CATEGORY\"}"
    files_json=$(echo "$files_json" | jq --argjson file "$file_json" '. += [$file]')
    
  done
  #echo "------------------------"
  # Add commit details to JSON
  commit_json=$(jq -n \
      --arg hash "$COMMIT_HASH" \
      --arg author "$CURRENT_AUTHOR" \
      --arg email "$CURRENT_AUTHOR_EMAIL" \
      --arg date "$CURRENT_COMMIT_DATE" \
      --argjson files "$files_json" \
      '{hash: $hash, author: $author, email: $email, commit_date: $date, files: $files}')

  output=$(echo "$output" | jq --argjson commit "$commit_json" '.commits += [$commit]')
done

# Add total commits processed to JSON
total_commits=$(echo "$output" | jq '.commits | length')
output=$(echo "$output" | jq --argjson total "$total_commits" '.total_commits_processed = $total')

# Output the JSON
echo "$output" | jq .