#!/bin/bash

# Initialize JSON output
output="{\"total_commits_processed\": 0, \"commits\": []}"

# Get recent commits (last 3 weeks) and process them without a subshell
while IFS=$'\t' read -r commit_hash author email commit_date; do
    files_json="[]"
    # Get files changed in the commit
    while read -r file; do
        # Check if the file is entirely new (no deletions, only additions)
        if git show "$commit_hash" --pretty="" --unified=0 -- "$file" | grep -q "^+" && ! git show "$commit_hash" --pretty="" -- "$file" | grep -q "^-"; then
            category="New Work"
        else
            category="Not New Work"
        fi
        # Add file details to JSON
        file_json="{\"file\": \"$file\", \"category\": \"$category\"}"
        files_json=$(echo "$files_json" | jq --argjson file "$file_json" '. += [$file]')
    done < <(git show --pretty="" --name-only "$commit_hash")
    # Add commit details to JSON
    commit_json=$(jq -n \
        --arg hash "$commit_hash" \
        --arg author "$author" \
        --arg email "$email" \
        --arg date "$commit_date" \
        --argjson files "$files_json" \
        '{hash: $hash, author: $author, email: $email, commit_date: $date, files: $files}')
    output=$(echo "$output" | jq --argjson commit "$commit_json" '.commits += [$commit]')
done < <(git log --since="3 weeks ago" --pretty=format:"%H%x09%an%x09%ae%x09%cd" --date=short)

# Add total commits processed to JSON
total_commits=$(echo "$output" | jq '.commits | length')
output=$(echo "$output" | jq --argjson total "$total_commits" '.total_commits_processed = $total')

# Output the JSON
echo "$output" | jq .
