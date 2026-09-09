# Released native v0.5.1 regression inputs

These files are byte-for-byte copies from repository release commit
`2bc026680d32e350a1cf2521523e0e8cf3d8358c`, under `native/scripts/`.
They are inert fixture data, never installed on a real host or executed by the
foundation tests. The tests verify their SHA-256 values and preserve their
bytes, modes and inodes in an isolated simulated pre-existing Core installation.

| Original file | Git blob |
| --- | --- |
| routing.sh | 4076655d2ced8048a6f6f152c09cd6da6953ec61 |
| healthcheck-lib.sh | 20747453a801ccf61756f8192c28d238e049fbce |
| warp-gateway | 800adc24bdd29b30a0a889c253294b922be18b8d |

SHA-256 pins are in `tests/admin_foundation_test.py`. The routing/health library
bytes intentionally differ from the candidate bundle inputs. This prevents a
candidate-to-candidate test from hiding the released-host version skew.
