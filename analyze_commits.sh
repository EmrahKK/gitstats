#!/bin/bash

# Define the threshold for "refactor" and "help others" (3 weeks in seconds)
REFACTOR_THRESHOLD=$((3 * 7 * 24 * 60 * 60))
HELP_OTHERS_THRESHOLD=$((3 * 7 * 24 * 60 * 60))

# Elasticsearch settings
ELASTICSEARCH_HOST="https://elastic.com.tr"
INDEX_NAME="git-stats-combined"
ELASTICSEARCH_USERNAME=""
ELASTICSEARCH_PASSWORD=""
NAMES_INPUT_FILE="users.txt"

# Parse command-line arguments for time range, project name, and repository name
SINCE="1 week ago"  # Default value
UNTIL="now"         # Default value
PROJECT_NAME=""
REPOSITORY_NAME=""
REPOSITORY_BRANCH=""

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
    --project_name)
      PROJECT_NAME="$2"
      shift 2
      ;;
    --repository_name)
      REPOSITORY_NAME="$2"
      shift 2
      ;;
    --elasticsearch_host)
      ELASTICSEARCH_HOST="$2"
      shift 2
      ;;      
    --elasticsearch_index)
      INDEX_NAME="$2"
      shift 2
      ;;
    --elasticsearch_user)
      ELASTICSEARCH_USERNAME="$2"
      shift 2
      ;;
    --elasticsearch_password)
      ELASTICSEARCH_PASSWORD="$2"
      shift 2
      ;;      
    *)
      echo "Unknown argument: $1"
      exit 1
      ;;
  esac
done

# Validate project_name and repository_name
if [[ -z "$PROJECT_NAME" || -z "$REPOSITORY_NAME" ]]; then
  echo "Error: --project_name and --repository_name are required parameters."
  exit 1
fi

# Get the list of commits within the specified time range
COMMITS=$(git log --since="$SINCE" --until="$UNTIL" --pretty=format:"%H")

# Check if there are any commits in the specified time range
if [ -z "$COMMITS" ]; then
  echo "No commits found in the specified time range."
  exit 0
fi

# Function to send a commit document to Elasticsearch
send_to_elasticsearch() {
  local doc_id=$1
  local json_data=$2
  local result=$(curl  -s -w "%{http_code}" -X POST "$ELASTICSEARCH_HOST/$INDEX_NAME/_doc/$doc_id" -H 'Authorization: Basic Zmx1ZW50Ym' -H "Content-Type: application/json" -d "$json_data" -o /dev/null )

  # echo "$PROJECT_NAME $REPOSITORY_NAME $doc_id - $result"

  sleep 0.1
}

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
    # git diff-tree -c --no-commit-id --name-only -r "$commit_hash"^1 "$commit_hash"
    git diff-tree --no-commit-id --name-only -r "$commit_hash"
  else
    # For non-merge commits, use the standard approach
    git diff-tree --no-commit-id --name-only -r "$commit_hash"
  fi
}

# Function to determine efficiency for a commit
determine_commit_efficiency() {
  local commit_category=$1
  local commit_insertions=$2
  local commit_deletions=$3
  local commit_weight=0
  local efficiency=0

  # Validate numeric inputs
  if ! [[ "$commit_insertions" =~ ^[0-9]+$ && "$commit_deletions" =~ ^[0-9]+$ ]]; then
    echo "Error: Insertions and deletions must be numeric values."
    return 1
  fi

  # Set weight based on category
  case "$commit_category" in
    "Refactor")
      commit_weight=0.9
      ;;
    "New Work")
      commit_weight=0.7
      ;;
    "Help Others")
      commit_weight=0.6
      ;;
    *)
      commit_weight=0.5
      ;;
  esac

  # Calculate efficiency, avoid division by zero
  local total_changes=$((commit_insertions + commit_deletions))
  if [[ $total_changes -eq 0 ]]; then
    printf "0.00\n"
    return 0
  fi

  if [[ $commit_insertions -eq 0 ]]; then
    efficiency=0.1
  else
    efficiency=$(echo "scale=2; ($commit_insertions / $total_changes) * $commit_weight" | bc)
  fi

  printf "%.2f\n" "$efficiency"
}

# Function to determine impact for a commit
determine_commit_impact() {
  local commit_files_changed=$1
  local commit_insertions=$2
  local c_impact=0

  c_impact=$((commit_files_changed * commit_insertions))

  echo "$c_impact"
}

# Iterate through each commit
for COMMIT_HASH in $COMMITS; do
  # Get the parent commit hashes
  PARENT_COMMIT_HASHES=$(git log -1 --pretty=format:"%P" "$COMMIT_HASH")

  # Skip merge commits (those with more than one parent)
  if [ $(echo "$PARENT_COMMIT_HASHES" | wc -w) -ge 2 ]; then
    continue
  fi


  files_json="[]"
  total_insertions=0
  total_deletions=0
  new_work_count=0
  refactor_count=0
  help_others_count=0
  churn_rework_count=0
  cefficiency=0
  commits=1
  commit_impact=0

  # Get the current author name and email of the commit
  CURRENT_AUTHOR=$(git log -1 --pretty=format:"%an" "$COMMIT_HASH")
  CURRENT_AUTHOR_EMAIL=$(git log -1 --pretty=format:"%ae" "$COMMIT_HASH")

  # Get Author Real Name
  #echo "--- $CURRENT_AUTHOR"
  # Lookup the file for the given name or user number
  if [[ "$CURRENT_AUTHOR" =~ .*0.* ]]; then
    authorNameDistilled=$(echo "$CURRENT_AUTHOR"| grep -oP "[a-zA-Z][0-9]+")
    MATCH=$(grep -i "$authorNameDistilled" "users.txt")
    if [ -n "$MATCH" ]; then
      # If a match is found, extract and print the user name
      CURRENT_AUTHOR=$(echo "$MATCH" | awk -F '-' '{print $1}')
    fi
  fi
  
  #echo "--- $CURRENT_AUTHOR"

  # Get the current commit date (Unix timestamp)
  CURRENT_COMMIT_DATE=$(git log -1 --pretty=format:%ct "$COMMIT_HASH")

  # Convert Unix timestamp to human-readable format
  #COMMIT_DATE_HR=$(date -d "@$CURRENT_COMMIT_DATE" "+%Y-%m-%d %H:%M")
  COMMIT_DATE_HR=$(date -Iseconds -d "@$CURRENT_COMMIT_DATE")

  # Get the commit message (comments)
  COMMIT_MESSAGE=$(git log -1 --pretty=format:"%s" "$COMMIT_HASH")

  # Get branch name
  BRANCH=$(git rev-parse --abbrev-ref HEAD)  

  # Get the list of modified files in the commit
  #MODIFIED_FILES=$(get_modified_files "$COMMIT_HASH" "$PARENT_COMMIT_HASHES")
  MODIFIED_FILES=$(git show --numstat --format='' "$COMMIT_HASH" | awk '{$2="";$1="";sub("  ","")}1')
  TOTAL_FILES_CHANGED=$(echo "$MODIFIED_FILES" | wc -l)

  IFS=$'\n'

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

        # Get insertions and deletions for the file
        STATS=$(git show --numstat --format='' "$COMMIT_HASH" -- "$FILE")
        INSERTIONS=$(echo "$STATS" | awk '{print $1}')
        DELETIONS=$(echo "$STATS" | awk '{print $2}')        
        #echo "$STATS"
	
      	# Check if INSERTIONS and DELETIONS are numbers
        if [[ $INSERTIONS =~ ^[0-9]+$ && $DELETIONS =~ ^[0-9]+$ ]]; then
          echo "$INSERTIONS - $DELETIONS - $FILE" 	  
        else
          echo "Cannot get changed line information for : $FILE "
          INSERTIONS=0
          DELETIONS=0
        fi

      else
        # Extract the last modification author and date
        LAST_MODIFIED_AUTHOR=$(echo "$LAST_MODIFIED_INFO" | awk '{$NF=""; print $0}' | sed 's/ *$//')
        LAST_MODIFIED_DATE=$(echo "$LAST_MODIFIED_INFO" | awk '{print $NF}')

        # Calculate the time difference in seconds
        TIME_DIFFERENCE=$((CURRENT_COMMIT_DATE - LAST_MODIFIED_DATE))

        # Get insertions and deletions for the file
        STATS=$(git show --numstat --format='' "$COMMIT_HASH" -- "$FILE")
        INSERTIONS=$(echo "$STATS" | awk '{print $1}')
        DELETIONS=$(echo "$STATS" | awk '{print $2}')        
        #echo "$STATS"
	
      	# Check if INSERTIONS and DELETIONS are numbers
        if [[ $INSERTIONS =~ ^[0-9]+$ && $DELETIONS =~ ^[0-9]+$ ]]; then
          echo "$INSERTIONS - $DELETIONS - $FILE" 	  
        else
          echo "Cannot get changed line information for : $FILE "
          INSERTIONS=0
          DELETIONS=0
        fi

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
  
  # Unset IFS for default settings in shell
  unset IFS

  # Determine commit efficiency based on commit categories, insertions and deletions
  cefficiency=$(determine_commit_efficiency "$commit_category" "$total_insertions" "$total_deletions")
  
  # Determine commit impact based on commit insertions and changed file count
  commit_impact=$(determine_commit_impact "$TOTAL_FILES_CHANGED" "$total_insertions")

  #echo "cefficiency : $cefficiency"

  # Add commit details to JSON
  commit_json=$(jq -n \
    --arg hash "$COMMIT_HASH" \
    --arg author "$CURRENT_AUTHOR" \
    --arg email "$CURRENT_AUTHOR_EMAIL" \
    --argjson date "$CURRENT_COMMIT_DATE" \
    --arg date_hr "$COMMIT_DATE_HR" \
    --arg message "$COMMIT_MESSAGE" \
    --arg parent "$PARENT_COMMIT_HASHES" \
    --arg project_name "$PROJECT_NAME" \
    --arg repository_name "$REPOSITORY_NAME" \
    --arg branch "$BRANCH" \
    --argjson commits "$commits" \
    --argjson total_files_changed "$TOTAL_FILES_CHANGED" \
    --argjson total_insertions "$total_insertions" \
    --argjson total_deletions "$total_deletions" \
    --argjson avg_insertions "$avg_insertions" \
    --argjson avg_deletions "$avg_deletions" \
    --argjson cefficiency "$cefficiency" \
    --argjson commit_impact "$commit_impact" \
    --arg category "$commit_category" \
    --argjson files "$files_json" \
    '{sha: $hash, author: $author, email: $email, commit_date: $date, date: $date_hr, branch: $branch, message: $message, parent: $parent, commits: $commits, project_name: $project_name, repository_name: $repository_name, total_files_changed: $total_files_changed, insertions: $total_insertions, deletions: $total_deletions, avg_insertions: $avg_insertions, avg_deletions: $avg_deletions, category: $category, cefficiency: $cefficiency, commit_impact: $commit_impact, files: $files}')
  
  #echo " ---"
  #echo " "
  #echo "$commit_json"
  
  send_to_elasticsearch "$COMMIT_HASH" "$commit_json"
done
