import { sdk, InputSpec, Value } from '../sdk'
import { configFile, defaultConfig, Config } from '../fileModels/config.yaml'

const settingsInputSpec = InputSpec.of({
  // Admin credentials
  adminUsername: Value.text({
    name: 'Admin Username',
    description: 'Login username for IcingaWeb2 dashboard',
    default: 'admin',
    required: true,
  }),
  adminPassword: Value.text({
    name: 'Admin Password',
    description:
      'Login password for IcingaWeb2 (leave empty on first install to auto-generate)',
    default: '',
    required: false,
    masked: true,
  }),

  // Network
  primaryDns: Value.text({
    name: 'Primary DNS',
    description: 'Primary DNS server for name resolution inside the container',
    default: '10.0.20.1',
    required: true,
  }),
  secondaryDns: Value.text({
    name: 'Secondary DNS',
    description: 'Fallback DNS server',
    default: '1.1.1.1',
    required: true,
  }),

  // Monitoring defaults
  checkInterval: Value.number({
    name: 'Check Interval (seconds)',
    description: 'Default interval between active checks',
    default: 300,
    required: true,
    integer: true,
    min: 60,
    max: 3600,
  }),
  retryInterval: Value.number({
    name: 'Retry Interval (seconds)',
    description: 'Interval for retrying failed checks',
    default: 60,
    required: true,
    integer: true,
    min: 10,
    max: 600,
  }),
  maxCheckAttempts: Value.number({
    name: 'Max Check Attempts',
    description: 'Number of retries before transitioning to hard state',
    default: 3,
    required: true,
    integer: true,
    min: 1,
    max: 10,
  }),
  snmpCommunity: Value.text({
    name: 'SNMP Community',
    description: 'Default SNMP community string for check_snmp probes',
    default: '10fir',
    required: true,
  }),

  // Observium sync
  observiumSyncEnabled: Value.toggle({
    name: 'Enable Observium Sync',
    description:
      'Import device and probe definitions from Observium MySQL database',
    default: false,
  }),
  observiumDbHost: Value.text({
    name: 'Observium DB Host',
    description: 'Observium MySQL server IP/hostname',
    default: '10.0.60.125',
    required: false,
  }),
  observiumDbUser: Value.text({
    name: 'Observium DB User',
    description: 'MySQL username for Observium database',
    default: 'observium',
    required: false,
  }),
  observiumDbPassword: Value.text({
    name: 'Observium DB Password',
    description: 'MySQL password for Observium database',
    default: '',
    required: false,
    masked: true,
  }),

  // Cloudflare tunnel monitoring
  cfApiToken: Value.text({
    name: 'Cloudflare API Token',
    description:
      'API token for Cloudflare tunnel health checks (leave empty to skip)',
    default: '',
    required: false,
    masked: true,
  }),
  cfAccountId: Value.text({
    name: 'Cloudflare Account ID',
    description: 'Cloudflare account ID for tunnel monitoring',
    default: '',
    required: false,
  }),

  // ntfy notifications
  ntfyEnabled: Value.toggle({
    name: 'Enable ntfy Notifications',
    description:
      'Send alert notifications to an ntfy server when hosts/services change state',
    default: false,
  }),
  ntfyServerUrl: Value.text({
    name: 'ntfy Server URL',
    description:
      'Full URL of the ntfy server (e.g. https://ntfy.sh or https://ntfy.10fir.com)',
    default: 'https://ntfy.sh',
    required: false,
  }),
  ntfyTopic: Value.text({
    name: 'ntfy Topic',
    description: 'Topic name to publish notifications to (e.g. icinga-alerts)',
    default: '',
    required: false,
  }),
  ntfyUsername: Value.text({
    name: 'ntfy Username',
    description: 'Username for ntfy authentication (leave empty for public topics)',
    default: '',
    required: false,
  }),
  ntfyPassword: Value.text({
    name: 'ntfy Password',
    description: 'Password for ntfy authentication',
    default: '',
    required: false,
    masked: true,
  }),
  ntfyPriority: Value.select({
    name: 'Default Priority',
    description:
      'Default ntfy priority for notifications (CRITICAL alerts always use "urgent")',
    default: '4',
    values: {
      '1': 'Min',
      '2': 'Low',
      '3': 'Default',
      '4': 'High',
      '5': 'Urgent',
    },
  }),
  ntfyOnCritical: Value.toggle({
    name: 'Notify on CRITICAL',
    description: 'Send notification when a host/service enters CRITICAL/DOWN state',
    default: true,
  }),
  ntfyOnWarning: Value.toggle({
    name: 'Notify on WARNING',
    description: 'Send notification when a host/service enters WARNING state',
    default: true,
  }),
  ntfyOnRecovery: Value.toggle({
    name: 'Notify on RECOVERY',
    description: 'Send notification when a host/service recovers to OK/UP state',
    default: true,
  }),
  ntfyOnUnknown: Value.toggle({
    name: 'Notify on UNKNOWN',
    description: 'Send notification when a host/service enters UNKNOWN state',
    default: false,
  }),

  // Logging
  logLevel: Value.select({
    name: 'Log Level',
    description: 'Icinga2 daemon log verbosity',
    default: 'warning',
    values: {
      error: 'Error Only',
      warning: 'Warning (Recommended)',
      information: 'Information',
      debug: 'Debug (Verbose)',
    },
  }),
})

export const configureSettings = sdk.Action.withInput(
  'configure-settings',

  async ({ effects }) => ({
    name: 'Configure Settings',
    description: 'Configure Icinga2 monitoring settings and Observium sync',
    warning: 'Changes require a service restart to take effect',
    allowedStatuses: 'any',
    group: 'Configuration',
    visibility: 'enabled',
  }),

  settingsInputSpec,

  async ({ effects }) => {
    const config = (await configFile.read().const(effects)) as Config | null
    if (config) {
      return {
        adminUsername: config['admin-username'],
        adminPassword: config['admin-password'],
        primaryDns: config['primary-dns'],
        secondaryDns: config['secondary-dns'],
        checkInterval: config['check-interval'],
        retryInterval: config['retry-interval'],
        maxCheckAttempts: config['max-check-attempts'],
        snmpCommunity: config['snmp-community'],
        observiumSyncEnabled: config['observium-sync-enabled'],
        observiumDbHost: config['observium-db-host'],
        observiumDbUser: config['observium-db-user'],
        observiumDbPassword: config['observium-db-password'],
        cfApiToken: config['cf-api-token'],
        cfAccountId: config['cf-account-id'],
        ntfyEnabled: config['ntfy-enabled'],
        ntfyServerUrl: config['ntfy-server-url'],
        ntfyTopic: config['ntfy-topic'],
        ntfyUsername: config['ntfy-username'],
        ntfyPassword: config['ntfy-password'],
        ntfyPriority: config['ntfy-priority'] as '1' | '2' | '3' | '4' | '5',
        ntfyOnCritical: config['ntfy-on-critical'],
        ntfyOnWarning: config['ntfy-on-warning'],
        ntfyOnRecovery: config['ntfy-on-recovery'],
        ntfyOnUnknown: config['ntfy-on-unknown'],
        logLevel: config['log-level'] as
          | 'error'
          | 'warning'
          | 'information'
          | 'debug',
      }
    }
    return {
      adminUsername: defaultConfig['admin-username'],
      adminPassword: defaultConfig['admin-password'],
      primaryDns: defaultConfig['primary-dns'],
      secondaryDns: defaultConfig['secondary-dns'],
      checkInterval: defaultConfig['check-interval'],
      retryInterval: defaultConfig['retry-interval'],
      maxCheckAttempts: defaultConfig['max-check-attempts'],
      snmpCommunity: defaultConfig['snmp-community'],
      observiumSyncEnabled: defaultConfig['observium-sync-enabled'],
      observiumDbHost: defaultConfig['observium-db-host'],
      observiumDbUser: defaultConfig['observium-db-user'],
      observiumDbPassword: defaultConfig['observium-db-password'],
      cfApiToken: defaultConfig['cf-api-token'],
      cfAccountId: defaultConfig['cf-account-id'],
      ntfyEnabled: defaultConfig['ntfy-enabled'],
      ntfyServerUrl: defaultConfig['ntfy-server-url'],
      ntfyTopic: defaultConfig['ntfy-topic'],
      ntfyUsername: defaultConfig['ntfy-username'],
      ntfyPassword: defaultConfig['ntfy-password'],
      ntfyPriority: defaultConfig['ntfy-priority'],
      ntfyOnCritical: defaultConfig['ntfy-on-critical'],
      ntfyOnWarning: defaultConfig['ntfy-on-warning'],
      ntfyOnRecovery: defaultConfig['ntfy-on-recovery'],
      ntfyOnUnknown: defaultConfig['ntfy-on-unknown'],
      logLevel: defaultConfig['log-level'],
    }
  },

  async ({ effects, input }) => {
    const existingConfig =
      ((await configFile.read().const(effects)) as Config | null) ||
      defaultConfig

    await configFile.write(effects, {
      ...existingConfig,
      'admin-username': input.adminUsername,
      'admin-password': input.adminPassword ?? existingConfig['admin-password'],
      'primary-dns': input.primaryDns,
      'secondary-dns': input.secondaryDns,
      'check-interval': input.checkInterval,
      'retry-interval': input.retryInterval,
      'max-check-attempts': input.maxCheckAttempts,
      'snmp-community': input.snmpCommunity,
      'observium-sync-enabled': input.observiumSyncEnabled,
      'observium-db-host': input.observiumDbHost ?? '10.0.60.125',
      'observium-db-user': input.observiumDbUser ?? 'observium',
      'observium-db-password':
        input.observiumDbPassword ??
        existingConfig['observium-db-password'],
      'cf-api-token': input.cfApiToken ?? existingConfig['cf-api-token'],
      'cf-account-id': input.cfAccountId ?? existingConfig['cf-account-id'],
      'ntfy-enabled': input.ntfyEnabled,
      'ntfy-server-url': input.ntfyServerUrl ?? existingConfig['ntfy-server-url'],
      'ntfy-topic': input.ntfyTopic ?? existingConfig['ntfy-topic'],
      'ntfy-username': input.ntfyUsername ?? existingConfig['ntfy-username'],
      'ntfy-password': input.ntfyPassword ?? existingConfig['ntfy-password'],
      'ntfy-priority': input.ntfyPriority,
      'ntfy-on-critical': input.ntfyOnCritical,
      'ntfy-on-warning': input.ntfyOnWarning,
      'ntfy-on-recovery': input.ntfyOnRecovery,
      'ntfy-on-unknown': input.ntfyOnUnknown,
      'log-level': input.logLevel,
    })

    return {
      version: '1' as const,
      title: 'Settings Saved',
      message: `Configuration saved successfully.

- Check Interval: ${input.checkInterval}s
- Retry Interval: ${input.retryInterval}s
- SNMP Community: ${input.snmpCommunity}
- Observium Sync: ${input.observiumSyncEnabled ? 'Enabled' : 'Disabled'}
- ntfy Notifications: ${input.ntfyEnabled ? 'Enabled' : 'Disabled'}${input.ntfyEnabled ? ` (${input.ntfyServerUrl}/${input.ntfyTopic})` : ''}
- Log Level: ${input.logLevel}

Please restart the service to apply these changes.`,
      result: {
        type: 'single' as const,
        value: 'Configuration saved. Restart to apply.',
        copyable: false,
        qr: false,
        masked: false,
      },
    }
  },
)
