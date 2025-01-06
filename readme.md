# Git Commit Analyzer Script

This script analyzes Git commits within a specified time range and categorizes them based on the changes made to files. It provides detailed information about each commit, including the author, date, modified files, and the category of the commit (e.g., "New Work", "Refactor", "Help Others", "Churn/Rework").

---

## Features

- **Categorize Commits**: Commits are categorized based on the weighted sum of file changes.
- **Detailed Commit Information**: For each commit, the script provides:
  - Author name and email.
  - Commit date (both Unix timestamp and human-readable format).
  - Commit message.
  - Parent commit hashes.
  - Total insertions and deletions.
  - Average insertions and deletions per file.
  - Commit category.
  - List of modified files with their categories, insertions, and deletions.
- **Custom Time Range**: Analyze commits within a specific time range using `--since` and `--until` arguments.
- **Merge Commit Handling**: Correctly identifies changes introduced by merge commits.

---

## Prerequisites

Before using the script, ensure you have the following installed:

1. **Git**:
   - The script uses Git commands to retrieve commit information.
   - Install Git: [Git Installation Guide](https://git-scm.com/book/en/v2/Getting-Started-Installing-Git).

2. **Bash**:
   - The script is written in Bash and should be run in a Bash-compatible shell.
   - Most Linux and macOS systems come with Bash pre-installed.

3. **jq**:
   - The script uses `jq` to manipulate JSON data.
   - Install `jq`:
     - **Debian/Ubuntu**: `sudo apt-get install jq`
     - **macOS**: `brew install jq`

4. **bc**:
   - The script uses `bc` for floating-point calculations.
   - Install `bc`:
     - **Debian/Ubuntu**: `sudo apt-get install bc`
     - **macOS**: `brew install bc`

---

## Usage


```./analyze_commits.sh [--since "time-range"] [--until "time-range"]```

eg.

```./analyze_commits.sh --since "10 days ago"```

---

## Output

The script outputs a JSON object with the following structure:

```json

{
  "total_commits_processed": 2,
  "commits": [
    {
      "hash": "abc1234",
      "author": "John Doe",
      "email": "john.doe@example.com",
      "commit_date": 1698765432,
      "commit_date_hr": "2023-10-30 12:34:56",
      "message": "Refactor utils.py for better performance",
      "parent": "def5678",
      "total_insertions": 15,
      "total_deletions": 5,
      "avg_insertions": 7.50,
      "avg_deletions": 2.50,
      "category": "Refactor",
      "files": [
        {
          "file": "src/utils.py",
          "category": "Refactor",
          "insertions": 10,
          "deletions": 5
        },
        {
          "file": "src/api.py",
          "category": "Help Others",
          "insertions": 5,
          "deletions": 0
        }
      ]
    },
    {
      "hash": "def5678",
      "author": "Jane Smith",
      "email": "jane.smith@example.com",
      "commit_date": 1698765433,
      "commit_date_hr": "2023-10-30 12:35:00",
      "message": "Update README with new installation instructions",
      "parent": "ghi9012",
      "total_insertions": 20,
      "total_deletions": 10,
      "avg_insertions": 20.00,
      "avg_deletions": 10.00,
      "category": "New Work",
      "files": [
        {
          "file": "README.md",
          "category": "New Work",
          "insertions": 20,
          "deletions": 10
        }
      ]
    }
  ]
}

```

---
