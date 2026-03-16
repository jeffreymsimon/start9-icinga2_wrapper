import { StartSdk } from '@start9labs/start-sdk'
import { manifest } from './manifest'

export const sdk = StartSdk.of().withManifest(manifest).build(true)

export {
  InputSpec,
  Value,
  List,
  Variants,
} from '@start9labs/start-sdk/base/lib/actions/input/builder'

export { getOwnServiceInterface } from '@start9labs/start-sdk/base/lib/util/getServiceInterface'
