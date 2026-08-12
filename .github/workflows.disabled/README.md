# CI (not yet enabled)

`ci.yml` lives here rather than in `.github/workflows/` because pushing a workflow
file requires a GitHub token with the `workflow` scope.

To enable it:

```bash
gh auth refresh -s workflow
git mv .github/workflows.disabled/ci.yml .github/workflows/ci.yml
git commit -am "Enable CI" && git push
```
