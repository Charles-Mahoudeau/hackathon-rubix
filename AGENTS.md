# Contributing to hackathon-rubix

## Commit messages

All commits must follow [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(<scope>): <description>
```

Types: `feat` `fix` `chore` `docs` `style` `refactor` `perf` `test` `build` `ci` `revert`

Examples:
- `feat(mining): add ore yield curve`
- `fix(ui): correct token-cost display on directive editor`
- `chore: bootstrap game/ from rtype template`

Enforced by:
- CI: `.github/workflows/commitlint.yml` runs commitlint against every PR's commits.
- Local (optional but recommended): `git config core.hooksPath .githooks` to reject non-conforming commit messages before you even push.
