import { VersionInfo } from '@start9labs/start-sdk'

export const v1_0_0 = VersionInfo.of({
  version: '1.0.0:0',
  releaseNotes: `Initial release of Icinga2 for StartOS 0.4.0

Features:
- Icinga2 monitoring engine with IcingaWeb2 dashboard
- Nagios-compatible check plugins (SSH, HTTP, SNMP, ping)
- Observium sync: import devices and probes from Observium MySQL
- Auto-configured MySQL database and web interface
- Health checks for web UI, database, and Icinga2 daemon
- Automatic admin credential generation

Configure monitoring via Actions > Configure Settings.
Enable Observium sync to import existing device/probe definitions.`,
  migrations: {
    up: async ({ effects }) => {},
    down: async ({ effects }) => {},
  },
})
