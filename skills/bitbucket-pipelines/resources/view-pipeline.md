# View Your Pipeline

**Source**: [Atlassian Support](https://support.atlassian.com/bitbucket-cloud/docs/view-your-pipeline/)

Access pipeline status and logs from the Pipelines section in Bitbucket.

## Pipeline History View

Filter by:

- Branch
- Pipeline type
- Status
- Trigger type

Select a specific pipeline to see its result view.

## Pipeline Status

Available statuses:

- **Pending**: Setting up build
- **In progress**: Pipeline currently running
- **Stopped**: Manually or system event
- **Paused**: Deployment paused (manual step waiting)
- **Successful**: Everything completed
- **Failed**: A step failed
- **Error**: Misconfigured pipeline
- **System error**: Something wrong on our end

## Rerunning Pipelines

- **Rerun failed steps only**: Update existing log
- **Rerun entire pipeline**: New pipeline and log

Build artifacts kept for 14 days.

## Log View

Selecting a step shows logs on the right:

- Build logs for last step
- Service logs (if added)
- Test reports (if configured)
- Artifacts (if stored)

Expandable sections for each command within a step.

## Customizing View

- **Expand**: More screen space for logs
- **Collapse sidebar**: Left navigation

## Next Steps

Edit your `bitbucket-pipelines.yml` to configure pipelines.
