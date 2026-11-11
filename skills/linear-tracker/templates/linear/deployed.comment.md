<!--
  Comment posted when a merged pull request is deployed: every pipeline of the
  merge commit finished green.
  Placeholders: {{issue}} {{pr_number}} {{pr_url}} {{base}} {{commit}} {{runs}}
  Edit freely. Drop this comment from the rendered body.
-->
Deployed: [PR #{{pr_number}}]({{pr_url}}) merged into `{{base}}`, and every pipeline of commit `{{commit}}` is green.

Pipelines: {{runs}}
