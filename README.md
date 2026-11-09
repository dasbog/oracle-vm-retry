# oracle-vm-retry

Every 10 minutes, GitHub tries to create an Oracle Cloud Always Free VM from a saved
instance configuration, until Oracle has capacity. When it succeeds it opens an issue
(so you get notified) and switches its own schedule off.

No private data is in this repo. Credentials live in the repo's Actions secrets:
`OCI_USER`, `OCI_TENANCY`, `OCI_FINGERPRINT`, `OCI_REGION`, `OCI_KEY`, `OCI_INSTANCE_CONFIG_ID`.

Manual try: Actions tab > Create Oracle VM > Run workflow.
