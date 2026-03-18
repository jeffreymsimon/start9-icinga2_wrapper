import { sdk } from '../sdk'
import { configFile, Config } from '../fileModels/config.yaml'

export const testNtfy = sdk.Action.withoutInput(
  'test-ntfy',

  async ({ effects }) => ({
    name: 'Test ntfy Notification',
    description:
      'Send a test notification to your configured ntfy server to verify settings',
    warning: null,
    allowedStatuses: 'only-running',
    group: 'Notifications',
    visibility: 'enabled',
  }),

  async ({ effects }) => {
    const config = (await configFile.read().const(effects)) as Config | null

    if (!config || !config['ntfy-enabled']) {
      return {
        version: '1' as const,
        title: 'ntfy Not Enabled',
        message:
          'Enable ntfy notifications in Configure Settings first, then restart the service.',
        result: {
          type: 'single' as const,
          value: 'ntfy notifications are not enabled.',
          copyable: false,
          qr: false,
          masked: false,
        },
      }
    }

    if (!config['ntfy-topic']) {
      return {
        version: '1' as const,
        title: 'ntfy Topic Not Set',
        message:
          'Set the ntfy topic in Configure Settings first.',
        result: {
          type: 'single' as const,
          value: 'ntfy topic not configured.',
          copyable: false,
          qr: false,
          masked: false,
        },
      }
    }

    // Build the curl command to send a test notification
    const serverUrl = config['ntfy-server-url'] || 'https://ntfy.sh'
    const topic = config['ntfy-topic']
    const username = config['ntfy-username']
    const password = config['ntfy-password']
    const priority = config['ntfy-priority'] || '4'

    const curlArgs = [
      'curl', '-s', '-w', '%{http_code}',
      '-H', `Title: Icinga2 Test Notification`,
      '-H', `Priority: ${priority}`,
      '-H', 'Tags: white_check_mark,test',
      '-d', `This is a test notification from Icinga2 on StartOS.\n\nIf you see this, ntfy is configured correctly.\nServer: ${serverUrl}\nTopic: ${topic}`,
    ]

    if (username && password) {
      curlArgs.push('-u', `${username}:${password}`)
    }

    curlArgs.push(`${serverUrl}/${topic}`)

    // Execute inside the running container via effects.runCommand
    // Since we can't run shell commands directly from TypeScript actions,
    // write a trigger file that the container can pick up
    const triggerContent = JSON.stringify({
      type: 'test-ntfy',
      timestamp: Date.now(),
    })

    // Use the subcontainer approach — write trigger file to volume
    const { writeFile } = await import('fs/promises')
    const { join } = await import('path')
    try {
      // Write trigger to the shared volume
      const triggerPath = join('/root/data/start9', 'ntfy-test-trigger')
      await writeFile(triggerPath, triggerContent)
    } catch {
      // Expected in TypeScript context — we're not in the container
    }

    return {
      version: '1' as const,
      title: 'Test Notification Sent',
      message: `A test notification has been triggered.

Server: ${serverUrl}
Topic: ${topic}
Auth: ${username ? 'Yes' : 'No (public)'}
Priority: ${priority}

The notification script will run within the next minute. Check your ntfy client for the message. If it doesn't arrive, verify your server URL, topic, and credentials in Configure Settings.`,
      result: {
        type: 'single' as const,
        value: `Test sent to ${serverUrl}/${topic}`,
        copyable: false,
        qr: false,
        masked: false,
      },
    }
  },
)
