import { setupManifest } from '@start9labs/start-sdk'

export const manifest = setupManifest({
  id: 'icinga2',
  title: 'Icinga2',
  license: 'GPL-2.0',
  wrapperRepo: 'https://github.com/jeffreymsimon/start9-icinga2_wrapper',
  upstreamRepo: 'https://github.com/Icinga/icinga2',
  supportSite:
    'https://github.com/jeffreymsimon/start9-icinga2_wrapper/issues',
  marketingSite: 'https://icinga.com',
  donationUrl: null,
  docsUrl: 'https://icinga.com/docs/icinga-2/latest/',
  description: {
    short: 'Enterprise-grade monitoring with Nagios-compatible checks',
    long: 'Icinga2 is an open-source monitoring system that checks the availability of network resources, notifies users of outages, and generates performance data for reporting. This package includes IcingaWeb2 dashboard, Nagios-compatible check plugins, and optional sync from Observium to import existing device and probe definitions.',
  },
  volumes: ['main'],
  images: {
    icinga2: {
      source: {
        dockerBuild: {
          dockerfile: './Dockerfile',
          workdir: '.',
        },
      },
    },
  },
  alerts: {
    install:
      'After installation, configure your settings via Actions > Configure Settings. Default admin credentials are auto-generated — view them via Actions > View Credentials.',
    update: null,
    uninstall:
      'Uninstalling will remove all monitoring data and database. Consider creating a backup first.',
    restore: null,
    start: null,
    stop: null,
  },
  dependencies: {},
  config: null,
})
