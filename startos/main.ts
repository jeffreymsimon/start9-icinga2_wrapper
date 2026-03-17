import { sdk } from './sdk'
import { webPort } from './utils'
import { configFile, defaultConfig, Config } from './fileModels/config.yaml'
import * as crypto from 'crypto'

export const main = sdk.setupMain(async ({ effects }) => {
  console.info('Starting Icinga2 monitoring!')

  let config = (await configFile.read().const(effects)) as Config | null

  // Generate passwords if not set
  if (!config || !config['db-password']) {
    const dbPassword = crypto.randomBytes(16).toString('hex')
    const adminPassword =
      config?.['admin-password'] || crypto.randomBytes(8).toString('base64')
    const apiPassword =
      config?.['api-password'] || crypto.randomBytes(16).toString('hex')

    config = {
      ...defaultConfig,
      ...config,
      'db-password': dbPassword,
      'admin-password': adminPassword,
      'api-password': apiPassword,
    }

    await configFile.write(effects, config)
    console.info('Generated database, admin, and API credentials')
  }

  // Generate API password if missing (upgrade from older config)
  if (!config['api-password']) {
    config = {
      ...config,
      'api-password': crypto.randomBytes(16).toString('hex'),
    }
    await configFile.write(effects, config)
    console.info('Generated API credentials')
  }

  const subcontainer = await sdk.SubContainer.of(
    effects,
    { imageId: 'icinga2' },
    sdk.Mounts.of().mountVolume({
      volumeId: 'main',
      subpath: null,
      mountpoint: '/root/data',
      readonly: false,
    }),
    'icinga2-server',
  )

  const shellEscape = (val: string | number | boolean): string => {
    const str = String(val)
    return `'${str.replace(/'/g, "'\\''")}'`
  }

  const envVarsList = [
    `S9_ICINGA2_ADMIN_USERNAME=${shellEscape(config['admin-username'])}`,
    `S9_ICINGA2_ADMIN_PASSWORD=${shellEscape(config['admin-password'])}`,
    `S9_ICINGA2_DB_PASSWORD=${shellEscape(config['db-password'])}`,
    `S9_ICINGA2_API_PASSWORD=${shellEscape(config['api-password'])}`,
    `S9_ICINGA2_PRIMARY_DNS=${shellEscape(config['primary-dns'])}`,
    `S9_ICINGA2_SECONDARY_DNS=${shellEscape(config['secondary-dns'])}`,
    `S9_ICINGA2_CHECK_INTERVAL=${shellEscape(config['check-interval'])}`,
    `S9_ICINGA2_RETRY_INTERVAL=${shellEscape(config['retry-interval'])}`,
    `S9_ICINGA2_MAX_CHECK_ATTEMPTS=${shellEscape(config['max-check-attempts'])}`,
    `S9_ICINGA2_SNMP_COMMUNITY=${shellEscape(config['snmp-community'])}`,
    `S9_ICINGA2_OBSERVIUM_SYNC=${shellEscape(config['observium-sync-enabled'])}`,
    `S9_ICINGA2_OBSERVIUM_DB_HOST=${shellEscape(config['observium-db-host'])}`,
    `S9_ICINGA2_OBSERVIUM_DB_USER=${shellEscape(config['observium-db-user'])}`,
    `S9_ICINGA2_OBSERVIUM_DB_PASSWORD=${shellEscape(config['observium-db-password'])}`,
    `S9_ICINGA2_CF_API_TOKEN=${shellEscape(config['cf-api-token'])}`,
    `S9_ICINGA2_CF_ACCOUNT_ID=${shellEscape(config['cf-account-id'])}`,
    `S9_ICINGA2_LOG_LEVEL=${shellEscape(config['log-level'])}`,
  ]

  const envVars = envVarsList.join(' ')

  return sdk.Daemons.of(effects)
    .addDaemon('primary', {
      subcontainer,
      exec: {
        command: [
          '/bin/sh',
          '-c',
          `${envVars} /usr/local/bin/docker_entrypoint.sh`,
        ],
      },
      ready: {
        display: 'Web Interface',
        fn: () =>
          sdk.healthCheck.checkPortListening(effects, webPort, {
            successMessage: 'IcingaWeb2 dashboard is accepting connections',
            errorMessage: 'IcingaWeb2 dashboard is not responding',
          }),
      },
      requires: [],
    })
    .addHealthCheck('database', {
      ready: {
        display: 'Database',
        fn: () =>
          sdk.healthCheck.runHealthScript(
            [
              'sh',
              '-c',
              'mysqladmin ping --socket=/var/run/mysqld/mysqld.sock 2>/dev/null && echo "Success: Database connected" || { echo "Failed: Database not responding"; exit 1; }',
            ],
            subcontainer,
            {
              timeout: 10000,
              errorMessage:
                'Database connection failed. MySQL may still be starting.',
            },
          ),
      },
      requires: [],
    })
    .addHealthCheck('icinga2-daemon', {
      ready: {
        display: 'Icinga2 Daemon',
        fn: () =>
          sdk.healthCheck.runHealthScript(
            [
              'sh',
              '-c',
              'test -f /run/icinga2/icinga2.pid && kill -0 $(cat /run/icinga2/icinga2.pid) 2>/dev/null && echo "Success: Icinga2 daemon running" || { echo "Failed: Icinga2 daemon not running"; exit 1; }',
            ],
            subcontainer,
            {
              timeout: 5000,
              errorMessage:
                'Icinga2 daemon not running. Check logs for errors.',
            },
          ),
      },
      requires: [],
    })
})
