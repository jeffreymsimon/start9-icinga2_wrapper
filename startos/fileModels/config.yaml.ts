import { FileHelper } from '@start9labs/start-sdk'
import { object, string, number, boolean, literals } from 'ts-matches'

const configShape = object({
  // Admin credentials
  'admin-username': string.onMismatch('admin'),
  'admin-password': string.onMismatch(''),

  // Database (auto-generated)
  'db-password': string.onMismatch(''),

  // Network
  'primary-dns': string.onMismatch('10.0.20.1'),
  'secondary-dns': string.onMismatch('1.1.1.1'),

  // Monitoring defaults
  'check-interval': number.onMismatch(300),
  'retry-interval': number.onMismatch(60),
  'max-check-attempts': number.onMismatch(3),
  'snmp-community': string.onMismatch('10fir'),

  // Icinga2 API credentials (auto-generated)
  'api-password': string.onMismatch(''),

  // Observium sync
  'observium-sync-enabled': boolean.onMismatch(false),
  'observium-db-host': string.onMismatch('10.0.60.125'),
  'observium-db-user': string.onMismatch('observium'),
  'observium-db-password': string.onMismatch(''),

  // Cloudflare tunnel monitoring
  'cf-api-token': string.onMismatch(''),
  'cf-account-id': string.onMismatch(''),

  // Logging
  'log-level': literals('error', 'warning', 'information', 'debug').onMismatch(
    'warning',
  ),
})

export const configFile = FileHelper.yaml(
  {
    volumeId: 'main',
    subpath: '/start9/config.yaml',
  },
  configShape,
)

export type Config = {
  'admin-username': string
  'admin-password': string
  'db-password': string
  'primary-dns': string
  'secondary-dns': string
  'check-interval': number
  'retry-interval': number
  'max-check-attempts': number
  'snmp-community': string
  'api-password': string
  'observium-sync-enabled': boolean
  'observium-db-host': string
  'observium-db-user': string
  'observium-db-password': string
  'cf-api-token': string
  'cf-account-id': string
  'log-level': 'error' | 'warning' | 'information' | 'debug'
}

export const defaultConfig: Config = {
  'admin-username': 'admin',
  'admin-password': '',
  'db-password': '',
  'primary-dns': '10.0.20.1',
  'secondary-dns': '1.1.1.1',
  'check-interval': 300,
  'retry-interval': 60,
  'max-check-attempts': 3,
  'snmp-community': '10fir',
  'api-password': '',
  'observium-sync-enabled': false,
  'observium-db-host': '10.0.60.125',
  'observium-db-user': 'observium',
  'observium-db-password': '',
  'cf-api-token': '',
  'cf-account-id': '',
  'log-level': 'warning',
}
