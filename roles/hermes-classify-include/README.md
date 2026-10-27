# hermes-classify-include

Loops over `hermes_extra_roles` and dynamically includes each. Designed to be
the LAST role in a pull playbook. The list is typically supplied at runtime by
the ansible-pull wrapper, which materializes Hermes's classify response into
`--extra-vars @99-roles.yml`.

When the list is empty (or missing), the role no-ops cleanly.

Push-only roles are refused: if the list names any of `hermes_classify_denied_roles`
(default `k3s`, `bootstrap-user`; matched on the last path component), the role fails
before including anything, so a classification can never restart or reconfigure k3s
from the hourly pull.
