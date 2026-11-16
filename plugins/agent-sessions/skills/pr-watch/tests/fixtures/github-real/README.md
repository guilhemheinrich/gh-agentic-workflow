Real GitHub REST payloads, fetched with `gh api` on 2026-11-02 from the public
repository `cli/cli`, pull request 14858 (merged, 26 check runs, two inline
review comments, three reviews), then trimmed to the fields `prw` reads.
`statuses.json` and `issue-comments.json` are empty arrays: that PR has none.
They pin the field names the GitHub provider maps (`merged`, `mergeable_state`,
`merge_commit_sha`, check-run `status`/`conclusion`, review `state`, comment
`line`), which the first fixtures had only from memory.
