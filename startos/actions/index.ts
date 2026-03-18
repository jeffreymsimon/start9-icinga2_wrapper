import { sdk } from '../sdk'
import { configureSettings } from './configure-settings'
import { viewCredentials } from './view-credentials'
import { syncNow } from './sync-now'
import { testNtfy } from './test-ntfy'

export const actions = sdk.Actions.of()
  .addAction(configureSettings)
  .addAction(viewCredentials)
  .addAction(syncNow)
  .addAction(testNtfy)
