import subprocess
import json
from datetime import datetime
from collections import defaultdict
import multiprocessing
from elasticsearch import Elasticsearch, helpers
import os

# Define the threshold for "refactor" and "help others" (3 weeks in seconds)
REFACTOR_THRESHOLD = 3 * 7 * 24 * 60 * 60
HELP_OTHERS_THRESHOLD = 3 * 7 * 24 * 60 * 60

# Default values for time range
SINCE = "7 days ago"
UNTIL = "now"

def run_git_command(command):
    """Run a Git command and return its output."""
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, shell=True)
    if result.returncode != 0:
        raise Exception(f"Git command failed: {result.stderr}")
    return result.stdout.strip()

def get_commit_list(since, until):
    """Get the list of commits within the specified time range."""
    command = f"git rev-list --since='{since}' --until='{until}' HEAD"
    commits = run_git_command(command).splitlines()
    return commits

def get_file_history():
    """Cache the last modification author and date for each file."""
    file_history = {}
    files = run_git_command("git ls-files").splitlines()
    for file in files:
        last_modified_info = run_git_command(f"git log -1 --pretty=format:'%an %ct' -- '{file}'")
        if last_modified_info:
            author, timestamp = last_modified_info.rsplit(" ", 1)
            file_history[file] = {"author": author, "timestamp": int(timestamp)}
    return file_history

def determine_commit_category(new_work_count, refactor_count, help_others_count, churn_rework_count):
    """Determine the commit category based on weighted file categories."""
    weights = {
        "New Work": new_work_count * 6,
        "Refactor": refactor_count * 8,
        "Help Others": help_others_count * 5,
        "Churn/Rework": churn_rework_count * 4,
    }
    max_category = max(weights, key=weights.get)
    return max_category

def determine_commit_efficiency(commit_category, insertions, deletions):
    """Calculate the efficiency of a commit based on its category and changes."""
    weights = {
        "Refactor": 0.9,
        "New Work": 0.7,
        "Help Others": 0.6,
        "Churn/Rework": 0.5,
    }
    weight = weights.get(commit_category, 0.5)
    total_changes = insertions + deletions
    if total_changes == 0:
        return 0.0
    efficiency = (insertions / total_changes) * weight
    return round(efficiency, 2)

def process_commit(commit_hash, file_history, previous_commit_timestamp):
    """Process a single commit and return its details as a dictionary."""
    commit_details = {
        "sha": commit_hash,
        "author": run_git_command(f"git log -1 --pretty=format:'%an' {commit_hash}"),
        "email": run_git_command(f"git log -1 --pretty=format:'%ae' {commit_hash}"),
        "commit_date": int(run_git_command(f"git log -1 --pretty=format:'%ct' {commit_hash}")),
        "message": run_git_command(f"git log -1 --pretty=format:'%s' {commit_hash}"),
        "parent": run_git_command(f"git log -1 --pretty=format:'%P' {commit_hash}"),
        "files": [],
        "total_files_changed": 0,
        "total_insertions": 0,
        "total_deletions": 0,
        "avg_insertions": 0,
        "avg_deletions": 0,
        "category": "",
        "cefficiency": 0,
        "commit_interval": 0,  # Initialize commit_interval
    }

    # Calculate commit_interval
    if previous_commit_timestamp is not None:
        commit_details["commit_interval"] = commit_details["commit_date"] - previous_commit_timestamp
    else:
        commit_details["commit_interval"] = 0  # No previous commit

    # Get modified files in the commit
    modified_files = run_git_command(f"git diff-tree --no-commit-id --name-only -r {commit_hash}").splitlines()
    commit_details["total_files_changed"] = len(modified_files)

    if commit_details["total_files_changed"] == 0:
        commit_details["category"] = "Churn/Rework"
    else:
        new_work_count = 0
        refactor_count = 0
        help_others_count = 0
        churn_rework_count = 0

        for file in modified_files:
            file_info = file_history.get(file, {})
            last_modified_author = file_info.get("author", "")
            last_modified_date = file_info.get("timestamp", 0)

            # Get insertions and deletions for the file
            stats = run_git_command(f"git diff --numstat {commit_hash}^ {commit_hash} -- '{file}'")
            insertions, deletions, _ = stats.split("\t", 2)
            insertions = int(insertions) if insertions.isdigit() else 0
            deletions = int(deletions) if deletions.isdigit() else 0

            commit_details["total_insertions"] += insertions
            commit_details["total_deletions"] += deletions

            # Determine file category
            time_difference = commit_details["commit_date"] - last_modified_date
            if time_difference > REFACTOR_THRESHOLD and (insertions + deletions) > 10:
                category = "Refactor"
                refactor_count += 1
            elif last_modified_author != commit_details["author"] and time_difference <= HELP_OTHERS_THRESHOLD:
                category = "Help Others"
                help_others_count += 1
            else:
                diff = run_git_command(f"git diff --unified=0 {commit_hash}^ {commit_hash} -- '{file}'")
                if "+" in diff and "-" not in diff:
                    category = "New Work"
                    new_work_count += 1
                else:
                    category = "Churn/Rework"
                    churn_rework_count += 1

            # Add file details to commit
            commit_details["files"].append({
                "file": file,
                "category": category,
                "insertions": insertions,
                "deletions": deletions,
            })

        # Calculate averages
        commit_details["avg_insertions"] = round(commit_details["total_insertions"] / commit_details["total_files_changed"], 2)
        commit_details["avg_deletions"] = round(commit_details["total_deletions"] / commit_details["total_files_changed"], 2)

        # Determine commit category and efficiency
        commit_details["category"] = determine_commit_category(new_work_count, refactor_count, help_others_count, churn_rework_count)
        commit_details["cefficiency"] = determine_commit_efficiency(commit_details["category"], commit_details["total_insertions"], commit_details["total_deletions"])

    return commit_details

def send_to_elasticsearch_bulk(commit_data_list, es_host, es_index, es_user=None, es_password=None):
    """Send commit data to Elasticsearch in bulk with optional authentication."""
    if es_user and es_password:
        es = Elasticsearch(es_host, http_auth=(es_user, es_password))
    else:
        es = Elasticsearch(es_host)

    actions = [
        {
            "_index": es_index,
            "_id": commit_data["sha"],
            "_source": commit_data,
        }
        for commit_data in commit_data_list
    ]
    try:
        helpers.bulk(es, actions)
        print(f"Successfully indexed {len(commit_data_list)} commits in Elasticsearch.")
    except Exception as e:
        print(f"Failed to index commits in Elasticsearch: {e}")

def main(since, until, es_host, es_index, es_user=None, es_password=None):
    """Main function to analyze Git commits and send data to Elasticsearch in bulk."""
    # Get the list of commits
    commits = get_commit_list(since, until)
    if not commits:
        print("No commits found in the specified time range.")
        return

    # Cache file histories
    file_history = get_file_history()

    # Process commits in order to calculate commit_interval
    results = []
    previous_commit_timestamp = None

    for commit in commits:
        commit_data = process_commit(commit, file_history, previous_commit_timestamp)
        results.append(commit_data)
        previous_commit_timestamp = commit_data["commit_date"]  # Update previous commit timestamp

    # Send commit data to Elasticsearch in bulk
    send_to_elasticsearch_bulk(results, es_host, es_index, es_user, es_password)

    # Prepare final JSON output
    output = {
        "total_commits_processed": len(results),
        "commits": results,
    }

    # Print the JSON output
    print(json.dumps(output, indent=2))

if __name__ == "__main__":
    import argparse

    # Parse command-line arguments
    parser = argparse.ArgumentParser(description="Analyze Git commits and send data to Elasticsearch in bulk.")
    parser.add_argument("--since", default=SINCE, help="Start date for commit analysis (default: 7 days ago)")
    parser.add_argument("--until", default=UNTIL, help="End date for commit analysis (default: now)")
    parser.add_argument("--es-host", required=True, help="Elasticsearch host (e.g., http://localhost:9200)")
    parser.add_argument("--es-index", required=True, help="Elasticsearch index name (e.g., git-stats-combined)")
    parser.add_argument("--es-user", help="Elasticsearch username (optional)")
    parser.add_argument("--es-password", help="Elasticsearch password (optional)")
    args = parser.parse_args()

    # Run the main function
    main(
        args.since,
        args.until,
        args.es_host,
        args.es_index,
        args.es_user,
        args.es_password,
    )
