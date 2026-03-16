import { sdk } from '../sdk'
import { configFile, Config } from '../fileModels/config.yaml'

export const viewCredentials = sdk.Action.withoutInput(
  'view-credentials',

  async ({ effects }) => ({
    name: 'View Credentials',
    description: 'Show IcingaWeb2 admin login and Icinga2 API credentials',
    warning: null,
    allowedStatuses: 'any',
    group: 'Configuration',
    visibility: 'enabled',
  }),

  async ({ effects }) => {
    const config = (await configFile.read().const(effects)) as Config | null

    if (!config || !config['admin-password']) {
      return {
        version: '1' as const,
        title: 'Credentials Not Generated',
        message:
          'Credentials have not been generated yet. Start the service first.',
        result: {
          type: 'single' as const,
          value: 'Service must be started first to generate credentials.',
          copyable: false,
          qr: false,
          masked: false,
        },
      }
    }

    const apiPassword = config['api-password'] || 'Not yet generated'

    return {
      version: '1' as const,
      title: 'Icinga2 Credentials',
      message: `IcingaWeb2 Dashboard:
  Username: ${config['admin-username']}
  Password: ${config['admin-password']}

Icinga2 API:
  Username: root
  Password: ${apiPassword}
  Endpoint: https://localhost:5665/v1/`,
      result: {
        type: 'single' as const,
        value: `Username: ${config['admin-username']}\nPassword: ${config['admin-password']}`,
        copyable: true,
        qr: false,
        masked: true,
      },
    }
  },
)
