import { sdk } from '../sdk'
import { configureSettings } from './configure-settings'
import { viewCredentials } from './view-credentials'
import { syncNow } from './sync-now'

export const actions = sdk.Actions.of()
  .addAction(configureSettings)
  .addAction(viewCredentials)
  .addAction(syncNow)
