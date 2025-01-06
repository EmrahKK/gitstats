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

---
