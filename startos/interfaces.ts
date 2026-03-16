import { sdk } from './sdk'
import { webPort } from './utils'

export const setInterfaces = sdk.setupInterfaces(async ({ effects }) => {
  const httpMulti = sdk.MultiHost.of(effects, 'http-multi')
  const httpOrigin = await httpMulti.bindPort(webPort, {
    protocol: 'http',
  })

  const webUi = sdk.createInterface(effects, {
    name: 'Web UI',
    id: 'web-ui',
    description:
      'IcingaWeb2 dashboard for monitoring hosts, services, and alerts',
    type: 'ui',
    masked: false,
    schemeOverride: null,
    username: null,
    path: '',
    query: {},
  })

  const webUiReceipt = await httpOrigin.export([webUi])

  return [webUiReceipt]
})
