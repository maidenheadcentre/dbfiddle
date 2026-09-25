# oracle

| engine | product |
|---|---|
| `oracle_11.2` | 11g XE |
| `oracle_18` | 18c XE |
| `oracle_21` | 21c XE |
| `oracle_23c` | 23c Free |
| `oracle_23` | **23ai** Free |
| `oracle_26` | 26ai Free, versioned 23.26.x |

Oracle shipped no XE or Free build of 12c or 19c.

- If a new version's ceremony never reaches `FIDDLE-READY`, try `oracle_26`'s ksipc veth
  workaround.
