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

# Function to determine commit category based on file categories
determine_commit_category() {
  local new_work_count=$1
  local refactor_count=$2
  local help_others_count=$3
  local churn_rework_count=$4

  # Priority order: Refactor > Help Others > New Work > Churn/Rework
  if [ "$refactor_count" -gt 0 ]; then
    echo "Refactor"
  elif [ "$help_others_count" -gt 0 ]; then
    echo "Help Others"
  elif [ "$new_work_count" -gt 0 ]; then
    echo "New Work"
  else
    echo "Churn/Rework"
  fi
}

# Iterate through each commit
for COMMIT_HASH in $COMMITS; do
  files_json="[]"
  total_insertions=0
  total_deletions=0
  new_work_count=0
  refactor_count=0
  help_others_count=0
  churn_rework_count=0

  # Get the current author name and email of the commit
  CURRENT_AUTHOR=$(git log -1 --pretty=format:"%an" "$COMMIT_HASH")
  CURRENT_AUTHOR_EMAIL=$(git log -1 --pretty=format:"%ae" "$COMMIT_HASH")

  # Get the current commit date
  CURRENT_COMMIT_DATE=$(git log -1 --pretty=format:%ct "$COMMIT_HASH")

  # Get the list of modified files in the commit
  MODIFIED_FILES=$(git diff-tree --no-commit-id --name-only -r "$COMMIT_HASH")

  for FILE in $MODIFIED_FILES; do
    # Get the last modification author and date of the file before the current commit
    LAST_MODIFIED_INFO=$(git log -1 --pretty=format:"%an %ct" "$COMMIT_HASH^" -- "$FILE" 2>/dev/null)
    if [ -z "$LAST_MODIFIED_INFO" ]; then
      # If the file has no history before this commit, it's "new work"
      CATEGORY="New Work"
      new_work_count=$((new_work_count + 1))
    else
      # Extract the last modification author and date
      LAST_MODIFIED_AUTHOR=$(echo "$LAST_MODIFIED_INFO" | awk '{$NF=""; print $0}' | sed 's/ *$//')
      LAST_MODIFIED_DATE=$(echo "$LAST_MODIFIED_INFO" | awk '{print $NF}')

      # Calculate the time difference in seconds
      TIME_DIFFERENCE=$((CURRENT_COMMIT_DATE - LAST_MODIFIED_DATE))

      # Get insertions and deletions for the file
      STATS=$(git diff --numstat "$COMMIT_HASH^" "$COMMIT_HASH" -- "$FILE")
      INSERTIONS=$(echo "$STATS" | awk '{print $1}')
      DELETIONS=$(echo "$STATS" | awk '{print $2}')

      # Check if the file qualifies as "refactor"
      if [ "$TIME_DIFFERENCE" -gt "$REFACTOR_THRESHOLD" ]; then
        # Additional criterion: Total additions and deletions must be greater than 10
        TOTAL_CHANGES=$((INSERTIONS + DELETIONS))
        if [ "$TOTAL_CHANGES" -gt 10 ]; then
          CATEGORY="Refactor"
          refactor_count=$((refactor_count + 1))
        else
          CATEGORY="Churn/Rework"
          churn_rework_count=$((churn_rework_count + 1))
        fi
      else
        # If not "refactor", check if it qualifies as "help others"
        if [ "$LAST_MODIFIED_AUTHOR" != "$CURRENT_AUTHOR" ] && [ "$TIME_DIFFERENCE" -le "$HELP_OTHERS_THRESHOLD" ]; then
          CATEGORY="Help Others"
          help_others_count=$((help_others_count + 1))
        else
          # If not "help others", check if it qualifies as "new work"
          DIFF=$(git diff --unified=0 "$COMMIT_HASH^" "$COMMIT_HASH" -- "$FILE")
          if echo "$DIFF" | grep -q '^+[^+]' && ! echo "$DIFF" | grep -q '^-'; then
            CATEGORY="New Work"
            new_work_count=$((new_work_count + 1))
          else
            # If none of the above, categorize as "churn/rework"
            CATEGORY="Churn/Rework"
            churn_rework_count=$((churn_rework_count + 1))
          fi
        fi
      fi
    fi

    # Add to total insertions and deletions for the commit
    total_insertions=$((total_insertions + INSERTIONS))
    total_deletions=$((total_deletions + DELETIONS))

    # Add file details to JSON
    file_json=$(jq -n \
      --arg file "$FILE" \
      --arg category "$CATEGORY" \
      --argjson insertions "$INSERTIONS" \
      --argjson deletions "$DELETIONS" \
      '{file: $file, category: $category, insertions: $insertions, deletions: $deletions}')
    files_json=$(echo "$files_json" | jq --argjson file "$file_json" '. += [$file]')
  done

  # Determine commit category
  commit_category=$(determine_commit_category "$new_work_count" "$refactor_count" "$help_others_count" "$churn_rework_count")

  # Add commit details to JSON
  commit_json=$(jq -n \
    --arg hash "$COMMIT_HASH" \
    --arg author "$CURRENT_AUTHOR" \
    --arg email "$CURRENT_AUTHOR_EMAIL" \
    --arg date "$CURRENT_COMMIT_DATE" \
    --argjson total_insertions "$total_insertions" \
    --argjson total_deletions "$total_deletions" \
    --arg category "$commit_category" \
    --argjson files "$files_json" \
    '{hash: $hash, author: $author, email: $email, commit_date: $date, total_insertions: $total_insertions, total_deletions: $total_deletions, category: $category, files: $files}')

  output=$(echo "$output" | jq --argjson commit "$commit_json" '.commits += [$commit]')
done

# Add total commits processed to JSON
total_commits=$(echo "$output" | jq '.commits | length')
output=$(echo "$output" | jq --argjson total "$total_commits" '.total_commits_processed = $total')

# Output the JSON
echo "$output" | jq .
