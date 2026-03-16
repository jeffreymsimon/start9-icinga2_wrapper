import { VersionInfo } from '@start9labs/start-sdk'

export const v1_0_0_alpha_2 = VersionInfo.of({
  version: '1.0.0-alpha.2:0',
  releaseNotes: `Alpha 2: Fix IcingaWeb2 login and improve Observium sync

Fixes:
- Fix IcingaWeb2 schema import (wrong filename: mysql.sql → mysql.schema.sql)
- Make admin user setup idempotent (auto-recover if schema was missing)
- Add icinga2 config validation on startup

Improvements:
- Parse Observium probe_args: HTTP ports, SSL flags, SNMP OIDs/thresholds
- Remove blanket ping apply rule that conflicted with synced services
- Use alpha versioning consistent with other haz1upstart003 packages`,
  migrations: {
    up: async ({ effects }) => {},
    down: async ({ effects }) => {},
  },
})
