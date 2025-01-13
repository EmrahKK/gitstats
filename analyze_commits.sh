#!/bin/bash

# Initialize JSON output
output="{\"total_commits_processed\": 0, \"commits\": []}"

# Define the threshold for "refactor" and "help others" (3 weeks in seconds)
REFACTOR_THRESHOLD=$((3 * 7 * 24 * 60 * 60))
HELP_OTHERS_THRESHOLD=$((3 * 7 * 24 * 60 * 60))

# Parse command-line arguments for time range
SINCE="1 week ago"  # Default value
UNTIL="now"         # Default value

while [[ $# -gt 0 ]]; do
  case "$1" in
    --since)
      SINCE="$2"
      shift 2
      ;;
    --until)
      UNTIL="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1"
      exit 1
      ;;
  esac
done

# Get the list of commits within the specified time range
COMMITS=$(git log --since="$SINCE" --until="$UNTIL" --pretty=format:"%H")

# Check if there are any commits in the specified time range
if [ -z "$COMMITS" ]; then
  echo "No commits found in the specified time range."
  exit 0
fi

# Function to determine commit category based on weighted file categories
determine_commit_category() {
  local new_work_count=$1
  local refactor_count=$2
  local help_others_count=$3
  local churn_rework_count=$4

  # Apply integer weights to each category
  new_work_weighted=$((new_work_count * 6))
  refactor_weighted=$((refactor_count * 8))
  help_others_weighted=$((help_others_count * 5))
  churn_rework_weighted=$((churn_rework_count * 4))

  # Create an associative array to store weighted sums
  declare -A weighted_sums
  weighted_sums["New Work"]=$new_work_weighted
  weighted_sums["Refactor"]=$refactor_weighted
  weighted_sums["Help Others"]=$help_others_weighted
  weighted_sums["Churn/Rework"]=$churn_rework_weighted

  # Find the category with the highest weighted sum
  max_category=""
  max_value=-1
  for category in "${!weighted_sums[@]}"; do
    value=${weighted_sums[$category]}
    if (( value > max_value )); then
      max_value=$value
      max_category=$category
    elif (( value == max_value )); then
      # If weighted sums are equal, use priority order
      if [[ "$category" == "Refactor" && ("$max_category" == "New Work" || "$max_category" == "Help Others" || "$max_category" == "Churn/Rework") ]]; then
        max_category=$category
      elif [[ "$category" == "New Work" && ("$max_category" == "Help Others" || "$max_category" == "Churn/Rework") ]]; then
        max_category=$category
      elif [[ "$category" == "Help Others" && "$max_category" == "Churn/Rework" ]]; then
        max_category=$category
      fi
    fi
  done

  echo "$max_category"
}

# Function to get modified files for a commit
get_modified_files() {
  local commit_hash=$1
  local parent_hashes=$2

  # If it's a merge commit, compare against all parents
  if [ $(echo "$parent_hashes" | wc -w) -ge 2 ]; then
    # Use `git diff-tree -m` to split the merge commit into individual diffs
    git diff-tree -m --no-commit-id --name-only -r "$commit_hash"^1 "$commit_hash"
  else
    # For non-merge commits, use the standard approach
    git diff-tree --no-commit-id --name-only -r "$commit_hash"
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

  # Get the current commit date (Unix timestamp)
  CURRENT_COMMIT_DATE=$(git log -1 --pretty=format:%ct "$COMMIT_HASH")

  # Convert Unix timestamp to human-readable format
  COMMIT_DATE_HR=$(date -d "@$CURRENT_COMMIT_DATE" "+%Y-%m-%d %H:%M:%S")

  # Get the commit message (comments)
  COMMIT_MESSAGE=$(git log -1 --pretty=format:"%s" "$COMMIT_HASH")

  # Get the parent commit hashes
  PARENT_COMMIT_HASHES=$(git log -1 --pretty=format:"%P" "$COMMIT_HASH")

  # Get the list of modified files in the commit
  MODIFIED_FILES=$(get_modified_files "$COMMIT_HASH" "$PARENT_COMMIT_HASHES")
  TOTAL_FILES_CHANGED=$(echo "$MODIFIED_FILES" | wc -l)

  # If there are no modified files, categorize the commit as "Churn/Rework"
  if [ "$TOTAL_FILES_CHANGED" -eq 0 ]; then
    commit_category="Churn/Rework"
  else
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

    # Calculate average insertions and deletions per file
    if [ "$TOTAL_FILES_CHANGED" -gt 0 ]; then
      avg_insertions=$(echo "scale=2; $total_insertions / $TOTAL_FILES_CHANGED" | bc)
      avg_deletions=$(echo "scale=2; $total_deletions / $TOTAL_FILES_CHANGED" | bc)
    else
      avg_insertions=0
      avg_deletions=0
    fi

    # Determine commit category based on weighted file categories
    commit_category=$(determine_commit_category "$new_work_count" "$refactor_count" "$help_others_count" "$churn_rework_count")
  fi

  # Add commit details to JSON
  commit_json=$(jq -n \
    --arg hash "$COMMIT_HASH" \
    --arg author "$CURRENT_AUTHOR" \
    --arg email "$CURRENT_AUTHOR_EMAIL" \
    --arg date "$CURRENT_COMMIT_DATE" \
    --arg date_hr "$COMMIT_DATE_HR" \
    --arg message "$COMMIT_MESSAGE" \
    --arg parent "$PARENT_COMMIT_HASHES" \
    --argjson total_files_changed "$TOTAL_FILES_CHANGED" \
    --argjson total_insertions "$total_insertions" \
    --argjson total_deletions "$total_deletions" \
    --argjson avg_insertions "$avg_insertions" \
    --argjson avg_deletions "$avg_deletions" \
    --arg category "$commit_category" \
    --argjson files "$files_json" \
    '{hash: $hash, author: $author, email: $email, commit_date: $date, commit_date_hr: $date_hr, message: $message, parent: $parent, total_files_changed: $total_files_changed, total_insertions: $total_insertions, total_deletions: $total_deletions, avg_insertions: $avg_insertions, avg_deletions: $avg_deletions, category: $category, files: $files}')

  output=$(echo "$output" | jq --argjson commit "$commit_json" '.commits += [$commit]')
done

# Add total commits processed to JSON
total_commits=$(echo "$output" | jq '.commits | length')
output=$(echo "$output" | jq --argjson total "$total_commits" '.total_commits_processed = $total')

# Output the JSON
echo "$output" | jq .
