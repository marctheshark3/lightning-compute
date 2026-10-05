# Credentials and repository checks

Keep gateway keys in private files outside Git working trees or inject them through
the environment. The Spark installer uses a hidden prompt, stores its key in a
mode `0600` file under a mode `0700` directory, and refuses to generate credentials
or settings backups inside a Git working tree. Never paste keys into documentation,
registration blocks, command arguments, issues, or pull requests.

Earlier repository commits contain embedded gateway credentials. Removing them
from current files does not revoke them or erase Git history. Any deployment using
a previously committed key must rotate it and update its clients. History cleanup
alone cannot invalidate copies in clones or forks.

The `Checks` workflow runs credential-handling tests and Gitleaks **8.30.1** against
the current files and incoming PR commits. It does not claim that older history is
clean, and it does not use a baseline or allowlist to suppress credentials.

With Gitleaks installed, repeat the scans locally:

```bash
gitleaks dir . --redact=100
gitleaks git . --log-opts="origin/master..HEAD" --redact=100
gitleaks git . --log-opts="--all" --redact=100
```

The full-history scan will report the historical findings until that history is
rewritten. Keep any reports private and redacted. Automated scanning cannot prove
that every secret is absent; compare against known runtime credentials privately
when checking an existing deployment.

Credential-handling tests run without a live gateway or model (Python 3.11+):

```bash
python3 -m unittest discover -s tests -v
```
